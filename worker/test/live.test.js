// Tests for src/live.js, from what GO's feeds said about two trains one evening.
// Run with: node --test worker/test
import assert from "node:assert/strict";
import { test } from "node:test";
import { arrivalAt, follow, mergeTrains, torontoOffset } from "../src/live.js";

// 2026-11-06 in Toronto (EST, UTC-5).
const at = (clock) => {
  const [h, m, s = 0] = clock.split(":").map(Number);
  return Date.UTC(2026, 10, 7, h + 5 - 24, m, s) / 1000;
};
const clock = (t) => new Date((t - 5 * 3600) * 1000).toISOString().slice(11, 19);

test("merges vehicle positions with Service at a Glance, trains only", () => {
  const now = at("21:00:16");
  const vehicles = {
    entity: [
      { vehicle: { trip: { trip_id: "20261106-41-41650" }, position: { latitude: 43.7, longitude: -79.2 }, timestamp: now - 10,
                   current_status: "INCOMING_AT", stop_id: "00358" } },
      { vehicle: { trip: { trip_id: "20261106-LW-1033" }, position: { latitude: 43.4561768, longitude: -79.68119 },
                   timestamp: at("21:00:07"), current_status: "STOPPED_AT", stop_id: "OA" } },
      { vehicle: { trip: { trip_id: "20261106-LW-1034" }, position: { latitude: 43.63479, longitude: -79.4715958 },
                   timestamp: at("21:00:03"), current_status: "IN_TRANSIT_TO", stop_id: "EX" } },
    ],
  };
  const glance = {
    Metadata: { TimeStamp: "2026-11-06 21:00:16", ErrorCode: "200" },
    Trips: { Trip: [
      { TripNumber: "1033", LineCode: "LW", Latitude: 43.456176, Longitude: -79.68119, IsInMotion: false, DelaySeconds: -20,
        Course: 229.0, AtStationCode: "OA", ModifiedDate: "2026-11-06 20:59:41" },
      { TripNumber: "3034", LineCode: "GT", Latitude: 43.643235, Longitude: -79.386355, IsInMotion: true, DelaySeconds: -162,
        Course: 80, AtStationCode: null, ModifiedDate: "2026-11-06 21:00:21" },
      { TripNumber: "9999", LineCode: "LE", Latitude: 43.7, Longitude: -79.3, IsInMotion: true, DelaySeconds: 0,
        AtStationCode: null, ModifiedDate: "2026-11-06 20:40:00" },
    ] },
  };
  const { trains } = mergeTrains(vehicles, glance, now);
  assert.deepEqual(trains.map((t) => t.trip), ["1033", "1034", "3034"]);
  assert.deepEqual(trains[0], { trip: "1033", line: "LW", lat: 43.456177, lon: -79.68119, time: at("21:00:07"),
                                status: "at", stop: "OA", delay: -20, moving: false, course: 229 });
  assert.equal(trains[1].status, "to");
  assert.equal(trains[1].delay, undefined);
  // Only in Service at a Glance: kept where it says, with its time as real time.
  assert.equal(trains[2].time, at("21:00:21"));
  assert.equal(trains[2].status, null);
});

test("Toronto's offset from the feed's own clock, and without it", () => {
  assert.equal(torontoOffset("2026-11-06 21:00:16", at("21:00:20")), 5 * 3600);
  assert.equal(torontoOffset(undefined, at("21:00:20")), 5 * 3600);
  assert.equal(torontoOffset(undefined, Date.UTC(2026, 6, 1, 16) / 1000), 4 * 3600);
});

// Trip 1633 (Lakeshore West, westbound): tracked from Exhibition to Port Credit.
const codes = ["UN", "EX", "MI", "LO", "PO", "CL", "OA"];
const planned = ["20:47", "20:55", "21:03", "21:09", "21:16", "21:23", "21:30"].map(at);
const names = ["Union", "Exhibition", "Mimico", "Long Branch", "Port Credit", "Clarkson", "Oakville"];
const job = () => ({
  state: {
    departure: planned[1], arrival: planned[4], hasDeparted: true, platform: null,
    stops: names.map((name, i) => ({ name, time: planned[i] })),
    boardingIndex: 1, destinationIndex: 4, awaitsTrain: false,
  },
  live: { trip: "1633", codes, scheduled: planned },
  end: planned[4] - 60, dismissal: planned[4] + 14 * 60, summary: 15 * 60,
});
// What the vehicle feed said, and the delay Service at a Glance gave then.
const seen = [
  ["20:59:43", "to", "MI", -34], ["21:00:03", "to", "MI", -34], ["21:00:23", "to", "MI", -57],
  ["21:00:53", "to", "MI", -57], ["21:01:08", "to", "MI", -52], ["21:01:28", "at", "MI", -52],
  ["21:01:45", "at", "MI", -76], ["21:02:10", "at", "MI", -76], ["21:02:40", "at", "MI", -31],
  ["21:03:00", "at", "MI", -31], ["21:03:17", "at", "MI", 9], ["21:03:32", "at", "MI", 9],
  ["21:03:52", "at", "MI", 51], ["21:04:22", "to", "LO", 51], ["21:04:42", "to", "LO", 81],
  ["21:05:02", "to", "LO", 81], ["21:09:40", "to", "LO", 81], ["21:10:05", "at", "LO", 80],
  ["21:10:50", "to", "PO", 85], ["21:16:30", "to", "PO", 90], ["21:16:52", "at", "PO", 90],
].map(([time, status, stop, delay]) => ({ trip: "1633", line: "LW", lat: 43.6, lon: -79.5, time: at(time), status, stop, delay }));

/** Every 20 s from `from` to `to`, what the worker would do with the feed as it was 5 s before. */
function run(from, to) {
  let current = job();
  const pushes = [];
  for (let now = at(from); now <= at(to); now += 20) {
    const train = seen.filter((t) => t.time <= now - 5).at(-1);
    const result = follow(current, train, now);
    if (!result) continue;
    current = result.job;
    if (result.push) pushes.push({ now, ...result.push });
    if (result.push?.event === "end") break;
  }
  return { pushes, job: current };
}

test("pulls in, stands as long as it stands, leaves, and ends at your stop", () => {
  const { pushes, job: last } = run("20:59:50", "21:20:00");
  const trace = pushes.map(({ now, event, state, stale }) => {
    const s = state.stops;
    return `${clock(now)} ${event} MI ${s[2].arrives ? clock(s[2].arrives) : "-"}/${clock(s[2].time)} ` +
      `LO ${s[3].arrives ? clock(s[3].arrives) : clock(arrivalAt(s, 3))}/${clock(s[3].time)} ` +
      `PO ${clock(arrivalAt(s, 4))} stale ${stale ? clock(stale) : "-"}`;
  });
  console.log(trace.join("\n"));

  // First look: on its way to Mimico.
  assert.equal(pushes[0].now, at("20:59:50"));
  // In at Mimico as first seen there (each look sees the feed's latest), and not
  // gone before it's seen to leave.
  const inMimico = pushes.find((p) => p.state.stops[2].arrives);
  assert.ok(inMimico.state.stops[2].arrives >= at("21:01:28") && inMimico.state.stops[2].arrives <= at("21:01:45"));
  assert.ok(inMimico.now <= at("21:01:50"), "pushed as soon as it was seen in");
  for (const push of pushes.filter((p) => p.now < at("21:04:30") && p.now > at("21:01:40"))) {
    assert.ok(push.state.stops[2].time > push.now + 10, `still at Mimico at ${clock(push.now)}`);
  }
  // Left Mimico when seen on its way to Long Branch.
  const left = pushes.find((p) => p.state.stops[2].time === at("21:04:22"));
  assert.ok(left, "left Mimico when seen leaving");
  // Long Branch: at least as late as it left Mimico.
  assert.ok(arrivalAt(left.state.stops, 3) >= at("21:09:00") + 51 + 31 - 60);
  // Ended at Port Credit, when it got there.
  const end = pushes.at(-1);
  assert.equal(end.event, "end");
  assert.equal(end.state.stops[4].arrives, at("21:16:52"));
  assert.equal(end.state.arrival, at("21:16:52"));
  assert.ok(end.dismissal >= end.now + 14 * 60);
  // Not a push every look.
  assert.ok(pushes.length <= 14, `${pushes.length} pushes`);
  assert.equal(last.obs.k, 4);
});

test("an early train waits for its time; a late one is due any moment", () => {
  const { pushes } = run("20:59:50", "21:01:20");
  // Running early: still due at Mimico no earlier than a minute before it leaves.
  assert.ok(arrivalAt(pushes[0].state.stops, 2) >= at("21:02:00"));
  // Long after it should have got to Long Branch and still not there: any moment now.
  const { pushes: late } = run("21:05:00", "21:10:00");
  const overdue = late.filter((p) => p.state.stops[3].arrives && p.state.stops[3].arrives > p.now);
  assert.ok(overdue.length > 0, "re-timed when overdue");
  for (const push of overdue) assert.ok(push.state.stops[3].arrives - push.now <= 40);
});

test("nothing fresh: no push, and a followed trip ends well after it should have got in", () => {
  assert.equal(follow(job(), undefined, at("21:00:00")), null);
  const stale = { ...seen[0], time: at("20:50:00") };
  assert.equal(follow(job(), stale, at("21:00:00")), null);
  const followed = { ...job(), followed: true, end: at("21:15:00") };
  assert.equal(follow(followed, undefined, at("21:20:00")), null);
  assert.equal(follow(followed, undefined, at("21:26:00")).push.event, "end");
});

test("creeping along the platform doesn't count as leaving", () => {
  let current = job();
  current = follow(current, { ...seen[5] }, at("21:01:35")).job;
  const creeping = { ...seen[5], time: at("21:01:50"), status: "to", stop: "MI" };
  const result = follow(current, creeping, at("21:01:55"));
  assert.equal(result.job.obs.at, true);
  assert.equal(result.job.dep[2], undefined);
});

test("after a gap in the reports, a station it was seen at isn't left just now", () => {
  // In at Mimico, then nothing for ten minutes (the app or the feed away), then on
  // its way to Port Credit: it left Mimico somewhere in between, as timetabled.
  let current = follow(job(), { ...seen[5] }, at("21:01:35")).job;
  current = follow(current, { ...seen[6] }, at("21:01:50")).job;
  const later = { ...seen[18], time: at("21:12:00") };
  const result = follow(current, later, at("21:12:05"));
  assert.equal(result.job.dep[2], undefined);
  const stops = result.push.state.stops;
  assert.equal(stops[2].time, planned[2]);
  // Not taken to be 9 minutes late leaving Mimico: Port Credit as late as it runs.
  assert.ok(stops[4].time <= planned[4] + 90 + 60, clock(stops[4].time));
  // With the reports coming as they should, leaving is when it was seen to.
  let steady = follow(job(), { ...seen[12] }, at("21:03:55")).job;
  steady = follow(steady, { ...seen[13] }, at("21:04:25")).job;
  assert.equal(steady.dep[2], at("21:04:22"));
});
