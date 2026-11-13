// Tests for the LiveActivities Durable Object in src/index.js: a tracked train
// found cancelled, then running after all, or over; with GO's feeds and Apple's
// push service played by stand-ins, and the clock moved by hand. A made-up
// commuter from Oakville to Union. Run with: node --test worker/test/*.test.js
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

// 2026-11-13 in Toronto (EST, UTC-5). (On a trip with changes, the next train:
// Lakeshore East 9512, Union 08:10 to Danforth, also made up.)
const at = (clock) => {
  const [h, m, s = 0] = clock.split(":").map(Number);
  return Date.UTC(2026, 10, 13, h + 5, m, s) / 1000;
};
const clock = (t) => new Date((t - 5 * 3600) * 1000).toISOString().slice(11, 19);

// Lakeshore West 1925 (made up): Aldershot 07:10 to Union 08:00, tracked from Oakville (07:40).
const codes = ["AL", "BU", "OA", "CL", "PO", "UN"];
const names = ["Aldershot", "Burlington", "Oakville", "Clarkson", "Port Credit", "Union"];
const planned = ["07:10", "07:22", "07:40", "07:45", "07:51", "08:00"].map(at);
const LIVE_TOKEN = "ab".repeat(32);
const DEVICE = "cd".repeat(32);

const onCodes = ["UN", "DA", "SC", "GU", "RO"];
const onNames = ["Union", "Danforth", "Scarborough", "Guildwood", "Rouge Hill"];
const onPlanned = ["08:10", "08:16", "08:22", "08:27", "08:31"].map(at);
const change = {
  station: "Union", lineCode: "LE", lineColorHex: "EE3124", lineName: "Lakeshore East",
  departure: onPlanned[0], terminusName: "Rouge Hill", destinationName: "Danforth",
};

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
    live: { trip: "1925", codes, scheduled: planned },
    alerts: true,
    quiet: false,
    legs: [],
    device: DEVICE,
    ...extra,
  };
}

/** Oakville to Union, then at Union a change to the 08:10 to Danforth. */
function journey(extra = {}) {
  const first = job();
  return {
    ...first,
    state: { ...first.state, change },
    legs: [{
      state: {
        departure: onPlanned[0], arrival: onPlanned[1], hasDeparted: false,
        stops: onNames.map((name, i) => ({ name, time: onPlanned[i] })),
        boardingIndex: 0, destinationIndex: 1, awaitsTrain: false,
      },
      times: [], end: onPlanned[1], dismissal: onPlanned[1] + 900,
      live: { trip: "9512", codes: onCodes, scheduled: onPlanned },
    }],
    ...extra,
  };
}

// --- Stand-ins ---------------------------------------------------------------

let now = at("06:50");
Date.now = () => now * 1000;

// What GO's feeds say: where 1925 won't stop, the trains cancelled outright, and
// the trains' positions ([trip, status, stop]: reported as of now).
const feeds = { failing: false, skips: [], cancelledTrips: [], vehicles: [] };
let pushes = [];

const json = (body) => new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });

globalThis.fetch = async (url, init = {}) => {
  const target = new URL(url);
  if (target.hostname === "api.openmetrolinx.com") {
    if (feeds.failing) return new Response("busy", { status: 500 });
    const path = target.pathname.replace("/OpenDataAPI/api/V1", "");
    if (path === "/ServiceUpdate/Exceptions/Train") return json({ Metadata: { ErrorCode: "200" }, Trip: [] });
    if (path === "/Gtfs/Feed/TripUpdates") {
      return json({ entity: [{ trip_update: {
        trip: { trip_id: "20261113-LW-1925", schedule_relationship: "SCHEDULED" },
        stop_time_update: codes.map((code) => ({
          stop_id: code, schedule_relationship: feeds.skips.includes(code) ? "SKIPPED" : "SCHEDULED",
        })),
      } }, ...feeds.cancelledTrips.map((trip) => ({ trip_update: {
        trip: { trip_id: `20261113-LE-${trip}`, schedule_relationship: "CANCELED" }, stop_time_update: [],
      } }))] });
    }
    if (path === "/Gtfs/Feed/VehiclePosition") {
      return json({ entity: feeds.vehicles.map(([trip, status, stop]) => ({ vehicle: {
        trip: { trip_id: `20261113-LW-${trip}` }, position: { latitude: 43.45, longitude: -79.68 },
        timestamp: Math.floor(now), current_status: status, stop_id: stop,
      } })) });
    }
    if (path === "/ServiceataGlance/Trains/All") return json({ Metadata: { ErrorCode: "200" }, Trips: { Trip: [] } });
  }
  if (target.hostname.endsWith("push.apple.com")) {
    pushes.push({ to: target.pathname.split("/").pop(), type: init.headers["apns-push-type"], body: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  }
  throw new Error(`Unexpected fetch: ${url}`);
};

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
const env = {
  METROLINX_API_KEY: "test",
  APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`,
  APNS_KEY_ID: "KEY1234567",
  APPLE_TEAM_ID: "TEAM123456",
};

function activities() {
  const storage = new Storage();
  return { storage, object: new LiveActivities({ storage }, env) };
}

/** Moves the clock to the object's alarm and runs it: what it pushed. */
async function runAlarm({ storage, object }) {
  assert.ok(storage.alarm != null, "an alarm is set");
  now = Math.max(now, storage.alarm / 1000);
  pushes = [];
  await object.alarm();
  return pushes;
}

const stored = ({ storage }) => storage.map.get(`job:${LIVE_TOKEN}`);
const live = (sent) => sent.filter((push) => push.type === "liveactivity");

// --- The tests ---------------------------------------------------------------

test("a tracked train found cancelled says so, then running after all", async () => {
  now = at("06:50");
  feeds.skips = [];
  const target = activities();
  await target.object.track(job());

  // Looked up right away, then every couple of minutes until it's followed.
  assert.deepEqual(await runAlarm(target), []);
  assert.equal(clock(target.storage.alarm / 1000), "06:52:01");

  // GO says it won't stop at Oakville: the activity says so, with an alert, and
  // the app's woken to find the next train.
  feeds.skips = ["AL", "BU", "OA"];
  const sent = await runAlarm(target);
  assert.equal(sent.length, 2);
  const [update, wake] = sent;
  assert.equal(update.to, LIVE_TOKEN);
  assert.equal(update.body.aps.event, "update");
  assert.deepEqual(update.body.aps["content-state"].cancelled, { index: 2, station: "Oakville" });
  assert.deepEqual(update.body.aps.alert, {
    title: "Your 07:40 train is cancelled",
    body: "It won't stop at Oakville. Open GO Stations to find another train.",
    sound: "default",
  });
  assert.equal(clock(update.body.aps["stale-date"]), "07:50:00");
  assert.equal(wake.to, DEVICE);
  assert.equal(wake.type, "background");
  assert.deepEqual(wake.body.cancelled, { trip: "1925" });

  // The app tells the worker the same trip again (with the next train it found):
  // still cancelled, and no second alert.
  const again = job();
  again.state = { ...again.state, cancelled: { index: 2, station: "Oakville", next: at("08:10") } };
  await target.object.track(again);
  assert.ok(stored(target).cancelled);
  assert.deepEqual(await runAlarm(target), []);

  // Gone from the feeds: one look isn't enough...
  feeds.skips = [];
  assert.deepEqual(await runAlarm(target), []);
  assert.equal(stored(target).cleared, 1);
  // ...two are: running after all, said with an alert.
  const back = live(await runAlarm(target));
  assert.equal(back.length, 1);
  assert.equal("cancelled" in back[0].body.aps["content-state"], false);
  assert.equal(back[0].body.aps.alert.title, "Your 07:40 train is running after all");
  assert.equal(stored(target).cancelled, null);
});

test("a cancelled train's Live Activity ends a while after it was due", async () => {
  now = at("07:30");
  feeds.skips = ["OA"];
  const target = activities();
  await target.object.track(job());
  // In the window it's followed in: looked up with every look at it.
  const sent = live(await runAlarm(target));
  assert.equal(sent.length, 1);
  assert.ok(sent[0].body.aps.alert);
  assert.equal(stored(target).cancelledUntil, at("07:50"));

  // Looks every 20 seconds (for it running after all), and nothing pushed...
  for (let i = 0; i < 5; i++) {
    const before = now;
    assert.deepEqual(await runAlarm(target), []);
    assert.ok(target.storage.alarm / 1000 - before >= 19, "not looked again at once");
  }
  // ...until it ends, cancelled as it was.
  now = at("07:50");
  target.storage.alarm = now * 1000;
  const end = live(await runAlarm(target));
  assert.equal(end.length, 1);
  assert.equal(end[0].body.aps.event, "end");
  assert.deepEqual(end[0].body.aps["content-state"].cancelled, { index: 2, station: "Oakville" });
  assert.equal(stored(target), undefined);
  assert.equal(target.storage.alarm, null);
});

test("no alert when you asked not to be notified, and none for an earlier train cancelled", async () => {
  now = at("06:50");
  feeds.skips = ["OA"];
  const quiet = activities();
  await quiet.object.track(job({ quiet: true }));
  const sent = live(await runAlarm(quiet));
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].body.aps["content-state"].cancelled, { index: 2, station: "Oakville" });
  assert.equal(sent[0].body.aps.alert, undefined);

  // Where you get on is fine: it doesn't matter where else it won't stop. (A
  // minute on: the feeds are looked at afresh.)
  feeds.skips = ["AL", "BU"];
  now = at("06:51");
  const fine = activities();
  await fine.object.track(job());
  assert.deepEqual(await runAlarm(fine), []);
  assert.ok(!stored(fine).cancelled);
  assert.equal(stored(fine).cancelCheckedAt, now);
});

test("no answer from the feeds: the next look after the usual wait", async () => {
  now = at("06:50");
  feeds.failing = true;
  try {
    const target = activities();
    await target.object.track(job());
    for (let i = 0; i < 3; i++) {
      const before = now;
      assert.deepEqual(await runAlarm(target), []);
      assert.ok(target.storage.alarm / 1000 - before >= 119, `looked again at ${clock(target.storage.alarm / 1000)}`);
    }
  } finally {
    feeds.failing = false;
  }
});

test("the app's request: what it asks for the trip, and the list it reads", async () => {
  now = at("06:50");
  feeds.skips = ["OA"];
  const target = activities();
  const routed = { ...env, LIVE_ACTIVITIES: { idFromName: () => "all", get: () => target.object } };
  const body = { ...job({ quiet: true, told: true }), missedCheck: false };
  const response = await worker.fetch(new Request("https://worker.test/v1/activity", {
    method: "POST", body: JSON.stringify(body),
  }), routed);
  assert.equal(response.status, 204);
  const kept = stored(target);
  assert.equal(kept.quiet, true);
  assert.equal(kept.device, DEVICE);
  assert.equal(kept.missedCheck, undefined);
  // Told by the app already: no alert from the worker, just the activity.
  assert.equal(kept.cancelAlerted, true);
  const sent = await runAlarm(target);
  assert.equal(live(sent).length, 1);
  assert.equal(live(sent)[0].body.aps.alert, undefined);

  // GET /v1/live/cancelled: the trains the feeds have, cached half a minute.
  now += 60;
  const list = await worker.fetch(new Request("https://worker.test/v1/live/cancelled"), routed);
  assert.equal(list.status, 200);
  assert.equal(list.headers.get("Cache-Control"), "public, max-age=30");
  const listed = await list.json();
  assert.deepEqual(listed.trips, [{ trip: "1925", day: "20261113", skips: ["OA"] }]);
  assert.deepEqual(listed.from, ["exceptions", "updates"]);
});

test("on a trip with changes, the next train found cancelled says so on the change line, then running after all", async () => {
  now = at("06:40");
  feeds.skips = [];
  feeds.cancelledTrips = [];
  const target = activities();
  await target.object.track(journey());
  assert.deepEqual(await runAlarm(target), []);

  // GO cancels the 08:10 from Union: the change line says so, with an alert. (No
  // wake for the app: there's no next train for it to find, you plan another way.)
  feeds.cancelledTrips = ["9512"];
  const sent = await runAlarm(target);
  assert.equal(sent.length, 1);
  const state = sent[0].body.aps["content-state"];
  assert.deepEqual(state.change, { ...change, cancelled: true });
  assert.equal(state.cancelled, undefined);
  assert.deepEqual(sent[0].body.aps.alert, {
    title: "Your 08:10 connection at Union is cancelled",
    body: "Open GO Stations to plan another way there.",
    sound: "default",
  });

  // Still cancelled: nothing more, even when the app tells the worker the trip again.
  assert.deepEqual(await runAlarm(target), []);
  await target.object.track(journey());
  assert.ok(stored(target).connectionCancelled);
  assert.deepEqual(await runAlarm(target), []);

  // Gone from the feeds: one look isn't enough, two are.
  feeds.cancelledTrips = [];
  assert.deepEqual(await runAlarm(target), []);
  const back = await runAlarm(target);
  assert.equal(back.length, 1);
  assert.deepEqual(back[0].body.aps["content-state"].change, change);
  assert.equal(back[0].body.aps.alert.title, "Your 08:10 connection at Union is running after all");

  // Cancelled again: the change line says so, with no second alert for the same train.
  feeds.cancelledTrips = ["9512"];
  const again = await runAlarm(target);
  assert.equal(again.length, 1);
  assert.equal(again[0].body.aps["content-state"].change.cancelled, true);
  assert.equal(again[0].body.aps.alert, undefined);

  // Another next train (the app planned another way): what was said of the last one goes.
  const other = journey();
  other.legs[0].live = { ...other.legs[0].live, trip: "9514" };
  await target.object.track(other);
  assert.equal(stored(target).connectionCancelled, undefined);
  assert.equal(stored(target).connectionAlerted, undefined);
});

test("followed, the change line waits for the train's next report, alert and all", async () => {
  now = at("07:30");
  feeds.skips = [];
  feeds.cancelledTrips = [];
  feeds.vehicles = [["1925", "IN_TRANSIT_TO", "OA"]];
  try {
    const target = activities();
    await target.object.track(journey());
    // Followed from the first report.
    const first = await runAlarm(target);
    assert.equal(live(first).length, 1);
    assert.equal(stored(target).followed, true);

    // The 08:10 cancelled: one push, the train's own, with the alert.
    feeds.cancelledTrips = ["9512"];
    now += 40;
    const sent = await runAlarm(target);
    assert.equal(sent.length, 1);
    assert.deepEqual(sent[0].body.aps["content-state"].change, { ...change, cancelled: true });
    assert.equal(sent[0].body.aps.alert.title, "Your 08:10 connection at Union is cancelled");
    assert.equal(stored(target).connectionAlerted, true);
    assert.equal(stored(target).connectionAlertDue, undefined);
    // Nothing new after that.
    now += 40;
    assert.deepEqual(await runAlarm(target), []);

    // No report for a while: the alert waits for the next one.
    const quiet = activities();
    feeds.cancelledTrips = [];
    now = at("07:32");
    await quiet.object.track(journey());
    await runAlarm(quiet);
    feeds.vehicles = [];
    feeds.cancelledTrips = ["9512"];
    now += 40;
    assert.deepEqual(await runAlarm(quiet), []);
    assert.ok(stored(quiet).connectionAlertDue);
    feeds.vehicles = [["1925", "STOPPED_AT", "OA"]];
    now += 40;
    const late = await runAlarm(quiet);
    assert.equal(late.length, 1);
    assert.equal(late[0].body.aps.alert.title, "Your 08:10 connection at Union is cancelled");
  } finally {
    feeds.vehicles = [];
    feeds.cancelledTrips = [];
  }
});

test("no answer from the feeds: what the app said of its train stands meanwhile", async () => {
  now = at("06:50");
  feeds.failing = true;
  try {
    const target = activities();
    const claimed = job({ times: [at("06:55")] });
    claimed.state = { ...claimed.state, cancelled: { index: 2, station: "Oakville" } };
    await target.object.track(claimed);
    let sent = [];
    for (let i = 0; i < 6 && sent.length === 0; i++) sent = live(await runAlarm(target));
    assert.equal(clock(sent[0].body.aps.timestamp), "06:55:00");
    assert.deepEqual(sent[0].body.aps["content-state"].cancelled, { index: 2, station: "Oakville" });
  } finally {
    feeds.failing = false;
  }
});

test("the app's request for a trip with changes: told of the next train already", async () => {
  now = at("06:30");
  feeds.skips = [];
  feeds.cancelledTrips = ["9512"];
  try {
    const target = activities();
    const routed = { ...env, LIVE_ACTIVITIES: { idFromName: () => "all", get: () => target.object } };
    const body = { ...journey({ toldConnection: true }), state: { ...journey().state, change: { ...change, cancelled: true } } };
    const response = await worker.fetch(new Request("https://worker.test/v1/activity", {
      method: "POST", body: JSON.stringify(body),
    }), routed);
    assert.equal(response.status, 204);
    assert.equal(stored(target).connectionAlerted, true);
    assert.equal(stored(target).legs[0].live.trip, "9512");
    // Found cancelled by the worker too: the change line says so, with no alert.
    const sent = await runAlarm(target);
    assert.equal(sent.length, 1);
    assert.deepEqual(sent[0].body.aps["content-state"].change, { ...change, cancelled: true });
    assert.equal(sent[0].body.aps.alert, undefined);
  } finally {
    feeds.cancelledTrips = [];
  }
});
