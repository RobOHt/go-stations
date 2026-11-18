// What the worker does with GO's data on a bad day: feeds down, frozen, sending a
// web page instead of data, or the same thing in another shape (one object where
// there's usually a list, numbers as text, enums as numbers, a train listed twice,
// reports out of order). Written from what a rider should see, before looking at
// how the worker handles each one; then the same again with random junk mixed in,
// checking what must always hold. A made-up commuter from Oakville to Union.
// Run with: node --test worker/test/*.test.js
import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

// "cloudflare:workers" is only there on Cloudflare: a stand-in DurableObject.
const stub = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
register("data:text/javascript," + encodeURIComponent(`
  export async function resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") {
      return { url: "data:text/javascript," + encodeURIComponent(${JSON.stringify(stub)}), shortCircuit: true };
    }
    return next(specifier, context);
  }`));
const { default: worker, LiveActivities } = await import("../src/index.js");
const { cancellationFor, cancellations, follow, mergeTrains, torontoOffset } = await import("../src/live.js");

// --- The day, the trip, and stand-ins for GO and Apple ---------------------------

// 2026-11-13 in Toronto (EST, UTC-5).
const at = (clock, day = 13) => {
  const [h, m, s = 0] = clock.split(":").map(Number);
  return Date.UTC(2026, 10, day, h + 5, m, s) / 1000;
};
/** A time as GO's feeds write it: Toronto wall clock, "2026-11-13 07:40:00". */
const stamp = (t) => new Date((t - 5 * 3600) * 1000).toISOString().replace("T", " ").slice(0, 19);

// Lakeshore West 1925 (made up): Aldershot 07:10 to Union 08:00, from Oakville (07:40).
const codes = ["AL", "BU", "OA", "CL", "PO", "UN"];
const names = ["Aldershot", "Burlington", "Oakville", "Clarkson", "Port Credit", "Union"];
const planned = ["07:10", "07:22", "07:40", "07:45", "07:51", "08:00"].map((t) => at(t));
const LIVE_TOKEN = "ab".repeat(32);
const DEVICE = "cd".repeat(32);

function job(extra = {}) {
  return {
    token: LIVE_TOKEN,
    environment: "production",
    state: {
      departure: planned[2], arrival: planned[5], hasDeparted: false, platform: "2",
      stops: names.map((name, i) => ({ name, time: planned[i] })),
      boardingIndex: 2, destinationIndex: 5, awaitsTrain: true,
    },
    times: [],
    end: planned[5],
    dismissal: planned[5] + 15 * 60,
    live: { trip: "1925", codes: [...codes], scheduled: [...planned] },
    alerts: true,
    quiet: false,
    legs: [],
    device: DEVICE,
    ...extra,
  };
}

/** One train in /v1/live/trains, as mergeTrains() lists it. */
const report = (time, status, stop, extra = {}) =>
  ({ trip: "1925", line: "LW", lat: 43.45, lon: -79.68, time: at(time), status, stop, ...extra });

/** One train in GO's GTFS vehicle positions. */
function vehicle(trip, { time, status = "STOPPED_AT", stop = "OA", lat = 43.4561, lon = -79.6812, line = "LW" } = {}) {
  return {
    id: `v-${trip}`,
    vehicle: {
      trip: { trip_id: `20261113-${line}-${trip}` },
      position: { latitude: lat, longitude: lon },
      timestamp: time, current_status: status, stop_id: stop,
    },
  };
}

/** One train in Service at a Glance. */
const glanceTrip = (trip, extra = {}) => ({
  TripNumber: trip, LineCode: "LW", Latitude: 43.47, Longitude: -79.66, IsInMotion: true, DelaySeconds: 120,
  Course: 60, AtStationCode: null, ModifiedDate: stamp(now - 10), ...extra,
});
const glanceFeed = (trips) => ({ Metadata: { TimeStamp: stamp(now), ErrorCode: "200" }, Trips: { Trip: trips } });

let now = at("06:50");
Date.now = () => now * 1000;

const KEY = "test-key-5150";
const env = { METROLINX_API_KEY: KEY };

/** What GO answers this test: (path, url, init) → Response; throwing is no answer at all. */
let upstream = () => json({});
let calls = [];
let pushes = [];

const json = (body, init = {}) =>
  new Response(JSON.stringify(body), { status: 200, ...init, headers: { "Content-Type": "application/json", ...init.headers } });

globalThis.fetch = async (url, init = {}) => {
  const target = new URL(url);
  if (target.hostname === "api.openmetrolinx.com") {
    calls.push({ url: target, init });
    return upstream(target.pathname.replace("/OpenDataAPI/api/V1", ""), target, init);
  }
  if (target.hostname.endsWith("push.apple.com")) {
    pushes.push({ to: target.pathname.split("/").pop(), type: init.headers["apns-push-type"], body: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  }
  throw new Error(`Unexpected fetch: ${url}`);
};

const get = (path, init) => worker.fetch(new Request(`https://worker.test/v1${path}`, init), env);

/** How long a response may be kept (by the app's URL cache, or any cache on the way), in seconds. */
function keptFor(response) {
  const control = response.headers.get("Cache-Control") ?? "";
  if (/no-store|no-cache|private/i.test(control)) return 0;
  const age = /(?:s-)?max-age=(\d+)/i.exec(control);
  return age ? Number(age[1]) : 0;
}

const nextService = () => ({
  Metadata: { TimeStamp: stamp(now), ErrorCode: "200", ErrorMessage: "OK" },
  NextService: { Lines: [{
    StopCode: "OA", LineCode: "LW", LineName: "Lakeshore West", ServiceType: "T", DirectionCode: "E",
    DirectionName: "LW - Union Station", ScheduledDepartureTime: stamp(planned[2]),
    ComputedDepartureTime: stamp(planned[2] + 120), DepartureStatus: "I", ScheduledPlatform: "2",
    ActualPlatform: "", TripOrder: 1, TripNumber: "1925", UpdateTime: stamp(now), Status: "S",
  }] },
});

// --- The proxy -------------------------------------------------------------------

test("only the feeds the app reads are passed on to GO", async () => {
  now = at("07:00");
  calls = [];
  upstream = () => json(nextService());
  for (const path of ["/Stop/All", "/Fleet/Consist/All", "/Stop/NextService/UN/../../../Fleet/Consist/All",
    `/Stop/NextService/${"X".repeat(40)}`, "/", ""]) {
    const response = await get(path);
    assert.ok(response.status >= 400 && response.status < 500, `${path || "(nothing)"}: ${response.status}`);
  }
  const posted = await get("/Stop/NextService/OA", { method: "POST", body: "{}" });
  assert.ok(posted.status >= 400 && posted.status < 500, `POST: ${posted.status}`);
  assert.equal(calls.length, 0, "nothing was sent to GO");
});

test("the app can't swap in a key of its own", async () => {
  now = at("07:01");
  calls = [];
  upstream = () => json(nextService());
  const response = await get("/Stop/NextService/OA?key=someone-elses&key=another");
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].url.searchParams.getAll("key"), [KEY]);
});

test("a good answer goes to the app as it came, kept a few seconds", async () => {
  now = at("07:02");
  upstream = () => json(nextService());
  const response = await get("/Stop/NextService/OA");
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), nextService());
  const kept = keptFor(response);
  assert.ok(kept > 0 && kept <= 60, `kept for ${kept} s`);
});

test("GO failing: the app is told it failed, and nothing is kept", async () => {
  now = at("07:03");
  for (const status of [500, 502, 503, 504, 429, 404, 401, 403]) {
    // As an error page might come: with headers saying to keep it for an hour.
    upstream = () => json({ Message: "An error has occurred." }, { status, headers: { "Cache-Control": "public, max-age=3600" } });
    const response = await get("/Stop/NextService/OA");
    assert.ok(!response.ok, `GO's ${status}: the app got ${response.status}`);
    assert.equal(keptFor(response), 0, `GO's ${status}: kept for ${keptFor(response)} s`);
  }
  // GO turning the worker's key down isn't the app's fault: a server error.
  for (const status of [401, 403]) {
    upstream = () => json({ Message: "Authorization has been denied for this request." }, { status });
    const response = await get("/Stop/NextService/OA");
    assert.ok(response.status >= 500, `GO's ${status}: the app got ${response.status}`);
  }
});

test("a web page or half an answer instead of data: the app is told it failed, and it isn't kept", async () => {
  now = at("07:04");
  const odd = [
    () => new Response("<html><body>Down for maintenance</body></html>", { status: 200, headers: { "Content-Type": "text/html" } }),
    () => new Response("", { status: 200, headers: { "Content-Type": "application/json" } }),
    () => new Response('{"Metadata":{"ErrorCode":"200"},"NextService":{"Li', { status: 200, headers: { "Content-Type": "application/json" } }),
    () => new Response("null", { status: 200, headers: { "Content-Type": "application/json" } }),
  ];
  for (const [i, answer] of odd.entries()) {
    upstream = answer;
    const response = await get("/Stop/NextService/OA");
    assert.ok(!response.ok, `answer ${i}: the app got ${response.status}`);
    assert.equal(keptFor(response), 0, `answer ${i}: kept for ${keptFor(response)} s`);
  }
});

test("no answer from GO at all: the app is told it failed", async () => {
  now = at("07:05");
  upstream = () => { throw new TypeError("fetch failed"); };
  const response = await get("/Stop/NextService/OA");
  assert.ok(response.status >= 500, `the app got ${response.status}`);
  assert.equal(keptFor(response), 0);
});

test("the key never reaches the app, even when GO's error repeats the request", async () => {
  now = at("07:06");
  const leaks = [
    (path, url) => new Response(`Error processing ${url.href}`, { status: 500, headers: { "Content-Type": "text/plain" } }),
    (path, url) => json({ Message: "Bad request", Request: url.href }, { status: 400 }),
    (path, url) => { throw new Error(`connect ECONNREFUSED ${url.href}`); },
  ];
  for (const [i, leak] of leaks.entries()) {
    upstream = leak;
    const response = await get("/Stop/NextService/OA");
    const text = await response.text();
    assert.ok(!text.includes(KEY), `answer ${i} has the key: ${text}`);
    for (const [name, value] of response.headers) assert.ok(!value.includes(KEY), `answer ${i}: ${name} has the key`);
  }
});

test("not set up yet: says so, and asks GO nothing", async () => {
  now = at("07:07");
  calls = [];
  const response = await worker.fetch(new Request("https://worker.test/v1/Stop/NextService/OA"), {});
  assert.equal(response.status, 503);
  assert.equal(calls.length, 0);
});

// --- /v1/live/trains and /v1/live/cancelled ----------------------------------

test("one of the two position feeds failing: the trains the other has are still listed", async () => {
  now = at("08:00");
  upstream = (path) => {
    if (path === "/Gtfs/Feed/VehiclePosition") return new Response("busy", { status: 503 });
    if (path === "/ServiceataGlance/Trains/All") return json(glanceFeed([glanceTrip("1925")]));
    return new Response("not here", { status: 404 });
  };
  let response = await get("/live/trains");
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).trains.map((train) => train.trip), ["1925"]);

  now = at("09:00");
  upstream = (path) => {
    if (path === "/Gtfs/Feed/VehiclePosition") return json({ header: { timestamp: now }, entity: [vehicle("1925", { time: now - 5 })] });
    if (path === "/ServiceataGlance/Trains/All") return new Response("<html>Error</html>", { status: 500 });
    return new Response("not here", { status: 404 });
  };
  response = await get("/live/trains");
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).trains.map((train) => train.trip), ["1925"]);
});

test("both position feeds failing, or sending junk: the app isn't told no trains are running", async () => {
  const failing = [
    () => new Response("busy", { status: 503 }),
    () => new Response("<html><body>Down for maintenance</body></html>", { status: 200, headers: { "Content-Type": "text/html" } }),
    () => new Response('{"entity":[{"vehi', { status: 200, headers: { "Content-Type": "application/json" } }),
    () => { throw new TypeError("fetch failed"); },
  ];
  for (const [i, answer] of failing.entries()) {
    now = at("10:00") + i * 600;
    upstream = answer;
    const response = await get("/live/trains");
    const body = response.ok ? await response.json() : null;
    assert.ok(!(response.ok && body.trains?.length === 0), `answer ${i}: told no trains are running`);
    if (!response.ok) assert.equal(keptFor(response), 0, `answer ${i}: the failure kept for ${keptFor(response)} s`);
  }
});

test("one cancellation feed failing: the other's are still listed, saying which answered", async () => {
  now = at("12:00");
  upstream = (path) => {
    if (path === "/ServiceUpdate/Exceptions/Train") return new Response("busy", { status: 500 });
    if (path === "/Gtfs/Feed/TripUpdates") {
      return json({ entity: [{ trip_update: { trip: { trip_id: "20261113-LW-1925", schedule_relationship: "SCHEDULED" },
        stop_time_update: [{ stop_id: "OA", schedule_relationship: "SKIPPED" }] } }] });
    }
    return new Response("not here", { status: 404 });
  };
  const response = await get("/live/cancelled");
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.trips, [{ trip: "1925", day: "20261113", skips: ["OA"] }]);
  assert.deepEqual(body.from, ["updates"]);
});

test("neither cancellation feed answering: the app isn't told nothing is cancelled", async () => {
  // The app keeps the last list it had (for up to 10 minutes) when the worker fails,
  // and reads a list it's given as the whole truth.
  now = at("13:00");
  upstream = () => new Response("busy", { status: 503 });
  const response = await get("/live/cancelled");
  assert.ok(!response.ok, `the app got ${response.status}: ${await response.text()}`);
  assert.equal(keptFor(response), 0);
});

// --- Where the trains are: mergeTrains() --------------------------------------

test("a train listed twice: its newest report is the one used, whichever comes first", () => {
  now = at("07:41");
  const newer = vehicle("1925", { time: now - 5, status: "IN_TRANSIT_TO", stop: "CL", lat: 43.49 });
  const older = vehicle("1925", { time: now - 45, status: "STOPPED_AT", stop: "OA", lat: 43.45 });
  for (const entity of [[newer, older], [older, newer]]) {
    const { trains } = mergeTrains({ entity }, null, now);
    assert.equal(trains.length, 1);
    assert.equal(trains[0].time, now - 5);
    assert.equal(trains[0].stop, "CL");
    assert.equal(trains[0].status, "to");
  }
});

test("a report from the future isn't taken as just heard from", () => {
  now = at("07:41");
  const entity = [
    vehicle("1925", { time: now + 3600 }),
    // Milliseconds where GTFS has seconds.
    vehicle("1927", { time: now * 1000 }),
    vehicle("1929", { time: now - 5 }),
  ];
  const { trains } = mergeTrains({ entity }, null, now);
  for (const train of trains) assert.ok(train.time <= now + 60, `${train.trip} heard from at ${train.time - now} s from now`);
  assert.ok(trains.some((train) => train.trip === "1929"));
});

test("GTFS's numbers for where a train is: 1 standing at a station, 2 on its way, 0 pulling in", () => {
  now = at("07:41");
  const entity = [
    vehicle("1925", { time: now - 5, status: 1 }),
    vehicle("1927", { time: now - 5, status: 2 }),
    vehicle("1929", { time: now - 5, status: 0 }),
  ];
  const { trains } = mergeTrains({ entity }, null, now);
  assert.deepEqual(Object.fromEntries(trains.map((train) => [train.trip, train.status])), { 1925: "at", 1927: "to", 1929: "to" });
});

test("positions as text are read; positions no train could be at are left out", () => {
  now = at("07:41");
  const noLongitude = vehicle("1935", { time: now - 5 });
  delete noLongitude.vehicle.position.longitude;
  const entity = [
    vehicle("1925", { time: now - 5, lat: "43.4561", lon: "-79.6812" }),
    vehicle("1927", { time: now - 5, lat: 400, lon: -79.68 }),
    vehicle("1929", { time: now - 5, lat: 43.45, lon: -979.68 }),
    vehicle("1931", { time: now - 5, lat: null, lon: null }),
    vehicle("1933", { time: now - 5, lat: "", lon: "" }),
    noLongitude,
    // One of the two left at protobuf's default of 0.
    vehicle("1937", { time: now - 5, lat: 0, lon: -79.68 }),
    vehicle("1939", { time: now - 5, lat: 43.45, lon: 0 }),
  ];
  const { trains } = mergeTrains({ entity }, null, now);
  assert.deepEqual(trains.map((train) => train.trip), ["1925"]);
  assert.equal(trains[0].lat, 43.4561);
  assert.equal(trains[0].lon, -79.6812);
});

test("a delay from a Service at a Glance that stopped updating days ago isn't put on a fresh position", () => {
  now = at("07:41");
  const vehicles = { entity: [vehicle("1925", { time: now - 5 })] };
  const glance = glanceFeed([glanceTrip("1925", { DelaySeconds: 600, ModifiedDate: stamp(now - 2 * 86400) })]);
  const { trains } = mergeTrains(vehicles, glance, now);
  assert.equal(trains.length, 1);
  assert.equal(trains[0].delay, undefined, `a delay of ${trains[0].delay} s from two days ago`);
});

test("Service at a Glance's numbers and flags as text, and its trip number as a number", () => {
  now = at("07:41");
  const vehicles = { entity: [vehicle("1925", { time: now - 5 }), vehicle("1927", { time: now - 5 })] };
  const glance = glanceFeed([
    glanceTrip(1925, { DelaySeconds: "120", IsInMotion: "false", Course: "229.5" }),
    glanceTrip("1927", { DelaySeconds: 60, IsInMotion: "true", Course: 80 }),
  ]);
  const { trains } = mergeTrains(vehicles, glance, now);
  const byTrip = Object.fromEntries(trains.map((train) => [train.trip, train]));
  assert.equal(byTrip[1925].delay, 120);
  assert.equal(byTrip[1925].moving, false);
  assert.ok(Math.abs(byTrip[1925].course - 229.5) <= 1, `course ${byTrip[1925].course}`);
  assert.equal(byTrip[1927].moving, true);
});

test("one train where there's usually a list, in either feed", () => {
  now = at("07:41");
  const { trains } = mergeTrains({ entity: vehicle("1925", { time: now - 5 }) }, { Trips: { Trip: glanceTrip("1925") } }, now);
  assert.equal(trains.length, 1);
  assert.equal(trains[0].trip, "1925");
  assert.equal(trains[0].delay, 120);
});

test("junk where the feeds should be: no trains, and no crash", () => {
  now = at("07:41");
  const junk = [
    [undefined, undefined], [null, null], ["<html>", "<html>"], [[], []], [{ entity: "x" }, { Trips: "y" }],
    [{ entity: [null, 1, "a", {}, { vehicle: null }, { vehicle: { trip: null } }] }, { Trips: { Trip: [null, 1, {}, { TripNumber: null }] } }],
    [{ entity: { vehicle: { trip: { trip_id: 20261113 } } } }, { Trips: null, Metadata: null }],
  ];
  for (const [vehicles, glance] of junk) {
    const merged = mergeTrains(vehicles, glance, now);
    assert.deepEqual(merged.trains, [], JSON.stringify([vehicles, glance]));
  }
});

test("the clock change: the feed's Toronto times read the right side of it", () => {
  // 2026-11-01: 01:00 to 02:00 happens twice (EDT, then EST).
  const firstTime = Date.UTC(2026, 10, 1, 5, 31) / 1000; // 01:31 EDT
  const secondTime = Date.UTC(2026, 10, 1, 6, 31) / 1000; // 01:31 EST
  assert.equal(torontoOffset("2026-11-01 01:30:00", firstTime), 4 * 3600);
  assert.equal(torontoOffset("2026-11-01 01:30:00", secondTime), 5 * 3600);
  // 2026-03-08: 02:00 to 03:00 doesn't happen.
  const spring = Date.UTC(2026, 2, 8, 7, 6) / 1000; // 03:06 EDT
  assert.equal(torontoOffset("2026-03-08 03:05:00", spring), 4 * 3600);
  assert.equal(torontoOffset("2026-03-08 01:59:00", spring), 5 * 3600);
});

test("the clock change: a train heard from just before it isn't taken for one heard from an hour on", () => {
  // 01:00:30 EST, the second time round; the train last reported at 01:59:50 EDT, 40 s before.
  now = Date.UTC(2026, 10, 1, 6, 0, 30) / 1000;
  const glance = { Metadata: { TimeStamp: "2026-11-01 01:00:30", ErrorCode: "200" },
                   Trips: { Trip: [glanceTrip("1925", { ModifiedDate: "2026-11-01 01:59:50" })] } };
  const { trains } = mergeTrains(null, glance, now);
  assert.equal(trains.length, 1);
  assert.ok(Math.abs(trains[0].time - (now - 40)) <= 2, `heard from ${trains[0].time - now} s from now`);
});

// --- Following a tracked train: follow() ----------------------------------------

/** follow() on a copy of `current`: the result, and the job as it stands after. */
function step(current, train, t) {
  const result = follow(structuredClone(current), train, t);
  return { result, job: result?.job ?? current };
}

/** The tracked trip through a list of [report, time seen] pairs. */
function through(current, feed) {
  for (const [train, t] of feed) current = step(current, train, t).job;
  return current;
}

const states = (result) => [result?.state, result?.push?.state].filter(Boolean);

test("a report from a yard or a station not on the trip doesn't move the train along", () => {
  const before = through(job(), [[report("07:39:00", "to", "OA"), at("07:39:05")]]);
  for (const stop of ["GETW", "WR", null]) {
    const { job: after } = step(before, report("07:40:00", "at", stop), at("07:40:05"));
    assert.deepEqual(after.arr ?? {}, before.arr ?? {}, `${stop}: pulled in somewhere`);
    assert.deepEqual(after.dep ?? {}, before.dep ?? {}, `${stop}: left somewhere`);
  }
});

test("a report putting the train back where it's left, or an old one coming late, doesn't undo it", () => {
  const left = through(job(), [
    [report("07:39:50", "at", "OA"), at("07:39:55")],
    [report("07:41:10", "to", "CL"), at("07:41:15")],
  ]);
  const leftAt = left.dep?.[2];
  assert.ok(leftAt, "left Oakville");
  for (const [train, t] of [
    [report("07:42:10", "at", "OA"), at("07:42:15")], // a glitch puts it back at Oakville
    [report("07:39:50", "at", "OA"), at("07:41:35")], // the report from before it left, again
  ]) {
    const { result, job: after } = step(left, train, t);
    assert.equal(after.dep?.[2], leftAt);
    for (const state of states(result)) assert.equal(state.hasDeparted, true, "back to not having left");
  }
});

test("a report that doesn't say where the train is marks nothing", () => {
  for (const [status, stop] of [[null, null], [null, "OA"], ["at", null]]) {
    const { job: after } = step(job(), report("07:39:50", status, stop), at("07:39:55"));
    assert.deepEqual(after.arr ?? {}, {}, `${status} ${stop}`);
    assert.deepEqual(after.dep ?? {}, {}, `${status} ${stop}`);
  }
});

test("stops GO has no time for, and codes that don't line up with the stops: no crash, nothing broken pushed", () => {
  const holes = job();
  holes.live.scheduled = [planned[0], null, planned[2], null, null, planned[5]];
  holes.state.stops = holes.state.stops.map((stop, i) => ({ name: stop.name, time: holes.live.scheduled[i] }));
  const longer = job();
  longer.live.codes = [...codes, "NI"];
  longer.live.scheduled = [...planned, planned[5] + 600];
  const shorter = job();
  shorter.live.codes = codes.slice(0, 4);
  shorter.live.scheduled = planned.slice(0, 4);
  const problems = new Problems();
  for (const [name, start] of [["holes", holes], ["longer", longer], ["shorter", shorter]]) {
    let current = start;
    for (const [i, code] of codes.entries()) {
      for (const [offset, status] of [[-60, "to"], [-20, "at"], [40, "to"]]) {
        const t = planned[i] + offset + 120;
        const { result, job: after } = problems.run(() => step(current, report("00:00", status, code, { time: t, delay: 120 }), t + 5),
          `${name}, ${code} ${status}`) ?? { job: current };
        for (const state of states(result)) checkState(problems, state, `${name}, ${code} ${status}`);
        current = after;
      }
    }
  }
  problems.assertNone();
});

// --- Cancellations: cancellations() ----------------------------------------------

test("a train listed twice in the exceptions feed: both its stops count, and a cancellation in either", () => {
  const exceptions = { Trip: [
    { TripNumber: "1925", IsCancelled: "0", Stop: [{ Code: "PO", IsCancelled: "1" }] },
    { TripNumber: "1925", IsCancelled: "0", Stop: [{ Code: "CL", IsCancelled: "1" }] },
    { TripNumber: "1927", IsCancelled: "0", Stop: [{ Code: "PO", IsCancelled: "1" }] },
    { TripNumber: "1927", IsCancelled: "1", Stop: [] },
  ] };
  const list = cancellations(exceptions, null);
  // As the app reads them: every entry for the train together.
  const of = (trip) => list.filter((entry) => entry.trip === trip);
  assert.deepEqual([...new Set(of("1925").flatMap((entry) => entry.skips ?? []))].sort(), ["CL", "PO"]);
  assert.ok(of("1927").some((entry) => entry.all), JSON.stringify(list));
});

test("flags that mean no aren't read as cancelled, and ones that mean yes are", () => {
  for (const no of ["0", 0, false, "false", "False", "N", "", " ", null, undefined]) {
    const exceptions = { Trip: [{ TripNumber: "1925", IsCancelled: no, Stop: [{ Code: "OA", IsCancelled: no }] }] };
    assert.deepEqual(cancellations(exceptions, null), [], `${JSON.stringify(no)} read as cancelled`);
  }
  for (const yes of ["1", 1, true, "true", "True"]) {
    const exceptions = { Trip: [{ TripNumber: "1925", IsCancelled: yes, Stop: [] }, { TripNumber: "1927", IsCancelled: "0", Stop: [{ Code: "OA", IsCancelled: yes }] }] };
    assert.deepEqual(cancellations(exceptions, null), [{ trip: "1925", all: true }, { trip: "1927", skips: ["OA"] }], `${JSON.stringify(yes)} not read as cancelled`);
  }
});

test("the exceptions' trips as one object, stops with no code, trips with no number", () => {
  assert.deepEqual(cancellations({ Trip: { TripNumber: "1925", IsCancelled: "1" } }, null), [{ trip: "1925", all: true }]);
  const list = cancellations({ Trip: [
    { IsCancelled: "1" }, { TripNumber: "", IsCancelled: "1" }, { TripNumber: null, IsCancelled: "1" },
    { TripNumber: "1927", IsCancelled: "0", Stop: [{ IsCancelled: "1" }, { Code: "", IsCancelled: "1" }, null, { Code: "OA", IsCancelled: "1" }] },
  ] }, null);
  assert.deepEqual(list, [{ trip: "1927", skips: ["OA"] }]);
});

test("GTFS's numbers and words for a trip that won't run, and for a stop it has no news of", () => {
  const updates = { entity: [
    { trip_update: { trip: { trip_id: "20261113-LW-1925", schedule_relationship: 3 } } }, // CANCELED
    { trip_update: { trip: { trip_id: "20261113-LW-1927", schedule_relationship: "DELETED" } } },
    { trip_update: { trip: { trip_id: "20261113-LW-1929", schedule_relationship: 7 } } }, // DELETED
    { trip_update: { trip: { trip_id: "20261113-LW-1931", schedule_relationship: 0 },
      stop_time_update: [{ stop_id: "OA", schedule_relationship: 2 }, { stop_id: "CL", schedule_relationship: "NO_DATA" }] } },
  ] };
  const list = cancellations(null, updates);
  assert.deepEqual(list.map((entry) => [entry.trip, entry.all ?? false]).sort(), [["1925", true], ["1927", true], ["1929", true]]);
});

test("a stop skipped twice is listed once; numbers and codes with spaces round them are read", () => {
  const exceptions = { Trip: [{ TripNumber: " 1925 ", IsCancelled: "0", Stop: [{ Code: "OA", IsCancelled: "1" }, { Code: " OA ", IsCancelled: "1" }] }] };
  assert.deepEqual(cancellations(exceptions, null), [{ trip: "1925", skips: ["OA"] }]);
  const updates = { entity: [{ trip_update: { trip: { trip_id: "20261113-LW-1925", schedule_relationship: "SCHEDULED" },
    stop_time_update: [{ stop_id: "OA", schedule_relationship: "SKIPPED" }, { stop_id: "OA", schedule_relationship: "SKIPPED" }] } }] };
  assert.deepEqual(cancellations(null, updates), [{ trip: "1925", day: "20261113", skips: ["OA"] }]);
});

test("a tracked train looked up in a list with holes in it", () => {
  assert.equal(cancellationFor(job(), null), null);
  assert.equal(cancellationFor(job(), undefined), null);
  assert.equal(cancellationFor(job(), [{}, { trip: null }, { trip: "1925" }]), null);
  assert.deepEqual(cancellationFor(job(), [{}, { trip: "1925", day: "20261113", skips: ["OA"] }]), { index: 2, code: "OA", name: "Oakville" });
});

// --- The same, with random junk: what must always hold ------------------------
//
// Each test runs many seeded rounds and collects every kind of problem it finds
// (with the first round that showed it), rather than stopping at the first.

/** A seeded random source, so a round can be run again. */
function random(seed) {
  let s = seed >>> 0;
  const next = () => {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    chance: (p) => next() < p,
    pick: (list) => list[Math.floor(next() * list.length)],
    int: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)),
  };
}

/** The kinds of problem found, each with where it was first seen. */
class Problems {
  found = new Map();
  check(ok, kind, where) {
    if (!ok && !this.found.has(kind)) this.found.set(kind, typeof where === "function" ? where() : where);
    return ok;
  }
  /** Runs `body`, noting a crash as a problem. */
  run(body, where) {
    try {
      return body();
    } catch (error) {
      this.check(false, `throws ${error?.name}: ${String(error?.message).split("\n")[0]}`, where);
      return undefined;
    }
  }
  async runAsync(body, where) {
    try {
      return await body();
    } catch (error) {
      this.check(false, `throws ${error?.name}: ${String(error?.message).split("\n")[0]}`, where);
      return undefined;
    }
  }
  assertNone() {
    const list = [...this.found].map(([kind, where]) => `- ${kind}\n    first seen: ${where}`);
    assert.equal(list.length, 0, `\n${list.join("\n")}`);
  }
}

/** What a feed might send in place of a value. */
const ODD = [undefined, null, "", " ", "-", "null", "NaN", 0, -1, 1e15, NaN, Infinity, true, false, "true", {}, [], [null], "<html>"];
/** `good`, or now and then something odd in its place. */
const or = (r, good, p = 0.15) => (r.chance(p) ? r.pick(ODD) : good);
/** A list as feeds send it: usually a list; now and then one item alone, or junk. */
const listed = (r, items) => (r.chance(0.1) ? (items[0] ?? r.pick(ODD)) : r.chance(0.05) ? r.pick(ODD) : items);
const show = (value) => JSON.stringify(value, (key, v) => (typeof v === "number" && !Number.isFinite(v) ? String(v) : v));

function oddVehicles(r, t) {
  const entity = [];
  for (let i = 0, n = r.int(0, 8); i < n; i++) {
    if (r.chance(0.05)) { entity.push(r.pick(ODD)); continue; }
    const trip = String(r.int(1900, 1906));
    entity.push({
      id: or(r, `v${i}`),
      vehicle: or(r, {
        trip: or(r, { trip_id: or(r, r.pick([`20261113-LW-${trip}`, `20261113-LW-${trip}`, `LW-${trip}`, `20261113-41-${trip}`, Number(trip), "20261113-LW-"])) }),
        position: or(r, { latitude: or(r, r.pick([43.45, 43.51, "43.45", 0, 400])), longitude: or(r, r.pick([-79.68, -79.6, "-79.68", 0, -979.68])) }),
        timestamp: or(r, r.pick([t - 5, t - 30, t - 100, t - 400, t + 3600, t * 1000, String(t - 5), t - 3 * 86400])),
        current_status: or(r, r.pick(["STOPPED_AT", "IN_TRANSIT_TO", "INCOMING_AT", 0, 1, 2, "UNKNOWN"])),
        stop_id: or(r, r.pick(["OA", "CL", "GETW", "", 12345])),
      }),
    });
  }
  return r.chance(0.05) ? r.pick(ODD) : { header: or(r, { timestamp: t }), entity: listed(r, entity) };
}

function oddGlance(r, t) {
  const trips = [];
  for (let i = 0, n = r.int(0, 8); i < n; i++) {
    if (r.chance(0.05)) { trips.push(r.pick(ODD)); continue; }
    const trip = r.int(1900, 1906);
    trips.push({
      TripNumber: or(r, r.pick([String(trip), String(trip), trip])),
      LineCode: or(r, r.pick(["LW", "LW", "LE"])),
      Latitude: or(r, r.pick([43.5, 43.47, "43.5", 0])),
      Longitude: or(r, r.pick([-79.6, -79.66, "-79.6", 0])),
      IsInMotion: or(r, r.pick([true, false, "true", "false"])),
      DelaySeconds: or(r, r.pick([0, 120, -60, "120", 99999, 1.5])),
      Course: or(r, r.pick([90, "90", 229.5, 0])),
      AtStationCode: or(r, r.pick(["OA", null, ""])),
      ModifiedDate: or(r, r.pick([stamp(t - 10), stamp(t - 100), stamp(t - 400), stamp(t + 7200), stamp(t - 2 * 86400), "2026-13-45 99:99:99", "yesterday"])),
    });
  }
  return r.chance(0.05) ? r.pick(ODD)
    : { Metadata: or(r, { TimeStamp: or(r, stamp(t)), ErrorCode: or(r, "200") }), Trips: or(r, { Trip: listed(r, trips) }) };
}

const isTime = (value) => typeof value === "number" && Number.isFinite(value);
const isInt = (value) => Number.isInteger(value);

test("random junk in the position feeds: every train listed is one the app can draw", () => {
  // The app reads /v1/live/trains as { trip: String, line: String, lat, lon, time: Double,
  // status: String?, stop: String?, delay: Double?, moving: Bool?, course: Double? }:
  // one train it can't read loses it the whole list.
  const problems = new Problems();
  const t = at("07:41");
  for (let seed = 1; seed <= 3000; seed++) {
    const r = random(seed);
    const vehicles = oddVehicles(r, t);
    const glance = oddGlance(r, t);
    const merged = problems.run(() => mergeTrains(vehicles, glance, t), () => `seed ${seed}`);
    if (!problems.check(Array.isArray(merged?.trains), "no list of trains", `seed ${seed}`)) continue;
    for (const train of merged.trains) {
      const where = () => `seed ${seed}: ${show(train)}`;
      problems.check(typeof train.trip === "string" && /^[A-Za-z0-9]{1,12}$/.test(train.trip), "a trip number that isn't one", where);
      problems.check(typeof train.line === "string" && /^[A-Z]{2}$/.test(train.line), "a line code that isn't one", where);
      problems.check(isTime(train.lat) && Math.abs(train.lat) <= 90 && train.lat !== 0, "a latitude no train could be at", where);
      problems.check(isTime(train.lon) && Math.abs(train.lon) <= 180 && train.lon !== 0, "a longitude no train could be at", where);
      problems.check(isTime(train.time), "a time that isn't a number", where);
      problems.check(!(train.time > t + 60), "heard from in the future", where);
      problems.check(!(train.time < t - 300), "not heard from in five minutes, but listed", where);
      problems.check(["at", "to", null].includes(train.status), "a status that isn't at, to or null", where);
      problems.check(train.stop === null || (typeof train.stop === "string" && train.stop.trim() !== ""), "a stop that isn't a code or null", where);
      problems.check(train.delay === undefined || isTime(train.delay), "a delay that isn't a number", where);
      problems.check(train.moving === undefined || typeof train.moving === "boolean", "moving that isn't true or false", where);
      problems.check(train.course === undefined || isTime(train.course), "a course that isn't a number", where);
    }
    const trips = merged.trains.map((train) => train.trip);
    problems.check(new Set(trips).size === trips.length, "a train listed twice", () => `seed ${seed}: ${trips}`);
  }
  problems.assertNone();
});

const FLAGS = ["1", "0", 1, 0, true, false, "true", "false", "True", "False"];

function oddExceptions(r) {
  const trips = [];
  for (let i = 0, n = r.int(0, 6); i < n; i++) {
    if (r.chance(0.05)) { trips.push(r.pick(ODD)); continue; }
    const stops = [];
    for (let j = 0, m = r.int(0, 4); j < m; j++) {
      stops.push(r.chance(0.05) ? r.pick(ODD) : { Code: or(r, r.pick(["OA", "CL", "PO", "UN"])), IsCancelled: or(r, r.pick(FLAGS)) });
    }
    trips.push({ TripNumber: or(r, r.pick(["1925", "1927", 1925, "E647Q"])), IsCancelled: or(r, r.pick(FLAGS)),
                 IsOverride: or(r, r.pick(["0", "1"])), Stop: listed(r, stops) });
  }
  return r.chance(0.05) ? r.pick(ODD) : { Metadata: { ErrorCode: "200" }, Trip: listed(r, trips) };
}

function oddUpdates(r) {
  const entity = [];
  for (let i = 0, n = r.int(0, 6); i < n; i++) {
    if (r.chance(0.05)) { entity.push(r.pick(ODD)); continue; }
    const stops = [];
    for (let j = 0, m = r.int(0, 4); j < m; j++) {
      stops.push(r.chance(0.05) ? r.pick(ODD) : {
        stop_id: or(r, r.pick(["OA", "CL", "PO", "UN"])), stop_sequence: or(r, j + 1),
        schedule_relationship: or(r, r.pick(["SCHEDULED", "SKIPPED", "NO_DATA", 0, 1, 2])),
      });
    }
    entity.push({ id: or(r, `t${i}`), trip_update: or(r, {
      trip: or(r, { trip_id: or(r, r.pick(["20261113-LW-1925", "20261114-LW-1925", "20261113-LW-1927", "20261113-19-12345", "LW-1925"])),
                    schedule_relationship: or(r, r.pick(["SCHEDULED", "CANCELED", "ADDED", 0, 3])) }),
      stop_time_update: listed(r, stops),
    }) });
  }
  return r.chance(0.05) ? r.pick(ODD) : { header: { timestamp: at("07:41") }, entity: listed(r, entity) };
}

test("random junk in the cancellation feeds: every entry is one the app can read", () => {
  // The app reads /v1/live/cancelled as [{ trip: String, day: String?, all: Bool?,
  // skips: [String]? }]: one entry it can't read loses it the whole list.
  const problems = new Problems();
  for (let seed = 1; seed <= 3000; seed++) {
    const r = random(seed);
    const exceptions = oddExceptions(r);
    const updates = oddUpdates(r);
    const list = problems.run(() => cancellations(exceptions, updates), () => `seed ${seed}`);
    if (!problems.check(Array.isArray(list), "no list", `seed ${seed}`)) continue;
    for (const entry of list) {
      const where = () => `seed ${seed}: ${show(entry)}`;
      problems.check(typeof entry.trip === "string" && /^[A-Za-z0-9]{1,12}$/.test(entry.trip), "a trip number that isn't one", where);
      problems.check(entry.day === undefined || (typeof entry.day === "string" && /^\d{8}$/.test(entry.day)), "a day that isn't one", where);
      problems.check(entry.all === undefined || entry.all === true, "all that isn't true", where);
      problems.check(entry.skips === undefined || (Array.isArray(entry.skips) && entry.skips.every((code) => typeof code === "string")),
        "skips that aren't station codes", where);
      problems.check(entry.all === true || entry.skips?.length > 0, "an entry that cancels nothing", where);
    }
  }
  problems.assertNone();
});

/** Problems with a pushed Live Activity's content, as the app decodes it (TripActivityAttributes.ContentState). */
function checkState(problems, state, where) {
  problems.check(isTime(state?.departure), "departure isn't a time", where);
  problems.check(isTime(state?.arrival), "arrival isn't a time", where);
  problems.check(typeof state?.hasDeparted === "boolean", "hasDeparted isn't true or false", where);
  for (const field of ["minutesLate", "boardingIndex", "destinationIndex", "revision"]) {
    problems.check(state?.[field] == null || isInt(state[field]), `${field} isn't a whole number`, where);
  }
  problems.check(state?.platform == null || typeof state.platform === "string", "platform isn't text", where);
  problems.check(state?.awaitsTrain == null || typeof state.awaitsTrain === "boolean", "awaitsTrain isn't true or false", where);
  if (state?.stops != null && problems.check(Array.isArray(state.stops), "stops isn't a list", where)) {
    for (const stop of state.stops) {
      problems.check(typeof stop?.name === "string", "a stop with no name", where);
      problems.check(stop?.time == null || isTime(stop.time), "a stop's time isn't a time", where);
      problems.check(stop?.arrives == null || isTime(stop.arrives), "a stop's arrival isn't a time", where);
    }
  }
  if (state?.cancelled != null) {
    problems.check(state.cancelled.index == null || isInt(state.cancelled.index), "cancelled index isn't a whole number", where);
  }
  if (state?.change != null) {
    for (const field of ["station", "lineCode", "lineColorHex", "terminusName", "destinationName"]) {
      problems.check(typeof state.change[field] === "string", `change ${field} isn't text`, where);
    }
    problems.check(isTime(state.change.departure), "change departure isn't a time", where);
  }
  // NaN and Infinity go out as null, which the app can't read where it needs a number.
  problems.check(!/"(NaN|Infinity|-Infinity)"/.test(show(state)), "NaN or Infinity in it", where);
}

/** Where train 1925 really is at `t`, `late` seconds late: at a station from 30 s before its time until 30 s after. */
function truth(t, late) {
  if (t < planned[0] + late - 600) return null;
  for (const [i, time] of planned.entries()) {
    if (t < time + late - 30) return { status: "to", stop: codes[i] };
    if (t <= time + late + 30) return { status: "at", stop: codes[i] };
  }
  return null;
}

/**
 * Train 1925's reports, `late` seconds late, every 20 s from 07:00 to 08:15, some
 * of them odd in ways mergeTrains() lets through: at a yard or another line's
 * station, saying nothing of where it is, old ones coming late, the same one again,
 * missing, or with a delay of a day either way.
 */
function oddRun(r, late) {
  const feed = [];
  let previous;
  for (let t = at("07:00"); t <= at("08:15"); t += 20) {
    const real = truth(t, late);
    let train = real && { trip: "1925", line: "LW", lat: 43.45, lon: -79.68, time: t, ...real, delay: late, moving: real.status === "to" };
    if (train && r.chance(0.06)) train.stop = r.pick(["GETW", "WR", null, r.pick(codes)]);
    if (train && r.chance(0.04)) train.status = null;
    if (train && r.chance(0.05)) train.time = t - r.int(30, 600);
    if (train && r.chance(0.04)) train.delay = r.pick([99999, -99999, undefined]);
    if (r.chance(0.05) && previous) train = previous;
    if (r.chance(0.05)) train = undefined;
    feed.push([train ?? undefined, t + r.int(1, 6)]);
    if (train) previous = train;
  }
  return feed;
}

test("random odd reports while following a train: what's noted stays sane, and what's pushed can be shown", () => {
  const problems = new Problems();
  for (let seed = 1; seed <= 500; seed++) {
    const r = random(seed);
    let current = job({ state: { ...job().state, awaitsTrain: r.chance(0.5) } });
    if (r.chance(0.2)) {
      // Stops GO's trip has no time for.
      current.live.scheduled = current.live.scheduled.map((time, i) => (i === 0 || i === 2 || i === 5 || r.chance(0.5) ? time : null));
      current.state.stops = current.state.stops.map((stop, i) => ({ name: stop.name, time: current.live.scheduled[i] }));
    }
    const left = {};
    for (const [train, t] of oddRun(r, r.pick([0, 0, 60, 240, 600]))) {
      const where = () => `seed ${seed} at ${stamp(t).slice(11)}, given ${show(train)}`;
      const result = problems.run(() => follow(structuredClone(current), train, t), where);
      if (result == null) continue;
      current = result.job ?? current;
      for (const [map, name] of [[current.arr ?? {}, "pulled in"], [current.dep ?? {}, "left"]]) {
        for (const time of Object.values(map)) {
          problems.check(isTime(time), `${name} at a time that isn't one`, where);
          problems.check(!(time > t + 1), `${name} somewhere in the future`, where);
        }
      }
      const dep = current.dep ?? {};
      for (const i of Object.keys(left)) problems.check(dep[i] != null, "no longer left a stop it had left", where);
      for (const [i, time] of Object.entries(dep)) {
        left[i] = time;
        const arr = current.arr?.[i];
        problems.check(arr == null || time >= arr, "left a stop before it pulled in there", where);
        for (const [j, other] of Object.entries(dep)) {
          problems.check(!(Number(j) > Number(i) && other < time), "left a stop before the one before it", where);
        }
      }
      const seenLeaving = current.dep?.[2] != null || current.obs?.k > 2;
      for (const state of states(result)) {
        checkState(problems, state, where);
        problems.check(!(seenLeaving && state.hasDeparted === false), "seen leaving your station, then not having left", where);
      }
    }
  }
  problems.assertNone();
});

// --- The whole worker, with feeds misbehaving at random ---------------------------

class Storage {
  map = new Map();
  alarm = null;
  async list({ prefix }) {
    return new Map([...this.map].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => [key, structuredClone(value)]));
  }
  async get(key) { return structuredClone(this.map.get(key)); }
  async put(key, value) { this.map.set(key, structuredClone(value)); }
  async delete(key) { this.map.delete(key); }
  async setAlarm(ms) { this.alarm = ms; }
  async deleteAlarm() { this.alarm = null; }
}

const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const pushEnv = {
  METROLINX_API_KEY: KEY,
  APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`,
  APNS_KEY_ID: "KEY1234567",
  APPLE_TEAM_ID: "TEAM123456",
};

/** Problems with a push, as APNs takes it and the app reads it. */
function checkPush(problems, push, where) {
  if (push.type !== "liveactivity") return;
  const aps = push.body?.aps;
  problems.check(["update", "end"].includes(aps?.event), "an event that isn't update or end", where);
  problems.check(isInt(aps?.timestamp), "a timestamp that isn't whole seconds", where);
  for (const field of ["stale-date", "dismissal-date"]) {
    problems.check(aps?.[field] == null || isInt(aps[field]), `a ${field} that isn't whole seconds`, where);
  }
  if (aps?.alert != null) {
    problems.check(typeof aps.alert.title === "string" && typeof aps.alert.body === "string", "an alert without words", where);
  }
  checkState(problems, aps?.["content-state"], where);
}

/** A cancellation feed with only other trains in it (1925 cancelled would rightly end its tracking). */
const otherTrains = (feed) => JSON.parse(JSON.stringify(feed ?? null)?.replaceAll("1925", "1927") ?? "null");

test("feeds failing or sending junk at random while a train is tracked: the worker keeps following it, and every push can be shown", async () => {
  const problems = new Problems();
  for (let seed = 1; seed <= 40; seed++) {
    const r = random(seed);
    const late = r.pick([0, 120, 480]);
    const storage = new Storage();
    const object = new LiveActivities({ storage }, pushEnv);
    now = at("06:50");
    // GO, this time round: each feed answering well, failing, or sending junk.
    upstream = (path) => {
      const roll = r.int(0, 9);
      if (roll === 0) throw new TypeError("fetch failed");
      if (roll === 1) return new Response("busy", { status: r.pick([500, 502, 503, 429]) });
      if (roll === 2) return new Response("<html>Down for maintenance</html>", { status: 200, headers: { "Content-Type": "text/html" } });
      if (path === "/Gtfs/Feed/VehiclePosition") {
        const real = truth(now, late);
        const entity = real ? [vehicle("1925", { time: now - 5, status: real.status === "at" ? "STOPPED_AT" : "IN_TRANSIT_TO", stop: real.stop })] : [];
        if (roll === 3) return json(oddVehicles(r, now));
        return json({ header: { timestamp: now }, entity });
      }
      if (path === "/ServiceataGlance/Trains/All") {
        return json(roll === 3 ? oddGlance(r, now) : glanceFeed(truth(now, late) ? [glanceTrip("1925", { DelaySeconds: late })] : []));
      }
      if (path === "/ServiceUpdate/Exceptions/Train") return json(roll === 3 ? otherTrains(oddExceptions(r)) : { Metadata: { ErrorCode: "200" }, Trip: [] });
      if (path === "/Gtfs/Feed/TripUpdates") return json(roll === 3 ? otherTrains(oddUpdates(r)) : { entity: [] });
      return new Response("not here", { status: 404 });
    };
    await problems.runAsync(() => object.track(job()), `seed ${seed}: tracking`);
    for (let alarms = 0; storage.alarm != null && alarms < 800; alarms++) {
      now = Math.max(now, storage.alarm / 1000);
      if (now > at("09:30")) break;
      pushes = [];
      const where = `seed ${seed} at ${stamp(now).slice(11)}`;
      await problems.runAsync(() => object.alarm(), where);
      for (const push of pushes) checkPush(problems, push, () => `${where}: ${show(push.body)}`);
      // Still following it until it should have got in.
      problems.check(!(now < planned[5] + late - 120 && storage.alarm == null), "stopped following the train on its way", where);
    }
  }
  problems.assertNone();
});

test("one tracked trip the worker can't handle doesn't stop it for everyone else", async () => {
  now = at("07:20");
  upstream = (path) => {
    if (path === "/Gtfs/Feed/VehiclePosition") {
      const real = truth(now, 0);
      return json({ header: { timestamp: now }, entity: real ? [vehicle("1925", { time: now - 5, status: real.status === "at" ? "STOPPED_AT" : "IN_TRANSIT_TO", stop: real.stop })] : [] });
    }
    if (path === "/ServiceataGlance/Trains/All") return json(glanceFeed([]));
    if (path === "/ServiceUpdate/Exceptions/Train") return json({ Metadata: { ErrorCode: "200" }, Trip: [] });
    if (path === "/Gtfs/Feed/TripUpdates") return json({ entity: [] });
    return new Response("not here", { status: 404 });
  };
  // Someone else's trip, first in the list, that fails whenever the worker gets to
  // it (here, its every save).
  const BROKEN = "00".repeat(32);
  class Failing extends Storage {
    failing = false;
    async put(key, value) {
      if (this.failing && key === `job:${BROKEN}`) throw new Error("can't save this one");
      return super.put(key, value);
    }
  }
  const storage = new Failing();
  const object = new LiveActivities({ storage }, pushEnv);
  await object.track(job({ token: BROKEN }));
  await object.track(job());
  storage.failing = true;
  let updates = 0;
  for (let alarms = 0; storage.alarm != null && alarms < 300 && now < at("08:10"); alarms++) {
    now = Math.max(now, storage.alarm / 1000);
    pushes = [];
    await object.alarm().catch(() => {});
    updates += pushes.filter((push) => push.to === LIVE_TOKEN && push.type === "liveactivity").length;
  }
  assert.ok(updates >= 5, `${updates} updates for the trip that's fine`);
});
