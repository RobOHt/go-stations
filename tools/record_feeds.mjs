#!/usr/bin/env node
// Records GO's live train feeds exactly as the Worker's watcher does (the same
// code: worker/src/watcher.js), every 5 seconds for a while, to a JSON-lines file
// in the watcher's own format (worker/src/record.js), and says how each way of
// drawing the trains did meanwhile. For trying the watcher on real trains before
// it's deployed; tools/replay_archive.mjs plays a recording back.
//
// Run by .github/workflows/probe.yml (mode: record), which has the key; it needs
// METROLINX_API_KEY in the environment and never prints it.
//
// Usage: METROLINX_API_KEY=... node tools/record_feeds.mjs --minutes 20 --out feeds.ndjson

import { createWriteStream, readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { watcher, watch } from "./watch_code.mjs";

const { values } = parseArgs({ options: { minutes: { type: "string", default: "20" }, out: { type: "string", default: "feeds.ndjson" } } });
const key = (process.env.METROLINX_API_KEY ?? "").trim();
if (!key) {
  console.error("METROLINX_API_KEY is not set");
  process.exit(1);
}
const minutes = Math.max(1, Math.min(Number(values.minutes) || 20, 120));
const out = createWriteStream(values.out);
const write = (line) => out.write(`${JSON.stringify(line)}\n`);
write({ k: "meta", watcher: watch.VERSION, network: watcher.network.version, by: "tools/record_feeds.mjs" });

// Meanwhile, the app's own view: the Worker's /v1/live/trains, asked every 5 s as the app
// asks it, halfway between the watcher's looks. When each report first shows up there, against
// when the watcher first saw it, is how much later the app has it (the scoreboard's APP_LAG).
const appURL = process.env.WORKER_URL ?? (() => {
  const swift = readFileSync(new URL("../Departures/API/MetrolinxClient.swift", import.meta.url), "utf8");
  const match = /baseURL = "([^"]+)"/.exec(swift);
  return match ? `${match[1]}/live/trains` : null;
})();
const firstWatch = new Map();
const firstApp = new Map();
const note = (map, list, at) => {
  for (const train of list?.trains ?? []) {
    for (const time of [train.time, ...(train.fixes ?? []).map((fix) => fix.time)]) {
      const key = `${train.trip}|${time}`;
      if (!map.has(key)) map.set(key, { at, time });
    }
  }
};
let appLooks = 0;
const askApp = async (until) => {
  await new Promise((resolve) => setTimeout(resolve, 2500));
  while (appURL && Date.now() < until) {
    const began = Date.now();
    try {
      const response = await fetch(appURL, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
      if (response.ok) {
        note(firstApp, await response.json(), Date.now() / 1000);
        appLooks++;
      }
    } catch {
      // The next one.
    }
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, 5000 - (Date.now() - began))));
  }
};

const started = Date.now() / 1000;
// (No warm-up: the recording starts cold, as an app just opened would.)
const look = new watcher.Watch({ upstream: (path) => watcher.upstreamJSON(key, path, 8000), startedAt: started, board: { warmUp: 0 } });
const end = Date.now() + minutes * 60_000;
const app = askApp(end);
let first = true;
let looks = 0;
let failed = 0;
let lastReport = Date.now();
while (Date.now() < end) {
  const began = Date.now();
  try {
    const { lines, merged, seen } = await look.look({ full: first });
    note(firstWatch, merged, seen);
    first = false;
    looks++;
    for (const line of lines) write(line);
    if (Date.now() - lastReport >= 60_000) {
      lastReport = Date.now();
      const summary = look.board.summary();
      console.log(`${new Date().toISOString().slice(11, 19)} ${merged.trains.length} trains (${summary.placed} placed on their runs); ` +
        `fix age when seen: median ${summary.fixAge.median} s, 90% ${summary.fixAge.p90} s`);
    }
  } catch (failure) {
    failed++;
    console.log(`look failed: ${String(failure?.message ?? failure).replaceAll(key, "")}`);
  }
  await new Promise((resolve) => setTimeout(resolve, Math.max(0, watcher.nextLook(began) - Date.now())));
}
await app;
await new Promise((resolve) => out.end(resolve));
console.log(`${looks} looks over ${minutes} min (${failed} failed); written to ${values.out}`);
const lags = [];
const appAges = [];
const watchAges = [];
for (const [key, seenByApp] of firstApp) {
  const seenByWatcher = firstWatch.get(key);
  // (Reports already out when the recording started say nothing about when they came.)
  if (seenByApp.at < started + 30 || (seenByWatcher && seenByWatcher.at < started + 30)) continue;
  appAges.push(seenByApp.at - seenByApp.time);
  if (!seenByWatcher) continue;
  lags.push(seenByApp.at - seenByWatcher.at);
  watchAges.push(seenByWatcher.at - seenByWatcher.time);
}
const q = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? Math.round(sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] * 10) / 10 : null;
};
console.log(`The app's view (${appLooks} looks at /v1/live/trains): ${lags.length} reports seen by both; ` +
  `the app has each one after the watcher by: 25% ${q(lags, 0.25)} s, median ${q(lags, 0.5)} s, 75% ${q(lags, 0.75)} s, 90% ${q(lags, 0.9)} s. ` +
  `Age when first seen: by the watcher median ${q(watchAges, 0.5)} s, by the app median ${q(appAges, 0.5)} s (90% ${q(appAges, 0.9)} s).`);
console.log(JSON.stringify(look.board.summary(), null, 2));
