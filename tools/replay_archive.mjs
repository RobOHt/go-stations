#!/usr/bin/env node
// Plays recorded live feeds back through the Worker's own watcher code, and says
// how each way of drawing the trains did: how far from the real train, how often
// ahead of it, how often it had to move back. The recordings are the watcher's
// hourly R2 files, or tools/record_feeds.mjs's; give several, oldest first, to
// play them as one stretch.
//
// Usage: node tools/replay_archive.mjs positions/2026/11/24/21.ndjson.gz [...]
//        node tools/replay_archive.mjs --json feeds.ndjson   (the numbers as JSON)

import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { parseArgs } from "node:util";
import { watcher, watch, record } from "./watch_code.mjs";

const { values, positionals } = parseArgs({ allowPositionals: true, options: { json: { type: "boolean", default: false } } });
if (!positionals.length) {
  console.error("usage: node tools/replay_archive.mjs FILE.ndjson[.gz] ...");
  process.exit(1);
}

const lines = [];
for (const path of positionals) {
  const bytes = readFileSync(path);
  const text = (bytes[0] === 0x1f && bytes[1] === 0x8b ? gunzipSync(bytes) : bytes).toString("utf8");
  for (const row of text.split("\n")) {
    if (!row.trim()) continue;
    try {
      lines.push(JSON.parse(row));
    } catch {
      // A torn last line: the rest stands.
    }
  }
}

// Every trip's stops in the recording, whenever it was looked up.
const stops = new Map();
for (const line of lines) {
  if (line.k === "trip" && Array.isArray(line.codes)) {
    const before = stops.get(`${line.day}|${line.trip}`);
    stops.set(`${line.day}|${line.trip}`, { codes: line.codes, stops: line.stops ?? before?.stops ?? null });
  }
}

// The looks, each its tick line and the changes after it.
const looks = [];
for (const line of lines) {
  if (line.k === "tick") looks.push([line]);
  else if (looks.length) looks[looks.length - 1].push(line);
}

const errors = [];
const player = new record.Player();
let clock = 0;
const upstream = async (path) => {
  const feeds = player.feeds();
  if (path === "/Gtfs/Feed/VehiclePosition") return feeds.vehicles;
  if (path === "/ServiceataGlance/Trains/All") return feeds.glance;
  const match = /^\/Schedule\/Trip\/(\d{8})\/(\w+)$/.exec(path);
  const trip = match && stops.get(`${match[1]}|${match[2]}`);
  if (!trip) return null;
  return { Metadata: { ErrorCode: "200" }, Trips: [{ Number: match[2], Stops: trip.stops ?? trip.codes.map((code) => ({ Code: code })) }] };
};
const replay = new watcher.Watch({
  upstream,
  clock: () => clock,
  startedAt: looks[0]?.[0]?.t ?? 0,
  board: { warmUp: 0, observer: (scored) => errors.push(scored) },
});
const points = [];
for (const group of looks) {
  for (const line of group) player.apply(line);
  clock = group[0].t;
  await replay.look({ full: false });
  points.push(...replay.board.points());
}
// The trains still running at the end: scored as far as their fixes go.
for (const train of replay.board.trains.values()) {
  train.score(Infinity, true);
  replay.board.collect(train, true, clock);
}
points.push(...replay.board.points());

const quantile = (sorted, p) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : NaN);
function figures(rows) {
  const off = rows.map((row) => Math.abs(row.error)).sort((a, b) => a - b);
  const behind = rows.map((row) => -row.error).sort((a, b) => a - b);
  const ahead = rows.filter((row) => row.error > 1).map((row) => row.error).sort((a, b) => a - b);
  return {
    seconds: rows.length,
    medianOff: Math.round(quantile(off, 0.5)),
    p90Off: Math.round(quantile(off, 0.9)),
    worstOff: Math.round(off[off.length - 1] ?? NaN),
    medianBehind: Math.round(quantile(behind, 0.5)),
    aheadShare: rows.length ? Math.round((ahead.length / rows.length) * 1000) / 10 : NaN,
    medianAhead: Math.round(quantile(ahead, 0.5)),
    worstAhead: Math.round(ahead[ahead.length - 1] ?? 0),
  };
}
const by = (key) => {
  const groups = new Map();
  for (const row of errors) {
    const name = `${row.model}|${row[key]}`;
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(row);
  }
  return groups;
};
const moves = new Map();
for (const point of points) {
  const model = point.blobs[0];
  const entry = moves.get(model) ?? { back: 0, seconds: 0, lurch: 0 };
  entry.back += point.doubles[8];
  entry.lurch += point.doubles[10];
  entry.seconds += point.doubles[0];
  moves.set(model, entry);
}

const span = looks.length ? looks[looks.length - 1][0].t - looks[0][0].t : 0;
const result = {
  looks: looks.length,
  minutes: Math.round(span / 60),
  trains: new Set(errors.map((row) => row.trip)).size,
  models: Object.fromEntries(watch.MODELS.map((model) => {
    const move = moves.get(model) ?? { back: 0, seconds: 0, lurch: 0 };
    return [model, {
      ...figures(errors.filter((row) => row.model === model)),
      backPerHour: move.seconds ? Math.round((move.back / move.seconds) * 3600 * 10) / 10 : NaN,
      lurchesPerHour: move.seconds ? Math.round((move.lurch / move.seconds) * 3600 * 10) / 10 : NaN,
    }];
  })),
  byPhase: Object.fromEntries([...by("phase")].map(([name, rows]) => [name, figures(rows)])),
  byLine: Object.fromEntries([...by("line")].map(([name, rows]) => [name, figures(rows)])),
  points: points.length,
};

if (values.json) {
  console.log(JSON.stringify(result, null, 2));
} else {
  console.log(`${result.looks} looks over ${result.minutes} min, ${result.trains} trains scored, ${result.points} data points`);
  const row = (name, f, extra = "") =>
    console.log(`${name.padEnd(22)} ${String(f.seconds).padStart(7)} s  off: median ${String(f.medianOff).padStart(4)} m, ` +
      `90% ${String(f.p90Off).padStart(4)} m, worst ${String(f.worstOff).padStart(5)} m;  median behind ${String(f.medianBehind).padStart(4)} m;  ` +
      `ahead ${String(f.aheadShare).padStart(4)}% (median ${f.medianAhead} m, most ${f.worstAhead} m)${extra}`);
  console.log("\nBy model:");
  for (const [model, f] of Object.entries(result.models)) row(model, f, `;  ${f.backPerHour} moves back an hour, ${f.lurchesPerHour} lurches`);
  console.log("\nBy phase:");
  for (const [name, f] of Object.entries(result.byPhase).sort()) row(name, f);
  console.log("\nBy line:");
  for (const [name, f] of Object.entries(result.byLine).sort()) row(name, f);
  // The worst seconds, one per train and model: what to look into.
  const clock = (t) => new Date((t - 5 * 3600) * 1000).toISOString().slice(11, 19);
  console.log("\nWorst seconds (one per train):");
  for (const model of watch.MODELS) {
    const worst = new Map();
    for (const row of errors) {
      if (row.model !== model) continue;
      if (!worst.has(row.trip) || Math.abs(row.error) > Math.abs(worst.get(row.trip).error)) worst.set(row.trip, row);
    }
    for (const row of [...worst.values()].sort((a, b) => Math.abs(b.error) - Math.abs(a.error)).slice(0, 4)) {
      console.log(`${model.padEnd(10)} ${row.error > 0 ? "ahead " : "behind"} ${String(Math.round(Math.abs(row.error))).padStart(5)} m  ` +
        `train ${row.trip} (${row.line}) at ${clock(row.time)} (UTC-5), ${row.phase}, its newest fix ${Math.round(row.age)} s old`);
    }
  }
}
