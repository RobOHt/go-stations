// Tests for cancelled trains in src/live.js: what GO's feeds say about them, and
// what a tracked trip's Live Activity then shows. A made-up commuter from
// Oakville to Union. Run with: node --test worker/test/*.test.js
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CANCELLED_FOR, cancelAlert, cancellationFor, cancellations, cancelledContent, cancelledUntil, connectionAlert,
  connectionFor, nextLeg, serviceDay, shownState, torontoDay,
} from "../src/live.js";

// 2026-11-13 in Toronto (EST, UTC-5).
const at = (clock, day = 13) => {
  const [h, m, s = 0] = clock.split(":").map(Number);
  return Date.UTC(2026, 10, day, h + 5, m, s) / 1000;
};

// Lakeshore West 1925 (made up): Aldershot 07:10 to Union 08:00, from Oakville (07:40).
const codes = ["AL", "BU", "OA", "CL", "PO", "UN"];
const names = ["Aldershot", "Burlington", "Oakville", "Clarkson", "Port Credit", "Union"];
const planned = ["07:10", "07:22", "07:40", "07:45", "07:51", "08:00"].map((t) => at(t));

function job(extra = {}) {
  return {
    state: {
      departure: planned[2], arrival: planned[5], hasDeparted: false, platform: "2",
      stops: names.map((name, i) => ({ name, time: planned[i] })),
      boardingIndex: 2, destinationIndex: 5, awaitsTrain: true,
    },
    live: { trip: "1925", codes, scheduled: planned },
    ...extra,
  };
}

// Then at Union, a change to Lakeshore East 9512 (made up): Union 08:10 to Rouge
// Hill, getting off at Danforth (08:16).
const onCodes = ["UN", "DA", "SC", "GU", "RO"];
const onNames = ["Union", "Danforth", "Scarborough", "Guildwood", "Rouge Hill"];
const onPlanned = ["08:10", "08:16", "08:22", "08:27", "08:31"].map((t) => at(t));
const change = {
  station: "Union", lineCode: "LE", lineColorHex: "EE3124", lineName: "Lakeshore East",
  departure: onPlanned[0], terminusName: "Rouge Hill", destinationName: "Danforth",
};

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

test("cancellations from the exceptions feed and the GTFS trip updates together", () => {
  const exceptions = {
    Metadata: { ErrorCode: "200" },
    Trip: [
      // An override with nothing cancelled: not a cancellation.
      { TripNumber: "E647Q", IsCancelled: "0", IsOverride: "1", Stop: [{ Code: "UN", IsCancelled: "0" }] },
      // Not stopping at Port Credit (and running everywhere else).
      { TripNumber: "1925", IsCancelled: "0", Stop: [{ Code: "PO", IsCancelled: "1" }, { Code: "CL", IsCancelled: "0" }] },
      // The whole trip.
      { TripNumber: "1931", IsCancelled: "1", Stop: [] },
      // One stop, not in a list.
      { TripNumber: "1937", IsCancelled: false, Stop: { Code: "OA", IsCancelled: true } },
    ],
  };
  const updates = {
    entity: [
      // The first three stations skipped: only the trip updates say so for two of them.
      { trip_update: { trip: { trip_id: "20261113-LW-1925", schedule_relationship: "SCHEDULED" }, stop_time_update: [
        { stop_id: "AL", schedule_relationship: "SKIPPED" }, { stop_id: "BU", schedule_relationship: "SKIPPED" },
        { stop_id: "OA", schedule_relationship: "SKIPPED" }, { stop_id: "CL", schedule_relationship: "SCHEDULED" },
      ] } },
      { trip_update: { trip: { trip_id: "20261113-LE-9406", schedule_relationship: "CANCELED" }, stop_time_update: [] } },
      // Running as planned.
      { trip_update: { trip: { trip_id: "20261113-LW-1927", schedule_relationship: "SCHEDULED" }, stop_time_update: [
        { stop_id: "OA", schedule_relationship: "SCHEDULED" },
      ] } },
      // A bus: not a train.
      { trip_update: { trip: { trip_id: "20261113-19-12345", schedule_relationship: "CANCELED" } } },
      // Numbers for the enums, as protobuf has them.
      { trip_update: { trip: { trip_id: "20261113-LW-1933", schedule_relationship: 0 }, stop_time_update: [
        { stop_id: "PO", schedule_relationship: 1 },
      ] } },
    ],
  };
  assert.deepEqual(cancellations(exceptions, updates), [
    { trip: "1925", skips: ["PO"] },
    { trip: "1925", day: "20261113", skips: ["AL", "BU", "OA"] },
    { trip: "1931", all: true },
    { trip: "1933", day: "20261113", skips: ["PO"] },
    { trip: "1937", skips: ["OA"] },
    { trip: "9406", day: "20261113", all: true },
  ]);
  // Either feed alone.
  assert.deepEqual(cancellations(null, updates).map((entry) => entry.trip), ["1925", "1933", "9406"]);
  assert.deepEqual(cancellations(exceptions, null).map((entry) => entry.trip), ["1925", "1931", "1937"]);
  assert.deepEqual(cancellations(undefined, {}), []);
});

test("a tracked train is cancelled for you where it won't stop at your station or your stop", () => {
  const skipping = (skips, extra = {}) => [{ trip: "1925", day: "20261113", skips, ...extra }];
  assert.deepEqual(cancellationFor(job(), skipping(["AL", "BU", "OA"])), { index: 2, code: "OA", name: "Oakville" });
  assert.deepEqual(cancellationFor(job(), skipping(["UN"])), { index: 5, code: "UN", name: "Union" });
  // Not stopping somewhere in between: it still takes you.
  assert.equal(cancellationFor(job(), skipping(["CL", "PO"])), null);
  // The whole trip, or by the exceptions feed (no day).
  assert.deepEqual(cancellationFor(job(), [{ trip: "1925", all: true }]), { all: true });
  assert.deepEqual(cancellationFor(job(), [{ trip: "1925", skips: ["OA"] }]), { index: 2, code: "OA", name: "Oakville" });
  // Another day's train with the same number, or another train.
  assert.equal(cancellationFor(job(), [{ trip: "1925", day: "20261112", all: true }]), null);
  assert.equal(cancellationFor(job(), [{ trip: "1927", all: true }]), null);
  // On its way, with you on it: only where you get off matters.
  const riding = job({ dep: { 2: at("07:41") }, obs: { k: 3, at: false } });
  assert.equal(cancellationFor(riding, skipping(["OA"])), null);
  assert.deepEqual(cancellationFor(riding, skipping(["UN"])), { index: 5, code: "UN", name: "Union", left: true });
  // Nothing to look it up by.
  assert.equal(cancellationFor({ state: job().state }, skipping(["OA"])), null);
});

test("a trip's service day counts the night as the day before", () => {
  assert.equal(serviceDay(planned), "20261113");
  assert.equal(serviceDay([null, at("00:30", 14), at("01:10", 14)]), "20261113");
  assert.equal(serviceDay([at("04:50", 14)]), "20261114");
  assert.equal(serviceDay([null, null]), null);
  assert.equal(torontoDay(at("23:59")), "20261113");
});

test("a cancelled train's Live Activity stays up until a while after it was due", () => {
  const verdict = { index: 2, code: "OA", name: "Oakville" };
  // Found out early: until 10 minutes after it was due to leave your station.
  assert.equal(cancelledUntil(job(), verdict, at("07:00")), planned[2] + CANCELLED_FOR);
  // Found out late (it's running late, and was taken off): 10 minutes from now.
  assert.equal(cancelledUntil(job(), verdict, at("07:45")), at("07:55"));
  // On it, and it won't stop where you get off: until a while after it would have got there.
  assert.equal(cancelledUntil(job(), { index: 5, code: "UN", name: "Union", left: true }, at("07:50")),
               planned[5] + CANCELLED_FOR);
});

test("what you're told when it's cancelled, and when it's running after all", () => {
  assert.deepEqual(cancelAlert(job(), { index: 2, code: "OA", name: "Oakville" }), {
    title: "Your 07:40 train is cancelled",
    body: "It won't stop at Oakville. Open GO Stations to find another train.",
  });
  assert.deepEqual(cancelAlert(job(), { all: true }), {
    title: "Your 07:40 train is cancelled",
    body: "Open GO Stations to find another train.",
  });
  assert.deepEqual(cancelAlert(job(), { index: 5, code: "UN", name: "Union" }), {
    title: "Your 07:40 train won't stop at Union",
    body: "Open GO Stations to find another train.",
  });
  assert.deepEqual(cancelAlert(job(), null, { back: true }), {
    title: "Your 07:40 train is running after all",
    body: "It's no longer listed as cancelled.",
  });
});

test("the pushed content says it's cancelled as the worker last looked", () => {
  const state = { ...job().state, cancelled: { index: 2, station: "Oakville", next: at("08:10") } };
  // Not looked yet: as the app had it.
  assert.equal(shownState(job(), state), state);
  // Looked, and running: not cancelled (whatever the app thought).
  const running = shownState(job({ cancelCheckedAt: at("07:30"), cancelled: null }), state);
  assert.equal("cancelled" in running, false);
  assert.equal(running.stops.length, 6);
  // Cancelled: where, and the next train the app found.
  const cancelled = shownState(job({ cancelCheckedAt: at("07:30"), cancelled: { index: 2, code: "OA", name: "Oakville" } }),
                               state);
  assert.deepEqual(cancelled.cancelled, { index: 2, station: "Oakville", next: at("08:10") });
  // The whole trip.
  assert.deepEqual(shownState(job({ cancelled: { all: true } }), job().state).cancelled, {});
  assert.deepEqual(cancelledContent({ all: true }), {});
  assert.equal(cancelledContent(null), null);
});

test("on a trip with changes, the next train is cancelled for you where you change to it or get off it", () => {
  const listed = (entry) => [{ trip: "9512", day: "20261113", ...entry }];
  assert.deepEqual(connectionFor(journey(), listed({ all: true })), { all: true });
  assert.deepEqual(connectionFor(journey(), listed({ skips: ["DA"] })), { index: 1, code: "DA", name: "Danforth" });
  assert.deepEqual(connectionFor(journey(), listed({ skips: ["UN"] })), { index: 0, code: "UN", name: "Union" });
  // Not stopping further on, past where you get off: it still takes you.
  assert.equal(connectionFor(journey(), listed({ skips: ["SC", "GU"] })), null);
  // The first train cancelled is a matter for that one (see cancellationFor).
  assert.equal(connectionFor(journey(), [{ trip: "1925", all: true }]), null);
  // No change, or nothing to look it up by.
  assert.equal(connectionFor(job(), listed({ all: true })), null);
  const blind = journey();
  blind.legs[0].live = null;
  assert.equal(connectionFor(blind, listed({ all: true })), null);
});

test("what you're told when the next train is cancelled, and when it's running after all", () => {
  assert.deepEqual(connectionAlert(journey()), {
    title: "Your 08:10 connection at Union is cancelled",
    body: "Open GO Stations to plan another way there.",
  });
  assert.deepEqual(connectionAlert(journey(), { back: true }), {
    title: "Your 08:10 connection at Union is running after all",
    body: "It's no longer listed as cancelled.",
  });
});

test("the pushed change line says the next train's cancelled as the worker last looked", () => {
  const claimed = { ...journey().state, change: { ...change, cancelled: true } };
  // Not looked yet: as the app had it.
  assert.equal(shownState(journey(), claimed), claimed);
  // Looked: cancelled, or not (whatever the app thought).
  const cancelled = shownState(journey({ connectionCheckedAt: at("07:30"), connectionCancelled: { all: true } }),
                               journey().state);
  assert.deepEqual(cancelled.change, { ...change, cancelled: true });
  const running = shownState(journey({ connectionCheckedAt: at("07:30"), connectionCancelled: null }), claimed);
  assert.deepEqual(running.change, change);
  // Without a change, nothing to say.
  assert.equal("change" in shownState(job({ connectionCheckedAt: at("07:30") }), job().state), false);
  // The first train's cancellation as before, with the change line as it is.
  const both = shownState(journey({ cancelCheckedAt: at("07:30"), cancelled: { all: true },
                                    connectionCheckedAt: at("07:30"), connectionCancelled: null }), claimed);
  assert.deepEqual(both.cancelled, {});
  assert.deepEqual(both.change, change);
});

test("changing to a next train you were told is cancelled: no second alert for it", () => {
  const told = nextLeg(journey({ connectionAlerted: true, connectionCancelled: { all: true } }), at("08:01"));
  assert.equal(told.live.trip, "9512");
  assert.equal(told.cancelAlerted, true);
  // Told, but it was running again after all: told again, if it's cancelled again.
  assert.equal(nextLeg(journey({ connectionAlerted: true, connectionCancelled: null }), at("08:01")).cancelAlerted,
               undefined);
  assert.equal(nextLeg(journey(), at("08:01")).cancelAlerted, undefined);
});
