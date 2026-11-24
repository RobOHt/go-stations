// The watcher: one Durable Object that looks at GO's two live train feeds every
// 5 seconds, all day, whether or not anyone has the app open.
//
// Each look:
//   - notes what changed in the feeds (src/record.js) and keeps it, to go to R2
//     as one gzipped JSON-lines file an hour (positions/YYYY/MM/DD/HH.ndjson.gz,
//     UTC): every GPS fix GO sends, the data a better model is trained on;
//   - looks up the stops of each trip it hasn't seen yet (GO's Schedule/Trip),
//     to place its train along its run as the app does;
//   - hands the trains to the scoreboard (src/watch.js), which replays how each
//     way of drawing them did against where they really went, and writes the
//     finished per-train-minute summaries to Analytics Engine (SCORES).
//
// The object wakes itself with an alarm; a Cron Trigger checks every minute that
// the alarm is still set (an alarm that fails often enough stops being retried).
// Nothing here is needed by the app: if the watcher stops, the app works as before.
// WATCH = "off" (wrangler.toml) stops it.

import { DurableObject } from "cloudflare:workers";
import networkFile from "../../Departures/Resources/network.json" with { type: "json" };
import { mergeTrains, torontoDay } from "./live.js";
import { Recorder, tripParts, vehicleId } from "./record.js";
import { Network, Run } from "./track.js";
import { Scoreboard, tripCodes, VERSION } from "./watch.js";

const UPSTREAM = "https://api.openmetrolinx.com/OpenDataAPI/api/V1";
/** Seconds between looks. */
export const EVERY = 5;
/** Trips whose stops are looked up in one look, at most. */
const LOOKUPS = 6;
/** A trip whose stops couldn't be had is asked about again after this long, in seconds. */
const RETRY = 300;
/** Data points written to Analytics Engine per look, at most (it takes 250 per invocation). */
const WRITES = 200;
/** What a look writes down is stored in parts no bigger than this. */
const PART = 96 * 1024;
/** Hours of lines kept when R2 won't take them, before the oldest are dropped. */
const BACKLOG = 24;

export const network = new Network(networkFile);

/** The stations the network knows. */
const known = (code) => network.station(code) != null;

/** GO's answer for one API path, or null (no answer, or an error). */
export async function upstreamJSON(key, path, timeout = 4000) {
  try {
    const response = await fetch(`${UPSTREAM}${path}?key=${encodeURIComponent(key)}`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(timeout),
    });
    if (!response.ok) return null;
    const body = await response.json();
    const code = String(body?.Metadata?.ErrorCode ?? "200");
    return code === "200" || code === "204" ? body : null;
  } catch {
    return null;
  }
}

/**
 * The work of one look, apart from where it's kept: the watcher runs it every 5
 * seconds; tools/record_feeds.mjs and tools/replay_archive.mjs run the same code
 * outside Cloudflare. `upstream(path)` answers for GO's API; `cache` (optional)
 * keeps trips' stops across restarts ({ get(key), put(key, value) }).
 */
export class Watch {
  constructor({ upstream, cache = null, clock = () => Date.now() / 1000, startedAt = clock(), board = {} } = {}) {
    this.upstream = upstream;
    this.cache = cache;
    this.clock = clock;
    this.recorder = new Recorder();
    this.board = new Scoreboard({ startedAt, ...board });
    /** Each trip's stops and run, by `${day}|${trip}`: { codes, run }, or { retry } after a failed look-up. */
    this.trips = new Map();
    this.feeds = { vehicles: null, glance: null };
  }

  /** One look at the feeds: what changed (lines to keep) and the trains as the app has them. */
  async look({ full = false } = {}) {
    const [vehicles, glance] = await Promise.all([
      this.upstream("/Gtfs/Feed/VehiclePosition"),
      this.upstream("/ServiceataGlance/Trains/All"),
    ]);
    const seen = this.clock();
    this.feeds = {
      vehicles: vehicles ? { ok: true, at: seen, ts: Number(vehicles?.header?.timestamp) || null } : { ok: false, at: seen },
      glance: glance ? { ok: true, at: seen } : { ok: false, at: seen },
    };
    const lines = this.recorder.look(vehicles, glance, seen, { full });
    const merged = mergeTrains(vehicles, glance, seen);

    // Each train's service day: its GTFS trip id's, or today's (a train only Service at a Glance has).
    const days = new Map();
    for (const entity of Array.isArray(vehicles?.entity) ? vehicles.entity : []) {
      const parts = tripParts(vehicleId(entity));
      if (parts) days.set(parts.trip, parts.day);
    }
    const today = torontoDay(seen - 4 * 3600);
    const keyOf = (train) => {
      const day = days.get(train.trip) ?? today;
      return { day, key: `${day}|${train.trip}` };
    };

    // The stops of trips not seen yet.
    const wanted = [];
    for (const train of merged.trains) {
      const { day, key } = keyOf(train);
      const entry = this.trips.get(key);
      if (entry && !(entry.retry && entry.retry <= seen)) continue;
      if (wanted.some((each) => each.key === key)) continue;
      wanted.push({ key, day, train });
      if (wanted.length >= LOOKUPS) break;
    }
    const found = await Promise.all(wanted.map((each) => this.lookUp(each, seen)));
    for (const line of found) if (line) lines.push(line);
    if (full) {
      // A file an hour stands on its own: the stops of every trip running, again.
      for (const train of merged.trains) {
        const { day, key } = keyOf(train);
        const entry = this.trips.get(key);
        if (entry?.codes && !found.some((line) => line?.day === day && line?.trip === train.trip)) {
          lines.push({ k: "trip", t: seen, day, trip: train.trip, codes: entry.codes });
        }
      }
    }

    // (Scoring never costs the recording: what changed is kept whatever happens here.)
    try {
      this.board.look(merged, seen, (train) => {
        const { day, key } = keyOf(train);
        const entry = this.trips.get(key);
        return { key, day, line: network.line(train.line) ?? train.line, run: entry?.run ?? null, codes: entry?.codes ?? null };
      });
    } catch (failure) {
      this.scoreErrors = (this.scoreErrors ?? 0) + 1;
      this.lastScoreError = `${new Date(seen * 1000).toISOString().slice(0, 19)} ${String(failure?.stack ?? failure).slice(0, 300)}`;
    }
    return { lines, merged, seen };
  }

  /** Looks up one trip's stops (cached, else GO's Schedule/Trip): the line to keep, or null. */
  async lookUp({ key, day, train }, now) {
    const line = network.line(train.line) ?? train.line;
    const cacheKey = `trip:${day}:${train.trip}`;
    let codes = null;
    let stops = null;
    try {
      codes = (await this.cache?.get(cacheKey)) ?? null;
    } catch {
      codes = null;
    }
    const cached = Array.isArray(codes) && codes.length >= 2;
    if (!cached) {
      const body = await this.upstream(`/Schedule/Trip/${day}/${train.trip}`);
      codes = body ? tripCodes(body, known) : null;
      if (codes) {
        const trips = body?.Trips?.Trip ?? body?.Trips;
        stops = (Array.isArray(trips) ? trips[0] : trips)?.Stops ?? null;
      }
    }
    if (!codes) {
      this.trips.set(key, { retry: now + RETRY });
      return null;
    }
    this.trips.set(key, { codes, run: Run.on(network, line, codes) });
    if (cached) return null;
    try {
      await this.cache?.put(cacheKey, codes);
    } catch {
      // Looked up again after a restart, then.
    }
    return { k: "trip", t: now, day, trip: train.trip, codes, ...(stops ? { stops } : {}) };
  }

  /** Forgets trips from before yesterday. */
  forget(now) {
    const yesterday = torontoDay(now - 28 * 3600);
    for (const key of this.trips.keys()) if (key.slice(0, 8) < yesterday) this.trips.delete(key);
  }
}

/** The R2 key for an hour's lines (`hour`: Unix hours). */
export function archiveKey(hour) {
  const date = new Date(hour * 3600 * 1000).toISOString();
  return `positions/${date.slice(0, 4)}/${date.slice(5, 7)}/${date.slice(8, 10)}/${date.slice(11, 13)}.ndjson.gz`;
}

/** Where a look's stored lines go: `rec:` and its time in milliseconds (13 digits), and the part. */
function rowKey(ms, part) {
  return `rec:${String(Math.floor(ms)).padStart(13, "0")}:${String(part).padStart(3, "0")}`;
}

export async function gzip(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** The next 5-second mark at least a second after `ms`. */
export function nextLook(ms) {
  const step = EVERY * 1000;
  return Math.ceil((ms + 1000) / step) * step;
}

export class Watcher extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.started = Date.now() / 1000;
    this.watch = new Watch({
      upstream: (path) => upstreamJSON(env.METROLINX_API_KEY ?? "", path),
      cache: { get: (key) => ctx.storage.get(key), put: (key, value) => ctx.storage.put(key, value) },
      startedAt: this.started,
    });
    this.hour = null;
    this.oldest = undefined;
    this.stats = { looks: 0, errors: 0, lastError: null, lastLook: null, took: null, flushed: null, written: 0, dropped: 0 };
  }

  /** Makes sure the watcher is running (the Cron Trigger asks every minute). */
  async start() {
    if (this.env.WATCH === "off") {
      await this.ctx.storage.deleteAlarm();
      return false;
    }
    if ((await this.ctx.storage.getAlarm()) == null) await this.ctx.storage.setAlarm(Date.now() + 1000);
    return true;
  }

  async alarm() {
    if (this.env.WATCH === "off") return;
    const started = Date.now();
    try {
      await this.look(started / 1000);
      this.stats.looks++;
    } catch (failure) {
      this.stats.errors++;
      // (Shown by /health: never the key, should an error ever carry it.)
      const text = String(failure?.stack ?? failure).replaceAll(this.env.METROLINX_API_KEY || "\u0000", "");
      this.stats.lastError = `${new Date().toISOString().slice(0, 19)} ${text.slice(0, 300)}`;
      console.log("watcher:", failure);
    } finally {
      this.stats.took = Date.now() - started;
      await this.ctx.storage.setAlarm(nextLook(Date.now()));
    }
  }

  async look(now) {
    if (!this.env.METROLINX_API_KEY) throw new Error("no Metrolinx key");
    const hour = Math.floor(now / 3600);
    const full = this.hour !== hour;
    this.hour = hour;
    const { lines, seen } = await this.watch.look({ full });
    this.stats.lastLook = seen;

    if (this.env.POSITIONS) {
      // This look's lines, kept until their hour goes to R2.
      const text = lines.map((line) => JSON.stringify(line)).join("\n") + "\n";
      const parts = [];
      for (let start = 0; start < text.length; start += PART) parts.push(text.slice(start, start + PART));
      const entries = {};
      parts.forEach((part, index) => (entries[rowKey(seen * 1000, index)] = part));
      await this.ctx.storage.put(entries);
      if (this.oldest === undefined) {
        const first = await this.ctx.storage.list({ prefix: "rec:", limit: 1 });
        const [key] = first.keys();
        this.oldest = key ? Math.floor(Number(key.slice(4, 17)) / 3600000) : hour;
      }
      // Earlier hours, to R2 (two at most per look: a long backlog goes over a few looks;
      // after a failure, not again for a minute).
      for (let i = 0; i < 2 && this.oldest < hour && !(now < (this.flushRetry ?? 0)); i++) {
        await this.flush(this.oldest, now);
        this.oldest++;
      }
    }

    const points = this.watch.board.points(WRITES);
    if (this.env.SCORES) {
      for (const point of points) this.env.SCORES.writeDataPoint(point);
      this.stats.written += points.length;
    } else {
      this.stats.dropped += points.length;
    }
  }

  /** Sends one hour's kept lines to R2 as one gzipped file, then forgets them. */
  async flush(hour, now) {
    const start = rowKey(hour * 3600 * 1000, 0);
    const end = rowKey((hour + 1) * 3600 * 1000, 0);
    const rows = await this.ctx.storage.list({ prefix: "rec:", start, end });
    if (!rows.size) return;
    const meta = { k: "meta", watcher: VERSION, network: network.version, hour: new Date(hour * 3600 * 1000).toISOString() };
    const text = `${JSON.stringify(meta)}\n${[...rows.values()].join("")}`;
    let key = archiveKey(hour);
    try {
      // (Sent before but not forgotten, the DO having restarted in between: alongside, not over it.)
      if (await this.env.POSITIONS.head(key)) key = key.replace(".ndjson.gz", `-${Date.now()}.ndjson.gz`);
      const body = await gzip(text);
      await this.env.POSITIONS.put(key, body, {
        httpMetadata: { contentType: "application/gzip" },
        customMetadata: { watcher: VERSION, looks: String(rows.size) },
      });
      this.stats.flushed = { key, bytes: body.byteLength, raw: text.length, at: now };
    } catch (failure) {
      // R2 isn't taking it: kept for another try in a minute, but not forever.
      if (hour >= Math.floor(now / 3600) - BACKLOG) {
        this.flushRetry = now + 60;
        throw failure;
      }
      this.stats.lastError = `${new Date().toISOString().slice(0, 19)} dropped ${key}: ${String(failure).slice(0, 120)}`;
    }
    const keys = [...rows.keys()];
    for (let i = 0; i < keys.length; i += 128) await this.ctx.storage.delete(keys.slice(i, i + 128));
    // And trips' stops from before yesterday.
    const old = await this.ctx.storage.list({ prefix: "trip:", end: `trip:${torontoDay(now - 28 * 3600)}` });
    const tripKeys = [...old.keys()];
    for (let i = 0; i < tripKeys.length; i += 128) await this.ctx.storage.delete(tripKeys.slice(i, i + 128));
    this.watch.forget(now);
  }

  /** How the watcher is doing, for /health?check=watch (and it makes sure it's running). */
  async status() {
    const running = await this.start();
    const now = Date.now() / 1000;
    const { stats } = this;
    const feeds = this.watch.feeds;
    const trips = [...this.watch.trips.values()];
    return {
      running,
      version: VERSION,
      upFor: Math.round(now - this.started),
      looks: stats.looks,
      lastLook: stats.lastLook ? Math.round(now - stats.lastLook) : null,
      tookMs: stats.took,
      errors: stats.errors,
      lastError: stats.lastError,
      scoreErrors: this.watch.scoreErrors ?? 0,
      lastScoreError: this.watch.lastScoreError ?? null,
      feeds: {
        vehicles: feeds.vehicles?.ok ?? null,
        vehiclesAge: feeds.vehicles?.ts ? Math.round((feeds.vehicles.at ?? now) - feeds.vehicles.ts) : null,
        glance: feeds.glance?.ok ?? null,
      },
      trips: { known: trips.filter((trip) => trip.codes).length, failed: trips.filter((trip) => trip.retry).length },
      recording: Boolean(this.env.POSITIONS),
      flushed: stats.flushed ? { ...stats.flushed, at: Math.round(now - stats.flushed.at) } : null,
      scoring: Boolean(this.env.SCORES),
      written: stats.written,
      dropped: stats.dropped,
      ...this.watch.board.summary(),
    };
  }
}
