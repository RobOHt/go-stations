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
const { LiveActivities } = await import("../src/index.js");

// 2026-11-13 in Toronto (EST, UTC-5).
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

// --- Stand-ins ---------------------------------------------------------------

let now = at("06:50");
Date.now = () => now * 1000;

const feeds = { failing: false, skips: [] };
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
      } }] });
    }
    if (path === "/Gtfs/Feed/VehiclePosition") return json({ entity: [] });
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
