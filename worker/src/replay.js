// Where the app draws a train by its live reports: TrainReplay in the app
// (Departures/Views/TrainReplay.swift, as in build 148), line for line, so the
// watcher can replay what riders saw and score it. Times are seconds; distances
// are metres along the trip's run (see track.js).

import { Run } from "./track.js";

/** A train that moved less than this over the stretch its speed is measured over, in metres, is standing. */
export const STIRRING = 15;
/** A train's speed is measured over at least this long, in seconds... */
export const APART = 12;
/** ...and over no longer than this. */
export const WITHIN = 45;
/** In a train's first seconds in view: its speed from two reports at least this far apart. */
export const SOONEST = 4;
/** How far behind now the app draws a train, in seconds. */
export const DELAY = 10;
/** How hard a train slows for a station, and speeds up leaving one (m/s²), and its running speed (m/s). */
export const BRAKING = 0.3;
export const DEPARTING = 0.4;
export const CRUISING = 33;
/** How long past its latest report a train is carried on before it's held, in seconds. */
export const AHEAD = 40;
/** The hardest a train brakes (m/s²): it's carried on at least as far as that would take it. */
export const HARD = 1.0;
/** The map: a train drawn this many metres ahead of where it's now placed waits there while it moves. */
export const SLACK = 50;

/**
 * A train's reports (oldest first) as places along `run`, with what the latest
 * says: { samples, slopes, latest: { distance, speed, stop, isAt, away } }, or
 * null when none can be placed. `samples` are its reports on the run's track,
 * each later than the one before and never further back.
 */
export function track(reports, run) {
  const placed = [];
  for (const report of reports) {
    const sample = run.place(report, placed.length ? placed[placed.length - 1].stop : 0);
    if (!sample) continue;
    if (placed.length && sample.time <= placed[placed.length - 1].time) continue;
    placed.push(sample);
  }
  if (!placed.length) return null;
  const sample = placed[placed.length - 1];
  let speed = null;
  let before = null;
  for (let i = placed.length - 2; i >= 0; i--) {
    if (sample.time - placed[i].time >= APART) {
      before = placed[i];
      break;
    }
  }
  if (before) {
    if (sample.time - before.time <= WITHIN && sample.off <= Run.ON_TRACK && before.off <= Run.ON_TRACK) {
      const moved = Math.abs(sample.distance - before.distance);
      speed = moved < STIRRING ? 0 : moved / (sample.time - before.time);
    }
  } else if (placed.length >= 2 && sample.time - placed[0].time >= SOONEST &&
             sample.off <= Run.ON_TRACK && placed[0].off <= Run.ON_TRACK) {
    // Its first seconds in view: by the first report it has, once it has plainly moved since.
    const moved = Math.abs(sample.distance - placed[0].distance);
    if (moved >= STIRRING) speed = moved / (sample.time - placed[0].time);
  }
  const latest = { distance: sample.distance, speed, stop: sample.stop, isAt: sample.isAt, away: sample.off > Run.ON_TRACK };
  const samples = [];
  for (const entry of placed) {
    if (entry.off > Run.ON_TRACK) continue;
    const next = { ...entry };
    if (samples.length) next.distance = Math.max(next.distance, samples[samples.length - 1].distance);
    samples.push(next);
  }
  return { samples, slopes: slopes(samples), latest, moving: (speed ?? 0) > 0 };
}

/**
 * Where the train is drawn at `time` by `t` (its track): `delay` seconds behind,
 * gliding through its reports. Its latest report's place when it's off its track
 * (`away`), or nothing on the track to glide along.
 */
export function drawn(t, run, time, { delay = DELAY, clear = Run.CLEAR } = {}) {
  if (t.latest.away) return null;
  const metres = along(t.samples, t.slopes, t.moving, run, time - delay, clear);
  return metres ?? t.latest.distance;
}

/**
 * How far along `run` the train was at `time`, by its reports as placed along it
 * and its speed at each. `moving`: its latest reports have it measurably on the
 * move (it's carried on past them only then).
 */
export function along(samples, m, moving, run, time, clear = Run.CLEAR) {
  if (!samples.length || m.length !== samples.length) return null;
  const first = samples[0];
  const last = samples[samples.length - 1];
  if (time <= first.time) return first.distance;
  const count = samples.length;
  if (time < last.time) {
    let index = 0;
    while (index + 2 < count && samples[index + 1].time <= time) index++;
    const a = samples[index];
    const b = samples[index + 1];
    const h = b.time - a.time;
    if (!(h > 0)) return b.distance;
    const u = (time - a.time) / h;
    const u2 = u * u;
    const u3 = u2 * u;
    const distance = (2 * u3 - 3 * u2 + 1) * a.distance + (u3 - 2 * u2 + u) * h * m[index] +
      (-2 * u3 + 3 * u2) * b.distance + (u3 - u2) * h * m[index + 1];
    return Math.min(Math.max(distance, a.distance), b.distance);
  }
  // Past its latest report: carried on from there, at the pace it has there.
  let speed = Math.max(m[count - 1], 0);
  if (count >= 2) {
    const before = samples[count - 2];
    if (last.time > before.time) speed = Math.min(speed, (last.distance - before.distance) / (last.time - before.time));
  }
  if (!moving || !(speed > 0)) return last.distance;
  const horizon = Math.min(time - last.time, AHEAD);
  // However hard it brakes from here, it gets this far.
  const braked = Math.min(horizon, speed / HARD);
  const sure = last.distance + speed * braked - (HARD * braked * braked) / 2;
  // Otherwise no nearer the station it's heading for than `clear` short of its own spot.
  const spot = last.stop >= 0 && last.stop < run.starts.length ? run.starts[last.stop] : run.length;
  const goal = spot - clear;
  if (!(goal - last.distance > 0.5)) return sure;
  let speedingUp = 0;
  if (count >= 2 && m[count - 2] === 0) {
    // Just set off: from a standstill, speeding up as trains do.
    const gone = Math.max(last.distance - samples[count - 2].distance, 0);
    speed = Math.min(Math.max(m[count - 1], 0), Math.sqrt(2 * DEPARTING * gone));
    speedingUp = DEPARTING;
  }
  const top = Math.max(CRUISING, speed);
  let distance = last.distance;
  let elapsed = 0;
  while (elapsed < horizon) {
    const step = Math.min(0.5, horizon - elapsed);
    const room = goal - distance;
    if (room <= 0.5) {
      distance = goal;
      break;
    }
    const needed = (speed * speed) / (2 * room);
    const rate = needed >= BRAKING ? -needed : speed < top ? speedingUp : 0;
    const next = Math.max(speed + rate * step, 0);
    distance = Math.min(distance + ((speed + next) / 2) * step, goal);
    speed = next;
    elapsed += step;
  }
  return Math.max(distance, sure);
}

/**
 * The train's speed at each report, for a smooth curve through them that never
 * goes back or overshoots (Fritsch–Carlson, as in PCHIP): none where it didn't move.
 */
export function slopes(samples) {
  const count = samples.length;
  if (count < 2) return new Array(count).fill(0);
  const h = [];
  const d = [];
  for (let i = 0; i < count - 1; i++) {
    const span = samples[i + 1].time - samples[i].time;
    h.push(span);
    d.push(span > 0 ? (samples[i + 1].distance - samples[i].distance) / span : 0);
  }
  if (count === 2) return [d[0], d[0]];
  const m = new Array(count).fill(0);
  for (let k = 1; k < count - 1; k++) {
    if (!(d[k - 1] > 0 && d[k] > 0)) continue;
    const w1 = 2 * h[k] + h[k - 1];
    const w2 = h[k] + 2 * h[k - 1];
    m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k]);
  }
  const endSlope = (h0, h1, d0, d1) => {
    const slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1);
    if (slope * d0 <= 0) return 0;
    if (d0 * d1 <= 0 && Math.abs(slope) > 3 * Math.abs(d0)) return 3 * d0;
    return slope;
  };
  m[0] = endSlope(h[0], h[1], d[0], d[1]);
  m[count - 1] = endSlope(h[count - 2], h[count - 3], d[count - 2], d[count - 3]);
  return m;
}

/**
 * Where the map has the train after `distance` is worked out (NetworkMapView's
 * `settled`): a few metres behind where it was last drawn, while it moves, it
 * waits there for the train to catch up rather than being moved back.
 */
export function settle(distance, last, speed) {
  if (last != null && distance < last && last - distance < SLACK && speed !== 0) return last;
  return distance;
}
