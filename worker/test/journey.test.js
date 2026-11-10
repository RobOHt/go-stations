// Tests for journeys with changes and alerts in src/live.js: a made-up trip from
// Exhibition to Danforth, changing at Union. Run with: node --test worker/test/*.test.js
import assert from "node:assert/strict";
import { test } from "node:test";
import { ALERT_BEFORE, alertFor, alertTime, arrivalAt, follow, nextLeg, torontoClock, watchWindow } from "../src/live.js";

// 2026-11-10 in Toronto (EST, UTC-5).
const at = (clock) => {
  const [h, m, s = 0] = clock.split(":").map(Number);
  return Date.UTC(2026, 10, 10, h + 5, m, s) / 1000;
};

// The first train: Lakeshore West 1306, Exhibition 07:25 to Union 07:34.
const first = {
  codes: ["AL", "BU", "EX", "UN"],
  planned: ["06:50", "07:00", "07:25", "07:34"].map(at),
  names: ["Aldershot", "Burlington", "Exhibition", "Union"],
};
// The second: Lakeshore East 9206, Union 07:39 to Danforth 07:51 (and on to Oshawa).
const second = {
  codes: ["UN", "DA", "SC", "OS"],
  planned: ["07:39", "07:51", "07:55", "08:30"].map(at),
  names: ["Union", "Danforth", "Scarborough", "Oshawa"],
};

const change = {
  station: "Union", lineCode: "LE", lineColorHex: "FF0D00", lineName: "Lakeshore East",
  departure: at("07:39"), terminusName: "Oshawa", destinationName: "Danforth",
};

function state(trip, boarding, destination, extra = {}) {
  return {
    departure: trip.planned[boarding], arrival: trip.planned[destination], hasDeparted: false, platform: null,
    stops: trip.names.map((name, i) => ({ name, time: trip.planned[i] })),
    boardingIndex: boarding, destinationIndex: destination, awaitsTrain: true, ...extra,
  };
}

function job() {
  const base = {
    token: "ab".repeat(32), environment: "production", revision: 3, alerts: true,
    state: state(first, 2, 3, { change }),
    times: [], end: first.planned[3], dismissal: first.planned[3] + 15 * 60,
    live: { trip: "1306", codes: first.codes, scheduled: first.planned },
    legs: [{
      state: state(second, 0, 1, { leg: { tripNumber: "9206", lineCode: "LE" } }),
      times: [at("07:38"), at("07:39")], end: second.planned[1], dismissal: second.planned[1] + 15 * 60,
      live: { trip: "9206", codes: second.codes, scheduled: second.planned },
    }],
  };
  return { ...base, ...watchWindow(base) };
}

test("Toronto clock times", () => {
  assert.equal(torontoClock(at("07:39")), "07:39");
  assert.equal(torontoClock(at("23:05")), "23:05");
});

test("the change alert comes 5 minutes before Union, once, on the train", () => {
  const trip = job();
  const due = arrivalAt(trip.state.stops, 3);
  // Waiting at Exhibition: nothing yet, however close Union is on paper.
  assert.equal(alertFor(trip, trip.state, at("07:24:00")), null);
  // On the train, more than 5 minutes out: not yet.
  const riding = { ...trip.state, hasDeparted: true };
  assert.equal(alertFor(trip, riding, due - ALERT_BEFORE - 60), null);
  const alert = alertFor(trip, riding, due - ALERT_BEFORE + 5);
  assert.ok(alert);
  assert.equal(alert.title, "Change at Union in 5 min");
  assert.equal(alert.body, "Then the 07:39 Lakeshore East line train to Oshawa.");
  // Sent: not again.
  assert.equal(alertFor({ ...trip, alerted: alert.key }, riding, due - 120), null);
  // Too late to bother.
  assert.equal(alertFor(trip, riding, due - 30), null);
  // Without alerts, never.
  assert.equal(alertFor({ ...trip, alerts: false }, riding, due - 200), null);
});

test("the get-off alert on the last train", () => {
  const trip = nextLeg(job(), at("07:35"));
  const riding = { ...trip.state, hasDeparted: true };
  const due = arrivalAt(riding.stops, 1);
  const alert = alertFor(trip, riding, due - 4 * 60);
  assert.equal(alert.title, "Danforth in 4 min");
  assert.match(alert.body, /get off/);
});

test("when the alert is due for a trip that isn't followed", () => {
  const trip = job();
  assert.equal(alertTime(trip, at("07:00")), arrivalAt(trip.state.stops, 3) - ALERT_BEFORE);
  assert.equal(alertTime({ ...trip, alerts: false }, at("07:00")), null);
  // Sent already, or too late.
  const key = alertFor(trip, { ...trip.state, hasDeparted: true }, arrivalAt(trip.state.stops, 3) - 200).key;
  assert.equal(alertTime({ ...trip, alerted: key }, at("07:00")), null);
  assert.equal(alertTime(trip, at("07:34")), null);
});

test("in at Union, the next train takes over", () => {
  const trip = job();
  const next = nextLeg(trip, at("07:35"));
  assert.equal(next.live.trip, "9206");
  assert.equal(next.state.leg.tripNumber, "9206");
  assert.deepEqual(next.legs, []);
  assert.equal(next.token, trip.token);
  assert.equal(next.revision, 3);
  assert.equal(next.alerts, true);
  // Only the times still to come.
  assert.deepEqual(next.times, [at("07:38"), at("07:39")]);
  assert.deepEqual(nextLeg(next, at("07:36")), null);
  // Followed from 20 minutes before it's due at Union.
  assert.equal(next.watchFrom, at("07:19"));
  // Nothing seen of the first train carries over.
  assert.equal(next.obs, undefined);
  assert.equal(next.followed, undefined);
});

test("following the first train: ends in at Union, and says where it stands on the way", () => {
  const trip = job();
  const onTheWay = { trip: "1306", line: "LW", lat: 43.6, lon: -79.4, time: at("07:29:00"), status: "to", stop: "UN", delay: 0 };
  const result = follow(trip, onTheWay, at("07:29:10"));
  assert.ok(result.state, "the state as it stands");
  assert.ok(result.stale > at("07:29:10"));
  assert.equal(result.push.event, "update");
  // Again with nothing new: no push, but the state still comes back (for an alert).
  const again = follow(result.job, onTheWay, at("07:30:00"));
  assert.equal(again.push, null);
  assert.ok(again.state);
  const alert = alertFor(again.job, again.state, at("07:30:00"));
  assert.equal(alert?.title, "Change at Union in 4 min");
  // In at Union: the end of this train (the worker then takes the next one on).
  const inUnion = { ...onTheWay, time: at("07:33:40"), status: "at" };
  const end = follow(again.job, inUnion, at("07:33:50"));
  assert.equal(end.push.event, "end");
  assert.ok(end.job.legs.length === 1);
});
