// The scoreboard: how far from the real train each way of drawing it is, second
// by second, for every train GO reports, all day.
//
// Each train's reports come in as the app gets them (mergeTrains' list, looked at
// every 5 seconds). For each second, every model is replayed with only the
// reports an app would have had by then, and where it draws the train is noted.
// Later, once the train's next GPS fixes are in, where the train really was at
// that second is read off a smooth curve through all its fixes (the truth: a
// monotone cubic, as the app's own replay uses), and the difference is the error.
// Errors are summed up per train, per minute, per phase (standing, coming in,
// leaving, running) and per model, and go out as data points for Analytics Engine.
//
// The models:
//   today     what build 148 draws: 10 s behind, gliding through the reports
//             (TrainReplay), with the map's slack (NetworkMapView.settled).
//   from_fix  option A: guessed on from each fix's own time, no delay, carried
//             on as far as the station's own spot, gliding to each new fix in 2 s.
//   newest    the newest fix, as it is: how stale the raw data is.

import { Run } from "./track.js";
import { along, drawn, settle, slopes, track } from "./replay.js";

/** Changes to the scoring that make old numbers incomparable bump this. */
export const VERSION = "w1";
export const MODELS = ["today", "from_fix", "newest"];
/**
 * How long after the watcher first sees a report the app has it, in seconds: it
 * asks every 5 s, and the answer it gets can be a few seconds old (the Worker's
 * cache). Measured by tools/record_feeds.mjs asking /v1/live/trains as the app
 * does, in a rush hour: 2.1 s later (median; 90% within 7 s), when the watcher
 * first saw reports 7.6 s old (median) and the app 8.8 s old.
 */
export const APP_LAG = 2;
/** The app keeps a train's last 12 reports, of the last 5 minutes. */
export const KEEP = 12;
export const HISTORY = 300;
/** A report older than this doesn't place a train (the timetable does). */
export const FRESH = 120;
/** A second is scored once this long has passed, and two of the train's fixes are later than it. */
export const SETTLE = 30;
/** Option A glides to a new fix over this long, in seconds. */
export const GLIDE = 2;
/** After the watcher (re)starts, its trains have no past: seconds until it scores them. */
export const WARM_UP = 300;
/** A train with no new report in this long is gone. */
export const GONE = 300;
/** How far from a station's own spot a train is coming in or leaving, in metres. */
export const NEAR = 1500;
/** Below this speed (m/s), a train is standing. */
export const STANDING = 0.5;
/** Replayed seconds kept at most per train (a stall is caught up no further back). */
const CATCH_UP = 180;
/** How long a train's fixes are kept, in seconds (the truth needs the ones around each second). */
const KEEP_FIXES = 900;

// --- Reports, as the app has them ---------------------------------------------

/** A train's report and its other GPS fixes as reports of their own (LiveTrain.reports in the app). */
export function reportsOf(train) {
  const out = [{ time: train.time, lat: train.lat, lon: train.lon, status: train.status ?? null, stop: train.stop ?? null }];
  for (const fix of Array.isArray(train.fixes) ? train.fixes : []) {
    const newer = fix.time > train.time;
    out.push({ time: fix.time, lat: fix.lat, lon: fix.lon, status: newer ? train.status ?? null : null, stop: newer ? train.stop ?? null : null });
  }
  return out;
}

function onEarth(report) {
  const { lat, lon } = report;
  return Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && lat !== 0 && lon !== 0;
}

/**
 * Puts `report` among `reports` (oldest first) in its place by time, unless one
 * within a second of it is there already (LiveTrains.add in the app). True when added.
 */
export function addReport(reports, report) {
  if (!onEarth(report) || !Number.isFinite(report.time)) return false;
  if (reports.some((each) => Math.abs(each.time - report.time) < 1)) return false;
  let index = reports.findIndex((each) => each.time > report.time);
  if (index < 0) index = reports.length;
  reports.splice(index, 0, report);
  return true;
}

// --- Trips' stops -------------------------------------------------------------

/**
 * A trip's stop codes in the order the train calls at them, from GO's
 * Schedule/Trip answer (BoardService.inCallingOrder in the app: by time of day,
 * from just after the longest wait round the clock), keeping the stations
 * `known` has. Null when fewer than two.
 */
export function tripCodes(body, known) {
  const trips = body?.Trips?.Trip ?? body?.Trips;
  const trip = Array.isArray(trips) ? trips[0] : trips;
  const stops = Array.isArray(trip?.Stops) ? trip.Stops : trip?.Stops?.Stop ?? (trip?.Stops ? [trip.Stops] : []);
  const list = (Array.isArray(stops) ? stops : [stops]).filter((stop) => stop && typeof stop === "object");
  const minutes = list.map((stop) => clockMinutes(stop?.DepartureTime?.Scheduled || stop?.ArrivalTime?.Scheduled));
  let order = list.map((_, i) => i);
  if (list.length >= 2 && minutes.every((m) => m != null)) {
    const sorted = [...order].sort((a, b) => (minutes[a] !== minutes[b] ? minutes[a] - minutes[b] : a - b));
    let longest = -1;
    let start = 0;
    for (let position = 0; position < sorted.length; position++) {
      let gap = (minutes[sorted[(position + 1) % sorted.length]] - minutes[sorted[position]] + 1440) % 1440;
      if (position === sorted.length - 1 && gap === 0) gap = 1440;
      if (gap > longest) {
        longest = gap;
        start = (position + 1) % sorted.length;
      }
    }
    order = [...sorted.slice(start), ...sorted.slice(0, start)];
  }
  const codes = order.map((i) => String(list[i]?.Code ?? "").trim()).filter((code) => code && known(code));
  return codes.length >= 2 ? codes : null;
}

/** Minutes past midnight of a bare "HH:MM" ("24:05" is 5), or null. */
function clockMinutes(text) {
  const match = /^\s*(\d{1,2}):(\d{2})/.exec(String(text ?? ""));
  return match ? (Number(match[1]) * 60 + Number(match[2])) % 1440 : null;
}

/** Which way a run goes, by Union: "in" to it, "out" from it, "through" it, or "-". */
export function direction(codes) {
  if (!codes?.length) return "-";
  if (codes[codes.length - 1] === "UN") return "in";
  if (codes[0] === "UN") return "out";
  return codes.includes("UN") ? "through" : "-";
}

// --- Toronto time ---------------------------------------------------------------

const TORONTO = (() => {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Toronto", hourCycle: "h23", hour: "2-digit", weekday: "short" });
  } catch {
    return null;
  }
})();

/** The Toronto hour ("07") and weekday ("Tue") of a time. */
export function torontoHour(t) {
  if (TORONTO) {
    const parts = TORONTO.formatToParts(new Date(t * 1000));
    const hour = parts.find((part) => part.type === "hour")?.value ?? "";
    const weekday = parts.find((part) => part.type === "weekday")?.value ?? "";
    return { hour: hour.padStart(2, "0"), weekday };
  }
  const local = new Date((t - 5 * 3600) * 1000);
  return { hour: String(local.getUTCHours()).padStart(2, "0"), weekday: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][local.getUTCDay()] };
}

// --- One train ------------------------------------------------------------------

function freshModels() {
  return {
    today: { last: null },
    from_fix: { last: null, newest: null, offset: 0, since: null },
  };
}

class Watched {
  constructor(key, train, day) {
    this.key = key;
    this.trip = train.trip;
    this.line = train.line;
    this.day = day;
    /** The reports as the app has them, oldest first, each with when the app got it (`got`). */
    this.reports = [];
    /** Every fix of the train (for the truth), oldest first. */
    this.fixes = [];
    this.previous = null;
    this.run = null;
    this.codes = null;
    this.cursor = null;
    this.pending = [];
    this.models = freshModels();
    /** Per model, the last second scored: for moves back, and lurches. */
    this.prev = {};
    this.groups = new Map();
    this.cache = { key: null, track: null };
    this.placed = new Map();
    this.newestSeen = -Infinity;
  }

  /** One look at the train in the list, at `now` (the watcher's clock). New fixes' ages go to `ages`. */
  observe(train, now, lag, ages) {
    const looked = { ...train };
    // Creeping along the platform it's at, GO says it's on its way to that same station: it's still there.
    if (looked.status === "to" && this.previous?.status === "at" && this.previous.stop === looked.stop) looked.status = "at";
    for (const report of reportsOf(looked)) {
      if (addReport(this.reports, { ...report, got: now + lag })) {
        addReport(this.fixes, { ...report });
        if (report.time > this.newestSeen) {
          if (Number.isFinite(this.newestSeen)) ages.push(now - report.time);
          this.newestSeen = report.time;
        }
      }
    }
    this.previous = looked;
    this.lastSeen = now;
    // Kept as long as the app or the truth could need them.
    while (this.reports.length && this.reports[0].time < now - HISTORY - 120) this.reports.shift();
    while (this.fixes.length && this.fixes[0].time < now - KEEP_FIXES) {
      this.placed.delete(this.fixes[0].time);
      this.fixes.shift();
    }
  }

  setRun(run, codes) {
    this.run = run;
    this.codes = codes;
    this.cache = { key: null, track: null };
    this.placed.clear();
  }

  /** The reports the app had at `time` (LiveTrains.reports(of:at:)), or null when none places the train. */
  appReports(time) {
    const have = [];
    for (const report of this.reports) {
      if (report.got > time) continue;
      if (time - report.time < HISTORY) have.push(report);
    }
    const kept = have.slice(-KEEP);
    const newest = kept[kept.length - 1];
    if (!newest || !(time - newest.time < FRESH) || !(newest.time - time < 60)) return null;
    return kept;
  }

  trackOf(reports) {
    const key = `${reports.length}|${reports[0].time}|${reports[reports.length - 1].time}`;
    if (this.cache.key !== key) this.cache = { key, track: track(reports, this.run) };
    return this.cache.track;
  }

  /** Replays every model from the cursor to `now`, one second at a time. */
  replay(now, warm) {
    if (!this.run || !this.reports.length) return;
    const last = Math.floor(now);
    if (this.cursor == null) this.cursor = Math.ceil(this.reports[0].got);
    if (this.cursor < last - CATCH_UP) {
      this.cursor = last - CATCH_UP;
      this.models = freshModels();
      this.prev = {};
    }
    for (let time = this.cursor; time <= last; time++) {
      const reports = this.appReports(time);
      const t = reports && this.trackOf(reports);
      if (!t || t.latest.away || !t.samples.length) {
        // Not drawn by a live position (or drawn off its line): nothing to score.
        this.models = freshModels();
        this.prev = {};
        continue;
      }
      const newest = reports[reports.length - 1];
      const today = settle(drawn(t, this.run, time), this.models.today.last, t.latest.speed);
      this.models.today.last = today;

      const a = this.models.from_fix;
      const target = drawn(t, this.run, time, { delay: 0, clear: 0 });
      if (a.newest != null && newest.time !== a.newest && a.last != null) {
        a.offset = a.last - target;
        a.since = time;
      }
      const fade = a.since == null ? 0 : Math.max(0, 1 - (time - a.since) / GLIDE);
      const fromFix = target + a.offset * fade;
      a.last = fromFix;
      a.newest = newest.time;

      if (time >= warm) {
        this.pending.push({
          time,
          drawn: { today, from_fix: fromFix, newest: t.samples[t.samples.length - 1].distance },
          age: time - newest.time,
        });
      }
    }
    this.cursor = last + 1;
  }

  /** The train's path along its run by all its fixes: samples and slopes for the truth. */
  truth() {
    const samples = [];
    let hint = 0;
    for (const fix of this.fixes) {
      let sample = this.placed.get(fix.time);
      if (sample === undefined) {
        sample = this.run.place(fix, hint);
        this.placed.set(fix.time, sample);
      }
      if (!sample) continue;
      hint = sample.stop;
      if (sample.off > Run.ON_TRACK) continue;
      if (samples.length && sample.time <= samples[samples.length - 1].time) continue;
      const next = { time: sample.time, distance: sample.distance };
      if (samples.length) next.distance = Math.max(next.distance, samples[samples.length - 1].distance);
      samples.push(next);
    }
    return { samples, slopes: slopes(samples) };
  }

  /** Scores the replayed seconds whose truth is settled at `now` (all of them when `final`). */
  score(now, final = false) {
    if (!this.pending.length || !this.run) return;
    const { samples, slopes: m } = this.truth();
    if (samples.length < 2) {
      if (final) this.pending = [];
      return;
    }
    const at = (time) => along(samples, m, false, this.run, time);
    const first = samples[0].time;
    const lastFix = samples[samples.length - 1].time;
    let done = 0;
    for (const moment of this.pending) {
      const later = samples.filter((sample) => sample.time > moment.time).length;
      if (!final && (later < 2 || now - moment.time < SETTLE)) break;
      done++;
      if (moment.time < first || moment.time > lastFix) continue;
      this.tally(moment, at(moment.time), (at(moment.time + 1) - at(moment.time - 1)) / 2, at(moment.time - 1));
    }
    this.pending.splice(0, done);
    // Every second before this one is scored (or wasn't drawn by a live position).
    const frontier = final ? Infinity : this.pending[0]?.time ?? this.cursor ?? -Infinity;
    this.frontier = Math.max(this.frontier ?? -Infinity, frontier);
  }

  tally(moment, real, speed, realBefore) {
    const starts = this.run.starts;
    let next = starts.findIndex((start) => start > real - Run.PLATFORM);
    if (next < 0) next = starts.length - 1;
    const toNext = starts[next] - real;
    const sincePrevious = next > 0 ? real - starts[next - 1] : Infinity;
    const phase = speed < STANDING ? "stand" : toNext <= NEAR ? "in" : sincePrevious <= NEAR ? "out" : "run";
    const minute = Math.floor(moment.time / 60) * 60;
    for (const model of MODELS) {
      const value = moment.drawn[model];
      if (!Number.isFinite(value)) continue;
      const error = value - real;
      this.observer?.({ model, error, phase, line: this.line, time: moment.time, trip: this.trip, age: moment.age, real, value });
      const key = `${minute}|${phase}|${model}`;
      let group = this.groups.get(key);
      if (!group) {
        group = {
          minute, phase, model, stop: this.codes[next] ?? "", n: 0, sumAbs: 0, sumErr: 0, sumSq: 0, ahead: 0, aheadFar: 0,
          maxAhead: 0, maxBehind: 0, back: 0, backSum: 0, lurch: 0, over50: 0, over100: 0, ageSum: 0, speedSum: 0,
        };
        this.groups.set(key, group);
      }
      group.n++;
      group.sumAbs += Math.abs(error);
      group.sumErr += error;
      group.sumSq += error * error;
      if (error > 1) group.ahead++;
      if (error > 25) group.aheadFar++;
      group.maxAhead = Math.max(group.maxAhead, error);
      group.maxBehind = Math.max(group.maxBehind, -error);
      if (Math.abs(error) > 50) group.over50++;
      if (Math.abs(error) > 100) group.over100++;
      group.ageSum += moment.age;
      group.speedSum += Math.max(speed, 0);
      const before = this.prev[model];
      if (before && before.time === moment.time - 1) {
        const moved = value - before.value;
        if (moved < -0.5) {
          group.back++;
          group.backSum += -moved;
        }
        if (moved - (real - realBefore) > 20) group.lurch++;
      }
      this.prev[model] = { time: moment.time, value };
    }
  }

  /** The summaries of the minutes that are over (all of them when `final`). */
  finished(final = false) {
    const out = [];
    for (const [key, group] of this.groups) {
      if (!final && group.minute + 60 > (this.frontier ?? -Infinity)) continue;
      this.groups.delete(key);
      out.push(group);
    }
    return out;
  }
}

// --- Every train ------------------------------------------------------------------

/**
 * The scoreboard for every train: `look()` with each look at the feeds, then the
 * finished summaries as Analytics Engine data points from `points()`.
 */
export class Scoreboard {
  /** `observer({ model, error, phase, line, time, trip })`, when given, hears every second scored (tools use it). */
  constructor({ lag = APP_LAG, startedAt = 0, warmUp = WARM_UP, observer = null } = {}) {
    this.lag = lag;
    this.warm = startedAt + warmUp;
    this.observer = observer;
    this.trains = new Map();
    this.out = [];
    this.recent = [];
    this.ages = [];
  }

  /**
   * One look at the feeds at `now`: `list` is mergeTrains' list; `runOf(train)`
   * gives { key, day, run, codes } for a train (run and codes null while its
   * stops aren't known yet).
   */
  look(list, now, runOf) {
    const ages = [];
    for (const train of list?.trains ?? []) {
      const info = runOf(train);
      if (!info) continue;
      let watched = this.trains.get(info.key);
      if (!watched) {
        watched = new Watched(info.key, train, info.day);
        watched.observer = this.observer;
        this.trains.set(info.key, watched);
      }
      if (info.run && watched.run !== info.run) watched.setRun(info.run, info.codes);
      if (info.line) watched.line = info.line;
      watched.observe(train, now, this.lag, ages);
    }
    this.ages.push(...ages);
    if (this.ages.length > 2000) this.ages.splice(0, this.ages.length - 2000);
    for (const [key, watched] of this.trains) {
      if (now - (watched.lastSeen ?? now) > GONE) {
        watched.score(now, true);
        this.collect(watched, true, now);
        this.trains.delete(key);
        continue;
      }
      watched.replay(now, this.warm);
      watched.score(now);
      this.collect(watched, false, now);
    }
  }

  collect(watched, final, now) {
    for (const group of watched.finished(final)) {
      if (!group.n) continue;
      this.out.push(point(watched, group));
      this.recent.push({ minute: group.minute, model: group.model, phase: group.phase, n: group.n, sumAbs: group.sumAbs,
        sumErr: group.sumErr, ahead: group.ahead, back: group.back, over100: group.over100 });
    }
    while (this.recent.length && this.recent[0].minute < now - 3600) this.recent.shift();
    // (Nobody reading them: kept to a day's worth at most.)
    if (this.out.length > 20000) this.out.splice(0, this.out.length - 20000);
  }

  /** Data points ready to write, at most `limit` (the rest wait). */
  points(limit = Infinity) {
    return this.out.splice(0, limit);
  }

  /** How each model has done over the last hour, and how old fixes are when the watcher sees them. */
  summary() {
    const models = {};
    for (const model of MODELS) {
      const rows = this.recent.filter((row) => row.model === model);
      const n = rows.reduce((sum, row) => sum + row.n, 0);
      if (!n) continue;
      const sum = (field) => rows.reduce((total, row) => total + row[field], 0);
      models[model] = {
        seconds: n,
        meanOff: round(sum("sumAbs") / n),
        meanSigned: round(sum("sumErr") / n),
        aheadShare: round(sum("ahead") / n, 3),
        over100Share: round(sum("over100") / n, 3),
        backPerHour: round((sum("back") / n) * 3600, 1),
      };
    }
    const ages = [...this.ages].sort((a, b) => a - b);
    const q = (p) => (ages.length ? round(ages[Math.min(ages.length - 1, Math.floor(p * ages.length))], 1) : null);
    const trains = [...this.trains.values()];
    return {
      trains: trains.length,
      placed: trains.filter((each) => each.run).length,
      models,
      fixAge: { median: q(0.5), p90: q(0.9), count: ages.length },
      waiting: this.out.length,
    };
  }
}

function round(value, places = 1) {
  const scale = 10 ** places;
  return Math.round(value * scale) / scale;
}

/**
 * One train-minute's summary for one model, as an Analytics Engine data point:
 *
 *   index1  model
 *   blob1   model        blob2  line      blob3  phase (stand, in, out, run)
 *   blob4   station ahead (or at)        blob5  trip number
 *   blob6   direction by Union (in, out, through, -)
 *   blob7   Toronto hour ("07")          blob8  weekday ("Tue")
 *   blob9   last stop of the run         blob10 scoring version
 *   double1 seconds scored    double2  sum of |error| (m)   double3  sum of error (m; + ahead)
 *   double4 sum of error²     double5  seconds ahead by over 1 m   double6  ... by over 25 m
 *   double7 most ahead (m)    double8  most behind (m)
 *   double9 moves back        double10 metres moved back   double11 lurches (20 m+ in a second)
 *   double12 seconds off by over 50 m   double13 ... by over 100 m
 *   double14 sum of the newest fix's age (s)   double15 sum of the train's speed (m/s)
 *   double16 the minute (Unix seconds)
 */
export function point(watched, group) {
  const { hour, weekday } = torontoHour(group.minute);
  return {
    indexes: [group.model],
    blobs: [
      group.model, watched.line ?? "", group.phase, group.stop ?? "", watched.trip ?? "", direction(watched.codes),
      hour, weekday, watched.codes?.[watched.codes.length - 1] ?? "", VERSION,
    ],
    doubles: [
      group.n, round(group.sumAbs, 1), round(group.sumErr, 1), round(group.sumSq, 0), group.ahead, group.aheadFar,
      round(group.maxAhead, 1), round(group.maxBehind, 1), group.back, round(group.backSum, 1), group.lurch,
      group.over50, group.over100, round(group.ageSum, 1), round(group.speedSum, 1), group.minute,
    ],
  };
}
