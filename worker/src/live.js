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

  // Where it is, in this trip's stops: at or after where it was last seen.
  let index = train.stop ? codes.indexOf(train.stop, obs.k ?? 0) : -1;
  if (index < 0 && obs.k == null && train.stop) index = codes.indexOf(train.stop);
  if (index >= 0) {
    const sameStop = obs.k === index;
    if (train.status === "at") {
      if (!(obs.at && sameStop)) {
        if (obs.at && obs.k != null && obs.k < index) dep[obs.k] ??= train.time;
        arr[index] ??= train.time;
        Object.assign(obs, { k: index, at: true, since: train.time });
      }
    } else if (train.status === "to") {
      // Creeping along the platform it's at says "on its way to" that same station.
      if (!(obs.at && sameStop)) {
        if (obs.at && obs.k != null && obs.k < index) dep[obs.k] ??= train.time;
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
    stops[i].time = planned + late + extra;
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
