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

import { createWriteStream } from "node:fs";
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

const started = Date.now() / 1000;
// (No warm-up: the recording starts cold, as an app just opened would.)
const look = new watcher.Watch({ upstream: (path) => watcher.upstreamJSON(key, path, 8000), startedAt: started, board: { warmUp: 0 } });
const end = Date.now() + minutes * 60_000;
let first = true;
let looks = 0;
let failed = 0;
let lastReport = Date.now();
while (Date.now() < end) {
  const began = Date.now();
  try {
    const { lines, merged } = await look.look({ full: first });
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
await new Promise((resolve) => out.end(resolve));
console.log(`${looks} looks over ${minutes} min (${failed} failed); written to ${values.out}`);
console.log(JSON.stringify(look.board.summary(), null, 2));
