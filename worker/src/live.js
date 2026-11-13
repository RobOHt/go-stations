// Live train positions, and following a tracked train with them.
//
// GO's GTFS vehicle positions say where each train is (about every 20 s) and
// whether it's standing at a station (STOPPED_AT, with the station's code) or on
// its way to one (IN_TRANSIT_TO, INCOMING_AT). Service at a Glance adds how late
// it is. mergeTrains() makes the two one compact list for the app; follow() uses a
// train's latest position to re-time a tracked trip's Live Activity: when the train
// pulled in at each stop and left it, and when it should get to the ones ahead.
//
// Times are seconds since 1970 throughout, as the Live Activity's content carries them.

/** A train standing at a station is taken to stay at least this much longer. */
export const HOLD = 45;
/** How long a train stands at a station along the way, when nothing says otherwise. */
export const DWELL = 60;
/** A position older than this says nothing about where the train is now. */
export const FRESH = 120;
/** A train not heard from in this long isn't running. */
const GONE = 300;
/** Delay changes smaller than this don't re-time the stops ahead. */
const DELAY_STEP = 30;
/**
 * Reports further apart than this missed what happened in between: a train seen
 * at a station and then past it left somewhere in between, not just now.
 */
const REPORT_GAP = 90;

const TRIP_ID = /^(\d{8})-([A-Z]{2})-([A-Za-z0-9]{1,12})$/;

// --- The list of trains ------------------------------------------------------

/**
 * Every train in GO's vehicle positions (buses left out), with Service at a
 * Glance's delay, course and motion added; a train only Service at a Glance
 * knows about is kept at its position there. Trains not heard from in five
 * minutes are left out.
 *
 *   { at, trains: [{ trip, line, lat, lon, time, status: "at" | "to" | null,
 *                    stop, delay?, moving?, course? }] }
 */
export function mergeTrains(vehicles, glance, now) {
  const trains = new Map();
  for (const entity of list(vehicles?.entity)) {
    const vehicle = entity?.vehicle;
    const id = TRIP_ID.exec(String(vehicle?.trip?.trip_id ?? ""));
    const lat = Number(vehicle?.position?.latitude);
    const lon = Number(vehicle?.position?.longitude);
    if (!id || !Number.isFinite(lat) || !Number.isFinite(lon) || (lat === 0 && lon === 0)) continue;
    const status = vehicle.current_status;
    trains.set(id[3], {
      trip: id[3],
      line: id[2],
      lat: round(lat),
      lon: round(lon),
      time: Number(vehicle.timestamp) || Math.floor(now),
      status: status === "STOPPED_AT" ? "at" : status === "IN_TRANSIT_TO" || status === "INCOMING_AT" ? "to" : null,
      stop: typeof vehicle.stop_id === "string" && vehicle.stop_id ? vehicle.stop_id : null,
    });
  }

  const offset = torontoOffset(glance?.Metadata?.TimeStamp, now);
  for (const train of list(glance?.Trips?.Trip)) {
    const trip = String(train?.TripNumber ?? "").trim();
    if (!/^[A-Za-z0-9]{1,12}$/.test(trip)) continue;
    const extra = {};
    if (Number.isFinite(train.DelaySeconds)) extra.delay = train.DelaySeconds;
    if (typeof train.IsInMotion === "boolean") extra.moving = train.IsInMotion;
    if (Number.isFinite(train.Course)) extra.course = train.Course;
    const known = trains.get(trip);
    if (known) {
      Object.assign(known, extra);
      continue;
    }
    const time = wallClock(train.ModifiedDate, offset);
    const lat = Number(train.Latitude);
    const lon = Number(train.Longitude);
    if (time == null || !Number.isFinite(lat) || !Number.isFinite(lon) || (lat === 0 && lon === 0)) continue;
    // Its "station" can be a signal or junction along the line; the app checks.
    const at = typeof train.AtStationCode === "string" && train.AtStationCode ? train.AtStationCode : null;
    trains.set(trip, {
      trip,
      line: String(train.LineCode ?? "").trim() || null,
      lat: round(lat),
      lon: round(lon),
      time,
      status: at ? "at" : null,
      stop: at,
      ...extra,
    });
  }

  const running = [...trains.values()].filter((train) => now - train.time < GONE && train.time < now + 120);
  running.sort((a, b) => (a.trip < b.trip ? -1 : a.trip > b.trip ? 1 : 0));
  return { at: Math.floor(now), trains: running };
}

/** Seconds to add to a Toronto wall-clock time read as UTC to get the real time. */
export function torontoOffset(stamp, now) {
  const local = parseWall(stamp);
  if (local != null) {
    const offset = Math.round((now - local) / 900) * 900;
    if (offset >= 3 * 3600 && offset <= 6 * 3600) return offset;
  }
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Toronto", hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    }).formatToParts(new Date(now * 1000));
    const get = (type) => Number(parts.find((part) => part.type === type)?.value);
    const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second")) / 1000;
    if (Number.isFinite(wall)) return Math.round((now - wall) / 900) * 900;
  } catch {
    // Fall through.
  }
  return 5 * 3600;
}

function parseWall(text) {
  const match = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(String(text ?? ""));
  return match ? Date.UTC(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6]) / 1000 : null;
}

function wallClock(text, offset) {
  const local = parseWall(text);
  return local == null ? null : local + offset;
}

// --- Following a tracked train ------------------------------------------------

/**
 * When the train pulls in at stop `index` of a Live Activity's stops: when it was
 * seen there, else a minute before it leaves (or halfway from the stop before, on
 * a short hop). The same rule as TrainState.arrival in the app.
 */
export function arrivalAt(stops, index) {
  const stop = stops[index];
  if (!stop) return null;
  if (Number.isFinite(stop.arrives)) return Number.isFinite(stop.time) ? Math.min(stop.arrives, stop.time) : stop.arrives;
  if (!Number.isFinite(stop.time)) return null;
  if (index === 0 || index === stops.length - 1) return stop.time;
  const previous = Number.isFinite(stops[index - 1]?.time) ? stops[index - 1].time : stop.time;
  return stop.time - Math.min(DWELL, Math.max(0, stop.time - previous) / 2);
}

/**
 * Brings a tracked trip's Live Activity up to date with its train's latest
 * position (`train`, from mergeTrains, or undefined when it isn't in the list):
 * notes when the train pulled in at a stop and when it left, re-times the stops
 * ahead from how late it is, and says whether that's worth a push. A train
 * standing at a station longer than planned is kept there; one late for its next
 * stop is due there any moment.
 *
 * `job.live` is { trip, codes, scheduled }: the stops' codes and planned
 * departure times, matching `job.state.stops`. What was seen is kept on the job
 * (obs, arr, dep). Returns { job, changed, push, state, stale } (push: null,
 * or { event, state, stale | dismissal }; state and stale: the trip as it
 * stands, and when it next changes, while the train is on its way); or null
 * when there's nothing fresh to go on and nothing to do.
 */
export function follow(job, train, now) {
  const { codes, scheduled } = job.live;
  const count = codes.length;
  const base = job.state;
  const boarding = clamp(base.boardingIndex ?? 0, 0, count - 1);
  const destination = clamp(base.destinationIndex ?? count - 1, boarding, count - 1);

  if (!train || !(now - train.time < FRESH) || train.time > now + 60) {
    // Lost the train (or never had it). Once followed, end the activity a while
    // after it should have got in.
    if (job.followed && now > (job.end ?? now) + 600) {
      return { job, changed: true, push: { event: "end", state: base, dismissal: now + 60 } };
    }
    return null;
  }

  const obs = { ...(job.obs ?? {}) };
  const arr = { ...(job.arr ?? {}) };
  const dep = { ...(job.dep ?? {}) };

  // Reports missed since the last one looked at: when it left a station isn't known.
  const missed = Number.isFinite(job.seen) && train.time - job.seen > REPORT_GAP;

  // Where it is, in this trip's stops: at or after where it was last seen.
  let index = train.stop ? codes.indexOf(train.stop, obs.k ?? 0) : -1;
  if (index < 0 && obs.k == null && train.stop) index = codes.indexOf(train.stop);
  if (index >= 0) {
    const sameStop = obs.k === index;
    if (train.status === "at") {
      if (!(obs.at && sameStop)) {
        if (!missed && obs.at && obs.k != null && obs.k < index) dep[obs.k] ??= train.time;
        arr[index] ??= train.time;
        Object.assign(obs, { k: index, at: true, since: train.time });
      }
    } else if (train.status === "to") {
      // Creeping along the platform it's at says "on its way to" that same station.
      if (!(obs.at && sameStop)) {
        if (!missed && obs.at && obs.k != null && obs.k < index) dep[obs.k] ??= train.time;
        if (!sameStop || obs.at) Object.assign(obs, { k: index, at: false, since: train.time });
      }
    }
  }

  const reported = Number.isFinite(train.delay) ? train.delay : null;
  const delay = reported == null ? job.delay ?? 0
    : job.delay == null || Math.abs(reported - job.delay) >= DELAY_STEP ? reported : job.delay;
  // A train doesn't leave a station early, whatever its delay says.
  const late = Math.max(0, delay);
  const k = obs.k;
  // On its way to the end of its run ahead of time, though, it gets in early: the
  // timetable leaves room on the last stretch (into Union, say).
  const early = k === count - 1 && !obs.at && delay < 0 ? delay : 0;

  const stops = base.stops.map((stop) => {
    const copy = { name: stop.name };
    if (Number.isFinite(stop.time)) copy.time = stop.time;
    return copy;
  });
  let extra = 0;
  let leave = null;
  for (let i = 0; i < count; i++) {
    const planned = Number.isFinite(scheduled[i]) ? scheduled[i] : stops[i].time;
    if (k != null && i < k) {
      // Behind it: when it left, as seen, or no later than now.
      const left = dep[i] ?? Math.min(Number.isFinite(stops[i].time) ? stops[i].time : train.time, train.time);
      stops[i].time = left;
      if (arr[i] != null) stops[i].arrives = Math.min(arr[i], left);
      // Seen leaving the last one later than its delay says: the stops ahead are that late too.
      if (i === k - 1 && dep[i] != null && Number.isFinite(planned)) extra = Math.max(0, dep[i] - (planned + late));
      continue;
    }
    if (!Number.isFinite(planned)) continue;
    if (i === k && obs.at) {
      // Standing there: it leaves when due, and not before a little while from now.
      const due = planned + late + extra;
      let leaves = Math.max(due, now + HOLD);
      if (leaves > due && job.leave?.k === i && job.leave.time > now + 10) leaves = job.leave.time;
      if (leaves > due) leave = { k: i, time: leaves };
      extra = leaves - (planned + late);
      stops[i].time = leaves;
      if (arr[i] != null && i > 0) stops[i].arrives = Math.min(arr[i], leaves);
      continue;
    }
    stops[i].time = early < 0 && i === count - 1 ? planned + early : planned + late + extra;
  }

  // On its way to the next stop and late for it: due there any moment.
  let eta = null;
  if (k != null && !obs.at && k > 0) {
    const due = arrivalAt(stops, k);
    if (due != null && due < now + 10) {
      let comes = now + 40;
      if (job.eta?.k === k && job.eta.time > now + 10) comes = job.eta.time;
      eta = { k, time: comes };
      const shift = comes - due;
      for (let i = k; i < count; i++) if (Number.isFinite(stops[i].time)) stops[i].time += shift;
      stops[k].arrives = comes;
    }
  }

  const ended = k != null && ((obs.at && k >= destination) || k > destination);
  if (ended) {
    const came = arr[destination] ?? train.time;
    stops[destination].arrives = came;
    if (destination === count - 1 || !Number.isFinite(stops[destination].time)) stops[destination].time = came;
  }

  const state = { ...base, stops };
  if (Number.isFinite(stops[boarding].time)) state.departure = stops[boarding].time;
  const due = ended ? stops[destination].arrives : Number.isFinite(stops[destination].time) ? stops[destination].time : base.arrival;
  state.arrival = Math.max(due, state.departure + (ended ? 0 : 60));
  state.hasDeparted = now >= state.departure || (k != null && k > boarding);
  state.minutesLate = Math.round(late / 60);
  delete state.revision;

  const next = {
    ...job,
    obs, arr, dep,
    delay,
    leave,
    eta,
    followed: true,
    seen: train.time,
    end: ended ? now : arrivalAt(stops, destination) ?? job.end,
  };
  const key = JSON.stringify([k ?? null, obs.at ?? null, stops.map((stop) => [stop.time ?? null, stop.arrives ?? null])]);
  const changed = JSON.stringify([job.obs, job.arr, job.dep, job.delay, job.leave, job.eta, job.end, job.followed]) !==
    JSON.stringify([next.obs, next.arr, next.dep, next.delay, next.leave, next.eta, next.end, next.followed]);

  if (ended) {
    // On the Lock Screen as long after it got in as the app asked for.
    const summary = Number.isFinite(job.summary) ? job.summary : 15 * 60;
    return { job: next, changed: true, push: { event: "end", state, dismissal: now + Math.min(Math.max(summary, 60), 3600) } };
  }

  // Wake the activity again at the next thing it shows changing.
  let soonest = Infinity;
  for (let i = Math.max(k ?? 0, 0); i <= destination; i++) {
    for (const time of [arrivalAt(stops, i), stops[i].time]) {
      if (Number.isFinite(time) && time > now + 1) soonest = Math.min(soonest, time);
    }
  }
  const stale = Number.isFinite(soonest) ? soonest : now + 120;
  // (The state as it stands goes back either way, for an alert that's due.)
  if (key === job.pushed) return { job: next, changed, push: null, state, stale };
  next.pushed = key;
  return { job: next, changed: true, push: { event: "update", state, stale }, state, stale };
}

// --- Journeys with changes, and alerts ---------------------------------------

/** How long before the train gets to where you change or get off that you're told. */
export const ALERT_BEFORE = 5 * 60;

/** Which alert a trip's state is for: its train, and where you get off it. */
function alertKey(job, state) {
  const stops = Array.isArray(state?.stops) ? state.stops : [];
  const destination = clamp(state?.destinationIndex ?? stops.length - 1, 0, Math.max(stops.length - 1, 0));
  return `${job.live?.trip ?? ""}@${destination}:${stops[destination]?.name ?? ""}`;
}

/**
 * When the alert before your stop (or where you change) is due, by the stops'
 * times in `job.state`: 5 minutes before the train gets there. Null when the
 * trip has no alerts, it was sent, or it's too late for one.
 */
export function alertTime(job, now) {
  if (!job.alerts || job.alerted === alertKey(job, job.state)) return null;
  const stops = Array.isArray(job.state?.stops) ? job.state.stops : [];
  if (stops.length < 2) return null;
  const destination = clamp(job.state.destinationIndex ?? stops.length - 1, 0, stops.length - 1);
  const due = arrivalAt(stops, destination);
  if (!Number.isFinite(due) || due - now < 60) return null;
  return due - ALERT_BEFORE;
}

/**
 * The alert to send with an update, when it's time: about 5 minutes before the
 * train gets to where you change ("Change at Union in 5 min") or get off ("Port
 * Credit in 5 min"), once you're on it, once per stop. `state` is the trip as it
 * stands (re-timed by its train's position when it's followed). Returns { key,
 * title, body } (the job's `alerted` takes the key), or null.
 */
export function alertFor(job, state, now) {
  if (!job.alerts || !state) return null;
  const stops = Array.isArray(state.stops) ? state.stops : [];
  if (stops.length < 2) return null;
  const last = stops.length - 1;
  const boarding = clamp(state.boardingIndex ?? 0, 0, last);
  const destination = clamp(state.destinationIndex ?? last, boarding, last);
  const key = alertKey(job, state);
  if (job.alerted === key) return null;
  const due = arrivalAt(stops, destination);
  if (!Number.isFinite(due)) return null;
  const left = due - now;
  if (left > ALERT_BEFORE + 10 || left < 60) return null;
  // On the train: it has left where you get on.
  const leaves = stops[boarding]?.time;
  if (!state.hasDeparted && Number.isFinite(leaves) && now < leaves) return null;
  const minutes = Math.max(1, Math.round(left / 60));
  const name = String(stops[destination]?.name ?? "your stop");
  const change = state.change;
  if (change && typeof change === "object") {
    const line = change.lineName ? `${change.lineName} line` : String(change.lineCode ?? "next");
    const at = Number.isFinite(change.departure) ? `${torontoClock(change.departure)} ` : "";
    return {
      key,
      title: `Change at ${name} in ${minutes} min`,
      body: `Then the ${at}${line} train to ${change.terminusName ?? change.destinationName ?? "your stop"}.`,
    };
  }
  return { key, title: `${name} in ${minutes} min`, body: "Your stop is coming up. Get ready to get off." };
}

/**
 * When to follow a trip's train: from 20 minutes before it's due at your
 * station (in case you're waiting for it) until well after it should have got
 * to your stop.
 */
export function watchWindow(job) {
  if (!job.live) return {};
  const boarding = Math.max(0, job.state.boardingIndex ?? 0);
  const start = job.live.scheduled[boarding] ?? job.state.departure;
  return {
    watchFrom: start - 20 * 60,
    watchUntil: Math.max(job.end, start) + 45 * 60,
    summary: Math.max(60, job.dismissal - job.end),
  };
}

/**
 * On a journey with changes, once the train you're on is in where you change:
 * the job for the next train (`job.legs[0]`), nothing seen of it yet. Null when
 * there's none.
 */
export function nextLeg(job, now) {
  const [leg, ...rest] = Array.isArray(job.legs) ? job.legs : [];
  if (!leg) return null;
  const next = {
    token: job.token,
    environment: job.environment,
    revision: job.revision ?? 0,
    alerts: job.alerts,
    alerted: job.alerted,
    // (Asked not to be notified, and the app's own token to wake it, for this train too.)
    ...(job.quiet ? { quiet: true } : {}),
    ...(job.device ? { device: job.device } : {}),
    // Told it's cancelled already, as the connection.
    ...(job.connectionAlerted && job.connectionCancelled ? { cancelAlerted: true } : {}),
    state: leg.state,
    times: (leg.times ?? []).filter((t) => t > now && t < leg.end),
    end: leg.end,
    dismissal: Math.max(leg.dismissal, leg.end),
    live: leg.live ?? null,
    legs: rest,
  };
  return { ...next, ...watchWindow(next) };
}

/** A time as on GO's boards: 24-hour, Toronto time ("17:05"). */
export function torontoClock(t) {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Toronto", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    }).format(new Date(t * 1000));
  } catch {
    const offset = torontoOffset(undefined, t);
    return new Date((t - offset) * 1000).toISOString().slice(11, 16);
  }
}

function list(value) {
  return Array.isArray(value) ? value : [];
}

function round(degrees) {
  return Math.round(degrees * 1e6) / 1e6;
}

function clamp(value, low, high) {
  return Math.min(Math.max(Number.isInteger(value) ? value : low, low), high);
}

// --- Did you catch it? -------------------------------------------------------

/** How long after the train leaves where you get on that the app is woken to check you're on it. */
export const MISSED_AFTER = 120;

/**
 * On the first train of a trip from search (`missedCheck`, with the app's own
 * push token, `device`): once it has left where you get on, and a couple of
 * minutes have passed, the app is woken with a silent push to check you're on
 * it (it knows where you are; the worker doesn't). The push's payload: when it
 * left, and where the train was then. Null when it's not time, or done.
 */
export function missedCheck(job, train, now) {
  if (!job.missedCheck || !job.device || job.missedSent || !job.live) return null;
  const boarding = job.state?.boardingIndex ?? 0;
  const left = job.dep?.[boarding] ?? (job.obs?.k > boarding ? job.obs.since : null);
  if (!Number.isFinite(left) || now - left < MISSED_AFTER) return null;
  const check = { trip: job.live.trip, left };
  if (train && Number.isFinite(train.lat) && Number.isFinite(train.lon) && Number.isFinite(train.time)) {
    Object.assign(check, { lat: train.lat, lon: train.lon, time: train.time });
  }
  return check;
}

// --- Cancelled trains -------------------------------------------------------

/**
 * Which trains aren't running, or won't stop somewhere they were due to, by GO's
 * train exceptions feed and its GTFS trip updates together: each has had a
 * cancellation the other hadn't (a train not stopping at the first three of its
 * stations was in the trip updates, with only the third of them in the
 * exceptions). One entry per train per feed, by trip number:
 *
 *   [{ trip, day?, all?: true, skips?: [codes] }]
 *
 * `all`: the whole trip is cancelled. `skips`: the stations it won't stop at.
 * `day`: its service day ("20261113"), when the trip updates say (the
 * exceptions are today's).
 */
export function cancellations(exceptions, updates) {
  const found = new Map();
  const entry = (trip, day) => {
    const key = `${trip}|${day ?? ""}`;
    if (!found.has(key)) found.set(key, { trip, day, all: false, skips: new Set() });
    return found.get(key);
  };
  for (const trip of list(exceptions?.Trip)) {
    const number = String(trip?.TripNumber ?? "").trim();
    if (!/^[A-Za-z0-9]{1,12}$/.test(number)) continue;
    if (truthy(trip.IsCancelled)) entry(number).all = true;
    const stops = Array.isArray(trip.Stop) ? trip.Stop : trip.Stop ? [trip.Stop] : [];
    for (const stop of stops) {
      const code = String(stop?.Code ?? "").trim();
      if (code && truthy(stop.IsCancelled)) entry(number).skips.add(code);
    }
  }
  for (const entity of list(updates?.entity)) {
    const update = entity?.trip_update;
    const id = TRIP_ID.exec(String(update?.trip?.trip_id ?? ""));
    if (!id) continue;
    const relation = update.trip.schedule_relationship;
    const cancelled = relation === "CANCELED" || relation === "CANCELLED" || relation === 3;
    const skipped = [];
    for (const stop of list(update.stop_time_update)) {
      const code = String(stop?.stop_id ?? "").trim();
      if (code && (stop.schedule_relationship === "SKIPPED" || stop.schedule_relationship === 1)) skipped.push(code);
    }
    if (!cancelled && !skipped.length) continue;
    const train = entry(id[3], id[1]);
    if (cancelled) train.all = true;
    for (const code of skipped) train.skips.add(code);
  }
  return [...found.values()]
    .map(({ trip, day, all, skips }) => ({
      trip,
      ...(day ? { day } : {}),
      ...(all ? { all: true } : {}),
      ...(skips.size ? { skips: [...skips] } : {}),
    }))
    .sort((a, b) => (a.trip < b.trip ? -1 : a.trip > b.trip ? 1 : (a.day ?? "") < (b.day ?? "") ? -1 : 1));
}

/** "1", 1, true, "true": yes. */
function truthy(value) {
  return value === true || value === 1 || value === "1" || String(value ?? "").trim().toLowerCase() === "true";
}

/**
 * Whether a tracked trip's train still comes for you, by `cancellations()`: null
 * when it does; otherwise { index, code, name, left? }, the station of yours it
 * won't stop at (where you get on, or where you get off) with the name the Live
 * Activity shows (`left`: it has left where you get on, with you on it), or
 * { all: true } when the whole trip is cancelled. Only the entries for its service day count (trip numbers come round
 * again every day).
 */
export function cancellationFor(job, cancelled) {
  const live = job?.live;
  if (!live || !Array.isArray(cancelled)) return null;
  const day = serviceDay(live.scheduled);
  const entries = cancelled.filter((entry) => entry.trip === live.trip && (!entry.day || !day || entry.day === day));
  if (!entries.length) return null;
  if (entries.some((entry) => entry.all)) return { all: true };
  const skips = new Set(entries.flatMap((entry) => entry.skips ?? []));
  const last = live.codes.length - 1;
  const boarding = clamp(job.state?.boardingIndex ?? 0, 0, last);
  const destination = clamp(job.state?.destinationIndex ?? last, boarding, last);
  // Seen leaving where you get on: only where you get off matters now.
  const left = Number.isFinite(job.dep?.[boarding]) || (job.obs?.k ?? -1) > boarding;
  for (const index of left ? [destination] : [boarding, destination]) {
    const code = live.codes[index];
    if (!skips.has(code)) continue;
    return { index, code, name: String(job.state?.stops?.[index]?.name ?? code), ...(left ? { left: true } : {}) };
  }
  return null;
}

/** A trip's service day ("20261113"): the day its first train time is on, counting the night as the day before. */
export function serviceDay(scheduled) {
  const first = list(scheduled).find(Number.isFinite);
  return first == null ? null : torontoDay(first - 4 * 3600);
}

/** The Toronto date of a time, as GTFS writes it ("20261113"). */
export function torontoDay(t) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Toronto", year: "numeric", month: "2-digit", day: "2-digit",
    }).formatToParts(new Date(t * 1000));
    const get = (type) => parts.find((part) => part.type === type)?.value ?? "";
    return `${get("year")}${get("month")}${get("day")}`;
  } catch {
    return new Date((t - torontoOffset(undefined, t)) * 1000).toISOString().slice(0, 10).replaceAll("-", "");
  }
}

/**
 * What a cancelled train's Live Activity shows of it (`cancelled` in its
 * content): { index, station }, the stop of yours it won't stop at (its place
 * in the stops, and name), or {} for the whole trip. Null when it's running.
 */
export function cancelledContent(verdict) {
  if (!verdict) return null;
  return verdict.all ? {} : { index: verdict.index, station: verdict.name };
}

/**
 * The Live Activity's content as pushed: the trip's state with whether its train
 * is cancelled, by the worker's own look at the feeds once it has had one (until
 * then, as the app had it). The next train the app found stays on it.
 */
export function shownState(job, state) {
  if (!state || typeof state !== "object") return state;
  let shown = state;
  // On a trip with changes, the train you change to: cancelled or not as the
  // worker last looked (as the app had it, until then).
  if (job.connectionCheckedAt != null && state.change && typeof state.change === "object") {
    const { cancelled: _, ...change } = state.change;
    shown = { ...state, change: job.connectionCancelled ? { ...change, cancelled: true } : change };
  }
  if (job.cancelCheckedAt == null && !job.cancelled) return shown;
  const { cancelled: claimed, ...rest } = shown;
  if (!job.cancelled) return rest;
  const content = cancelledContent(job.cancelled);
  if (Number.isFinite(claimed?.next)) content.next = claimed.next;
  return { ...rest, cancelled: content };
}

/**
 * On a trip with changes, whether the next train (`job.legs[0]`) still comes for
 * you, by `cancellations()`: as `cancellationFor` has it for that train, where
 * you change to it and get off it. Null when it does, or there's none.
 */
export function connectionFor(job, cancelled) {
  const leg = Array.isArray(job?.legs) ? job.legs[0] : null;
  if (!leg?.live) return null;
  return cancellationFor({ live: leg.live, state: leg.state }, cancelled);
}

/**
 * The alert for the next train of a trip found cancelled ("Your 17:30
 * connection at Union is cancelled"), or running after all.
 */
export function connectionAlert(job, { back = false } = {}) {
  const change = job.state?.change;
  const time = Number.isFinite(change?.departure) ? `${torontoClock(change.departure)} ` : "";
  const station = typeof change?.station === "string" && change.station ? change.station : null;
  const train = `Your ${time}connection${station ? ` at ${station}` : ""}`;
  if (back) return { title: `${train} is running after all`, body: "It's no longer listed as cancelled." };
  return { title: `${train} is cancelled`, body: "Open GO Stations to plan another way there." };
}

/** How long after it was due to leave your station a cancelled train's Live Activity stays up. */
export const CANCELLED_FOR = 10 * 60;

/**
 * When a cancelled train's Live Activity ends: a while after it was due to leave
 * your station (or get to your stop, once you're on it), and never right after
 * you're told.
 */
export function cancelledUntil(job, verdict, now) {
  const stops = list(job.state?.stops);
  const last = stops.length - 1;
  const boarding = clamp(job.state?.boardingIndex ?? 0, 0, Math.max(last, 0));
  const destination = clamp(job.state?.destinationIndex ?? last, boarding, Math.max(last, 0));
  const due = verdict?.left ? arrivalAt(stops, destination) : job.live?.scheduled?.[boarding] ?? stops[boarding]?.time;
  return Math.max(Number.isFinite(due) ? due + CANCELLED_FOR : now, now + CANCELLED_FOR);
}

/**
 * The alert for a tracked train found cancelled: "Your 11:48 train is
 * cancelled" ("It won't stop at Port Credit."), or once you're on it, that it
 * won't stop where you get off. `back`: the cancellation was lifted, "Your 11:48
 * train is running after all".
 */
export function cancelAlert(job, verdict, { back = false } = {}) {
  const stops = list(job.state?.stops);
  const last = stops.length - 1;
  const boarding = clamp(job.state?.boardingIndex ?? 0, 0, Math.max(last, 0));
  const leaves = job.live?.scheduled?.[boarding] ?? stops[boarding]?.time;
  const train = Number.isFinite(leaves) ? `Your ${torontoClock(leaves)} train` : "Your train";
  if (back) {
    return { title: `${train} is running after all`, body: "It's no longer listed as cancelled." };
  }
  const find = "Open GO Stations to find another train.";
  if (!verdict || verdict.all) return { title: `${train} is cancelled`, body: find };
  if (verdict.index !== boarding) {
    return { title: `${train} won't stop at ${verdict.name}`, body: find };
  }
  return { title: `${train} is cancelled`, body: `It won't stop at ${verdict.name}. ${find}` };
}
