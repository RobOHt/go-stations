// Tests for the watcher (src/watcher.js) and what it's made of: the app's track
// geometry and replay, ported (src/track.js, src/replay.js), the scoreboard
// (src/watch.js) and the recording (src/record.js). The port is checked against
// the app's own self-checks (SelfCheck.realArrival and gpsOnly), which were
// worked out by the Python script the replay was tried with. Made-up trains
// throughout. Run with: node --test worker/test/*.test.js
import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";
import { gunzipSync } from "node:zlib";

// "cloudflare:workers" is only there on Cloudflare: a stand-in DurableObject.
const stub = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
register("data:text/javascript," + encodeURIComponent(`
  export async function resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") {
      return { url: "data:text/javascript," + encodeURIComponent(${JSON.stringify(stub)}), shortCircuit: true };
    }
    return next(specifier, context);
  }`));
const { Run, Path, point, coordinate } = await import("../src/track.js");
const { track, along, drawn } = await import("../src/replay.js");
const { Scoreboard, tripCodes, direction, point: dataPoint, MODELS } = await import("../src/watch.js");
const { Recorder, Player } = await import("../src/record.js");
const { Watcher, network, archiveKey, nextLook } = await import("../src/watcher.js");
const { default: worker } = await import("../src/index.js");

// --- A made-up line: due east from AA through BB to CC, 0.05° of longitude apart ---

const codes = ["AA", "BB", "CC"];
const west = -79.60;
const apart = 0.05;
const latitude = 43.60;
const line = new Run(codes, (a, b) => new Path([
  point(latitude, west + apart * codes.indexOf(a)),
  point(latitude, west + apart * codes.indexOf(b)),
]));
const hop = line.starts[1];
const report = (along, { north = 0, status = "to", stop = "BB", time = 0 } = {}) =>
  ({ time, lat: latitude + north, lon: west + apart * along, status, stop });

test("the replay draws a real arrival where the app does (SelfCheck.realArrival)", () => {
  // How far short of CC each of a real train's reports had it, 15 s apart.
  const short = [5198, 5024, 4848, 4639, 4387, 4108, 3817, 3516, 3206, 2895, 2570, 2239, 1897, 1553,
    1221, 903, 599, 348, 249, 180, 111, 69, 66, 65, 65, 64];
  const start = 1_000_000;
  const reports = (count) => short.slice(0, count).map((s, i) =>
    ({ time: start + i * 15, lat: latitude, lon: west + apart * (line.length - s) / hop, status: "to", stop: "CC" }));
  // (Reports in, seconds after the first, metres short of CC: as the app's self-check has them.)
  for (const [count, after, expected] of [
    [2, 20, 4966.0], [5, 52, 4527.0], [5, 68, 4252.6], [12, 200, 1466.7], [12, 260, 1356.3], [16, 240, 629.0],
    [17, 255, 365.2], [18, 262, 267.7], [18, 275, 236.0], [19, 282, 247.8], [22, 308, 85.6], [26, 400, 64.0],
  ]) {
    const t = track(reports(count), line);
    const got = line.length - along(t.samples, t.slopes, t.moving, line, start + after);
    assert.ok(Math.abs(got - expected) < 1.5, `${count} reports, ${after} s: ${got.toFixed(1)} m short, not ${expected}`);
  }
});

test("a report is placed where its position is, as the app places it (SelfCheck.gpsOnly)", () => {
  const between = line.place(report(0.4));
  assert.ok(Math.abs(between.distance - 0.4 * hop) < 1 && between.stop === 1 && !between.isAt);
  const short = line.place(report(0.96, { status: "at" }));
  assert.ok(Math.abs(short.distance - 0.96 * hop) < 1 && short.stop === 1 && short.isAt);
  const signal = line.place(report(1.5, { stop: "SIG9" }));
  assert.ok(Math.abs(signal.distance - 1.5 * hop) < 1 && signal.stop === 2 && !signal.isAt);
  const unnamed = line.place(report(0.3, { status: null, stop: null }));
  assert.ok(Math.abs(unnamed.distance - 0.3 * hop) < 1 && unnamed.stop === 1);
  // Short of where the run starts, and past where it ends: straight on along the track.
  const waiting = line.place(report(-0.03, { status: "at", stop: "AA" }));
  assert.ok(Math.abs(waiting.distance + 0.03 * hop) < 1 && waiting.off < 1 && waiting.stop === 0 && waiting.isAt);
  const overrun = line.place(report(2.04, { status: "at", stop: "CC" }));
  assert.ok(Math.abs(overrun.distance - 2.04 * hop) < 1 && overrun.off < 1 && overrun.stop === 2 && overrun.isAt);
  // Far past the end (off to a yard): away from its line.
  assert.equal(track([report(2.2, { status: "at", stop: "CC" })], line).latest.away, true);
  // Off to one side: how far off.
  assert.ok(line.place(report(0.5, { north: 0.001 })).off > 100);
});

test("a train's speed is only what it covered between reports far enough apart", () => {
  const two = track([report(0.2, { time: 0 }), report(0.3, { time: 15 })], line);
  assert.ok(Math.abs(two.latest.speed - (0.1 * hop) / 15) < 0.1);
  assert.ok(Math.abs(drawn(two, line, 15 + 10) - 0.3 * hop) < 1, "drawn 10 s behind: at its latest report");
  assert.equal(track([report(0.2)], line).latest.speed, null, "one report: no speed made up");
  const pullingIn = track([report(0.97, { status: "at", time: 0 }), report(0.99, { status: "at", time: 15 })], line);
  assert.ok(pullingIn.latest.speed > 1, "GO says it's standing while it pulls in: as fast as it covers the ground");
  const standing = track([report(1, { status: "at", time: 0 }), report(1.0001, { status: "at", time: 15 })], line);
  assert.equal(standing.latest.speed, 0);
  assert.equal(standing.moving, false);
});

test("the replay matches the Python mirror it was tried with", () => {
  // Reports (time, metres along) on a straight line with the stop it's heading for at `spot`,
  // and what model5.along drew (with the clear zone, and without it as option A has it).
  const metre = point(latitude, -79.7 + 1).x - point(latitude, -79.7).x;
  const cases = [
    { t: [1010, 1020, 1035], x: [3000.4, 3248.9, 3622.1], spot: 4122.1, draws: [[1038, 250, 3692.2], [1045, 250, 3820.9], [1045, 0, 3839.9], [1080, 0, 4122.1]] },
    { t: [1005, 1020, 1030, 1045], x: [500, 504, 590, 860], spot: 6000, draws: [[1025, 250, 533.5], [1050, 250, 950.0], [1075, 250, 1400.0]] },
  ];
  for (const c of cases) {
    const run = new Run(["AA", "BB"], () => new Path([point(latitude, -79.7), point(latitude, -79.7 + c.spot / metre)]));
    const t = track(c.t.map((time, i) => ({ time, lat: latitude, lon: -79.7 + c.x[i] / metre, status: "to", stop: "BB" })), run);
    for (const [at, clear, expected] of c.draws) {
      const got = along(t.samples, t.slopes, t.moving, run, at, clear);
      assert.ok(Math.abs(got - expected) < 0.5, `at ${at} (clear ${clear}): ${got.toFixed(1)}, not ${expected}`);
    }
  }
});

test("a trip's stops come in calling order, across midnight, stations only", () => {
  const stop = (Code, time) => ({ Code, DepartureTime: { Scheduled: time } });
  const body = { Trips: [{ Number: "1999", Stops: [stop("PO", "00:12"), stop("UN", "23:40"), stop("XX9", "23:50"), stop("EX", "23:47"), stop("OA", "24:30")] }] };
  assert.deepEqual(tripCodes(body, (code) => network.station(code) != null), ["UN", "EX", "PO", "OA"]);
  assert.deepEqual(tripCodes({ Trips: { Trip: { Stops: [stop("UN", "08:00"), stop("EX", "08:05")] } } }, () => true), ["UN", "EX"]);
  assert.equal(tripCodes({ Trips: [{ Stops: [stop("UN", "08:00")] }] }, () => true), null);
  assert.equal(direction(["OA", "UN"]), "in");
  assert.equal(direction(["UN", "OA"]), "out");
  assert.equal(direction(["AL", "UN", "OS"]), "through");
  assert.equal(direction(["AA", "BB"]), "-");
});

// --- The scoreboard ----------------------------------------------------------------

/** Metres per degree of longitude along the made-up lines, on the app's projection. */
const perDegree = point(latitude, west + 1).x - point(latitude, west).x;
/** A longer made-up line, 40 km due east with no station between: a train can run on it for minutes. */
const long = new Run(["AA", "ZZ"], () => new Path([point(latitude, west), point(latitude, west + 0.5)]));

/**
 * A made-up train `at(t)` metres along `run`: its reports, seen `age` s after each, naming the
 * station it's heading for (or standing at), as GO's feed does.
 */
function scoreRun({ at, run = line, every = 10, age = 5, seconds = 600, start = 1_800_000_000 }) {
  const scored = [];
  const board = new Scoreboard({ startedAt: start, warmUp: 0, observer: (row) => scored.push(row) });
  const runOf = (train) => ({ key: `20270115|${train.trip}`, day: "20270115", line: "LW", run, codes: run.codes });
  for (let now = start; now <= start + seconds; now += 5) {
    // The newest report out by now.
    const time = Math.floor((now - age - start) / every) * every + start;
    if (time < start) continue;
    const metres = at(time - start);
    const standing = Math.abs(at(time - start + 1) - metres) < 0.1;
    const next = run.starts.findIndex((s) => s > metres - Run.PLATFORM);
    const train = { trip: "42", line: "LW", lat: latitude, lon: west + metres / perDegree, time, status: standing ? "at" : "to", stop: run.codes[next] };
    board.look({ trains: [train] }, now, runOf);
  }
  for (const train of board.trains.values()) {
    train.score(Infinity, true);
    board.collect(train, true, start + seconds);
  }
  return { scored, points: board.points() };
}

const mean = (rows) => rows.reduce((sum, row) => sum + row.error, 0) / rows.length;
/** Past its first minute in view (before that, like an app just opened, it has no speed yet). */
const settled = (rows) => rows.filter((row) => row.time >= 1_800_000_060);

test("the scoreboard: a train at a steady 20 m/s, each model where it should be", () => {
  const { scored, points } = scoreRun({ at: (t) => 1000 + 20 * t, run: long });
  const by = (model) => settled(scored.filter((row) => row.model === model));
  // Drawn 10 s behind: 200 m behind the train. Option A: on it. The newest fix: 5 to 15 s old, plus the app's lag.
  assert.ok(Math.abs(mean(by("today")) + 200) < 5, `today ${mean(by("today"))}`);
  assert.ok(Math.abs(mean(by("from_fix"))) < 5, `from_fix ${mean(by("from_fix"))}`);
  assert.ok(mean(by("newest")) < -250 && mean(by("newest")) > -400, `newest ${mean(by("newest"))}`);
  assert.ok(scored.every((row) => row.phase === "run" || row.phase === "out"));
  // One data point per train, minute, phase and model.
  const sample = points.find((p) => p.blobs[0] === "today" && p.blobs[2] === "run");
  assert.equal(sample.indexes[0], "today");
  assert.equal(sample.blobs.length, 10);
  assert.equal(sample.doubles.length, 16);
  assert.deepEqual(sample.blobs.slice(1, 6), ["LW", "run", "ZZ", "42", "-"]);
  assert.equal(sample.blobs[8], "ZZ");
  assert.ok(sample.doubles[0] >= 1 && sample.doubles[0] <= 60, "seconds scored in the minute");
  assert.ok(Math.abs(sample.doubles[2] / sample.doubles[0] + 200) < 5, "mean error from its sums");
  assert.equal(sample.doubles[15] % 60, 0, "the minute it's for");
  const seconds = points.filter((p) => p.blobs[0] === "today").reduce((sum, p) => sum + p.doubles[0], 0);
  assert.equal(seconds, scored.filter((row) => row.model === "today").length, "every second scored is in a data point");
});

test("the scoreboard: a standing train is drawn where it stands, by every model", () => {
  const { scored, points } = scoreRun({ at: () => 2000, seconds: 300 });
  assert.ok(scored.length > 100);
  assert.ok(scored.every((row) => Math.abs(row.error) < 0.5 && row.phase === "stand"));
  assert.ok(points.every((p) => p.doubles[8] === 0), "never moved back");
});

test("the scoreboard: braking into a station, today's model never runs ahead", () => {
  // 25 m/s, braking at 0.5 m/s² to stand at BB's own spot, then standing.
  const v = 25;
  const a = 0.5;
  const stopAt = hop;
  const brakeFrom = stopAt - (v * v) / (2 * a);
  const at = (t) => {
    const d = 1000 + v * t;
    if (d <= brakeFrom) return d;
    const u = t - (brakeFrom - 1000) / v;
    return u < v / a ? brakeFrom + v * u - (a * u * u) / 2 : stopAt;
  };
  const { scored } = scoreRun({ at, seconds: Math.ceil((brakeFrom - 1000) / v + v / a + 120) });
  const today = scored.filter((row) => row.model === "today");
  assert.ok(Math.max(...today.map((row) => row.error)) < 5, "today's model stays behind the train");
  assert.ok(today.some((row) => row.phase === "in") && today.some((row) => row.phase === "stand"));
  assert.ok(MODELS.every((model) => scored.some((row) => row.model === model)));
});

// --- The recording ---------------------------------------------------------------

const vehicle = (trip, time, lon) => ({
  id: trip, vehicle: { trip: { trip_id: `20270115-LW-${trip}` }, position: { latitude, longitude: lon }, timestamp: time, current_status: "IN_TRANSIT_TO", stop_id: "BB" },
});
const glanceTrip = (trip, modified) => ({ TripNumber: trip, LineCode: "LW", Latitude: latitude, Longitude: west, ModifiedDate: modified, DelaySeconds: 0 });

test("what's recorded plays back as the feeds were, look by look", () => {
  const recorder = new Recorder();
  const player = new Player();
  const looks = [
    [{ header: { timestamp: 100 }, entity: [vehicle("1", 95, -79.6), vehicle("2", 96, -79.5), { id: "bus", vehicle: { trip: { trip_id: "20270115-21-500" } } }] },
      { Metadata: { TimeStamp: "2027-01-15 08:00:00" }, Trips: { Trip: [glanceTrip("1", "2027-01-15 07:59:50")] } }],
    // Train 1 moved; train 2 the same; Service at a Glance the same.
    [{ header: { timestamp: 105 }, entity: [vehicle("1", 104, -79.59), vehicle("2", 96, -79.5)] },
      { Metadata: { TimeStamp: "2027-01-15 08:00:05" }, Trips: { Trip: [glanceTrip("1", "2027-01-15 07:59:50")] } }],
    // Train 2 gone; Service at a Glance didn't answer.
    [{ header: { timestamp: 110 }, entity: [vehicle("1", 109, -79.58)] }, null],
  ];
  const kinds = [];
  looks.forEach(([vehicles, glance], index) => {
    const lines = recorder.look(vehicles, glance, 1000 + index * 5, { full: index === 0 });
    kinds.push(lines.map((line) => line.k).join(","));
    for (const line of JSON.parse(JSON.stringify(lines))) player.apply(line);
    const feeds = player.feeds();
    assert.deepEqual(feeds.vehicles.entity.map((e) => e.vehicle.timestamp), vehicles.entity.filter((e) => e.id !== "bus").map((e) => e.vehicle.timestamp));
    assert.equal(feeds.glance === null, glance === null);
  });
  assert.deepEqual(kinds, ["tick,v,v,g", "tick,v", "tick,v,v-"]);
});

// --- The watcher itself ------------------------------------------------------------

class Storage {
  map = new Map();
  alarm = null;
  async get(key) { return structuredClone(this.map.get(key)); }
  async put(key, value) {
    if (typeof key === "object") for (const [k, v] of Object.entries(key)) this.map.set(k, structuredClone(v));
    else this.map.set(key, structuredClone(value));
  }
  async delete(keys) { for (const key of [].concat(keys)) this.map.delete(key); }
  async list({ prefix = "", start, end, limit = Infinity } = {}) {
    const keys = [...this.map.keys()].filter((k) => k.startsWith(prefix) && (start == null || k >= start) && (end == null || k < end)).sort();
    return new Map(keys.slice(0, limit).map((k) => [k, structuredClone(this.map.get(k))]));
  }
  async getAlarm() { return this.alarm; }
  async setAlarm(ms) { this.alarm = ms; }
  async deleteAlarm() { this.alarm = null; }
}

test("the watcher looks every 5 seconds, keeps what it saw for R2 an hour at a time, and scores", async () => {
  // Lakeshore West 1925 (made up), Oakville to Union at 25 m/s, a GPS fix every 10 s, 6 s old when out.
  const trip = ["OA", "CL", "PO", "LO", "MI", "EX", "UN"];
  const run = Run.on(network, "LW", trip);
  const place = (metres) => {
    let i = 0;
    while (i + 1 < run.paths.length && run.starts[i + 1] <= metres) i++;
    return coordinate(run.paths[i].pointAt(metres - run.starts[i]));
  };
  const start = Date.UTC(2027, 0, 15, 13, 50, 0) / 1000; // 08:50 in Toronto
  let now = start;
  const realNow = Date.now;
  Date.now = () => now * 1000;
  const asked = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const path = new URL(url).pathname.replace("/OpenDataAPI/api/V1", "");
    asked.push(path);
    const json = (body) => new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
    const fix = Math.floor((now - 6 - start) / 10) * 10 + start;
    const metres = 25 * (fix - start) + 500;
    const at = place(metres);
    const heading = trip[run.starts.findIndex((s) => s > metres - Run.PLATFORM)];
    if (path === "/Gtfs/Feed/VehiclePosition") {
      return json({ header: { timestamp: now }, entity: [{ id: "1", vehicle: { trip: { trip_id: "20270115-LW-1925" }, position: { latitude: at.latitude, longitude: at.longitude }, timestamp: fix, current_status: "IN_TRANSIT_TO", stop_id: heading } }] });
    }
    if (path === "/ServiceataGlance/Trains/All") return json({ Metadata: { ErrorCode: "200", TimeStamp: "2027-01-15 08:50:00" }, Trips: { Trip: [] } });
    if (path === "/Schedule/Trip/20270115/1925") {
      return json({ Metadata: { ErrorCode: "200" }, Trips: [{ Number: "1925", Stops: trip.map((Code, i) => ({ Code, DepartureTime: { Scheduled: `08:${50 + i}` } })) }] });
    }
    throw new Error(`unexpected ${url}`);
  };
  try {
    const storage = new Storage();
    const r2 = new Map();
    const written = [];
    const env = {
      METROLINX_API_KEY: "test",
      POSITIONS: { head: async (key) => (r2.has(key) ? {} : null), put: async (key, body, options) => r2.set(key, { body, options }) },
      SCORES: { writeDataPoint: (p) => written.push(p) },
    };
    const object = new Watcher({ storage }, env);
    assert.equal(await object.start(), true);
    assert.ok(storage.alarm != null, "started: an alarm is set");

    // Twenty minutes of looks, over the hour (09:00 in Toronto).
    while (now < start + 20 * 60) {
      now = Math.max(now, storage.alarm / 1000);
      await object.alarm();
      assert.equal(storage.alarm, nextLook(now * 1000), "the next look on the next 5-second mark");
    }
    assert.equal(asked.filter((p) => p.startsWith("/Schedule/Trip/")).length, 1, "the trip's stops, looked up once");

    // The hour before 09:00 went to R2 as one gzipped file, and its lines were forgotten.
    const key = archiveKey(Math.floor(start / 3600));
    assert.equal(key, "positions/2027/01/15/13.ndjson.gz");
    const file = r2.get(key);
    assert.ok(file, "the hour's file is in R2");
    const lines = gunzipSync(file.body).toString("utf8").trim().split("\n").map((row) => JSON.parse(row));
    assert.equal(lines[0].k, "meta");
    assert.equal(lines.filter((l) => l.k === "tick").length, 120, "ten minutes of looks");
    assert.ok(lines.find((l) => l.k === "tick").full, "it starts with all of both feeds");
    assert.ok(lines.some((l) => l.k === "trip" && l.trip === "1925" && l.codes.join() === trip.join()));
    assert.ok(lines.filter((l) => l.k === "v").length >= 55, "each new fix");
    const kept = [...storage.map.keys()].filter((k) => k.startsWith("rec:"));
    assert.ok(kept.length > 0 && kept.every((k) => Number(k.slice(4, 17)) >= (Math.floor(start / 3600) + 1) * 3600000),
      "only this hour's lines are still kept");

    // Scored, and written to Analytics Engine.
    assert.ok(written.length > 20);
    const today = written.filter((p) => p.blobs[0] === "today");
    const meanOff = today.reduce((s, p) => s + p.doubles[1], 0) / today.reduce((s, p) => s + p.doubles[0], 0);
    assert.ok(Math.abs(meanOff - 250) < 30, `today's model about 10 s (250 m) behind: ${meanOff}`);
    assert.ok(written.every((p) => p.blobs[1] === "LW" && p.blobs[4] === "1925" && p.blobs[5] === "in"));

    const status = await object.status();
    assert.equal(status.running, true);
    assert.equal(status.errors, 0);
    assert.equal(status.trips.known, 1);
    assert.equal(status.recording, true);
    assert.ok(status.flushed?.key === key);
    assert.ok(status.models.today.meanOff > 200);

    // GO not answering: the look fails, and the next one is still set.
    globalThis.fetch = async () => { throw new Error("offline"); };
    now = storage.alarm / 1000;
    await object.alarm();
    assert.equal(storage.alarm, nextLook(now * 1000));

    // WATCH = "off": it stops.
    env.WATCH = "off";
    assert.equal(await object.start(), false);
    assert.equal(storage.alarm, null);
  } finally {
    globalThis.fetch = realFetch;
    Date.now = realNow;
  }
});

test("every minute, the Worker makes sure the watcher is running", async () => {
  let started = 0;
  const waits = [];
  const env = { WATCHER: { idFromName: (name) => name, get: (id) => ({ start: async () => { started++; return id === "all"; } }) } };
  await worker.scheduled({ cron: "* * * * *" }, env, { waitUntil: (promise) => waits.push(promise) });
  assert.deepEqual(await Promise.all(waits), [true]);
  assert.equal(started, 1);
  // Without a watcher bound, nothing to do.
  await worker.scheduled({}, {}, { waitUntil: () => assert.fail("nothing to wait for") });
});
