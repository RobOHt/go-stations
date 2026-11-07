// GO Stations API proxy, live train positions, and push updates for the tracked
// train's Live Activity.
//
// The app calls https://go-stations.<subdomain>.workers.dev/v1/<path>. This Worker
// adds the Metrolinx Open Data API key (a Worker secret that never ships in the app),
// forwards the request, and marks good answers cacheable for a few seconds so
// everyone looking at the same board shares one Metrolinx request. Only the
// read-only endpoints the app uses are allowed.
//
// GET /v1/live/trains: where every GO train is right now, and whether it's
// standing at a station (src/live.js), cached a few seconds.
//
// POST /v1/activity takes a Live Activity's push token, what it shows, and when
// the train reaches each stop; at each of those times the LiveActivities Durable
// Object has Apple's push service hand the activity an update (so iOS draws it
// again while the app isn't running), and at the end, ends it. With the trip's
// stops (`live`), it instead follows the train itself while it runs: every 20
// seconds it looks where the train is, and pushes an update when it pulls in at
// a stop or leaves one. POST /v1/activity/end forgets one early. Nothing is kept
// once the trip is over. The Apple push key is a Worker secret too (APNS_KEY_P8,
// APNS_KEY_ID, APPLE_TEAM_ID).

import { DurableObject } from "cloudflare:workers";
import { follow, mergeTrains } from "./live.js";

const UPSTREAM = "https://api.openmetrolinx.com/OpenDataAPI/api/V1";

const ROUTES = [
  // Live departures for one station.
  { pattern: /^\/Stop\/NextService\/[A-Za-z0-9]{1,8}$/, ttl: 20 },
  // The Union Station board.
  { pattern: /^\/ServiceUpdate\/UnionDepartures\/All$/, ttl: 20 },
  // Cancelled trips and stops.
  { pattern: /^\/ServiceUpdate\/Exceptions\/Train$/, ttl: 60 },
  // Service alerts.
  { pattern: /^\/ServiceUpdate\/ServiceAlert\/All$/, ttl: 120 },
  // One trip's stop list for a service day.
  { pattern: /^\/Schedule\/Trip\/\d{8}\/[A-Za-z0-9]{1,12}$/, ttl: 600 },
];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/v1/activity" || url.pathname === "/v1/activity/end") {
      return activity(request, env, url.pathname.endsWith("/end"));
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return error(405, "Method not allowed", { Allow: "GET, HEAD" });
    }

    if (url.pathname === "/v1/live/trains") return trainsNow(request, env);

    if (url.pathname === "/health") {
      const body = { ok: true, configured: Boolean(env.METROLINX_API_KEY), push: pushConfigured(env) };
      // ?check=push,metrolinx: also ask Apple and Metrolinx whether they accept the keys.
      const checks = (url.searchParams.get("check") ?? "").split(",");
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      if (checks.some(Boolean) && (!env.LIMITER || (await env.LIMITER.limit({ key: ip })).success)) {
        if (checks.includes("push") && body.push) {
          body.apple = {
            production: await checkApple(env, "api.push.apple.com"),
            sandbox: await checkApple(env, "api.sandbox.push.apple.com"),
            recent: await env.LIVE_ACTIVITIES.get(env.LIVE_ACTIVITIES.idFromName("all")).recent(),
          };
        }
        if (checks.includes("metrolinx") && body.configured) body.metrolinx = await checkMetrolinx(env);
        if (checks.includes("live") && body.configured) body.live = await checkLive(env);
      }
      return new Response(JSON.stringify(body), {
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }

    if (!url.pathname.startsWith("/v1/")) return error(404, "Not found");
    const path = url.pathname.slice("/v1".length);
    const route = ROUTES.find((r) => r.pattern.test(path));
    if (!route) return error(404, "Not found");

    if (!env.METROLINX_API_KEY) return error(503, "Live data isn't set up yet");

    if (env.LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      const { success } = await env.LIMITER.limit({ key: ip });
      if (!success) return error(429, "Too many requests", { "Retry-After": "30" });
    }

    let upstream;
    try {
      upstream = await fetch(`${UPSTREAM}${path}?key=${encodeURIComponent(env.METROLINX_API_KEY)}`, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      return error(504, "Metrolinx didn't respond");
    }

    const body = await upstream.text();
    // Metrolinx reports most failures inside a 200 response (Metadata.ErrorCode).
    const code = /"ErrorCode"\s*:\s*"?(\d{3})/.exec(body)?.[1] ?? String(upstream.status);

    if ([401, 403].includes(upstream.status) || code === "401" || code === "403") {
      return error(502, "Metrolinx rejected the proxy's API key");
    }

    const ok = upstream.ok && (code === "200" || code === "204");
    return new Response(body, {
      status: upstream.ok ? 200 : 502,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": ok ? `public, max-age=${route.ttl}` : "no-store",
      },
    });
  },
};

// --- Live train positions ---------------------------------------------------

// How long one look at GO's live feeds is reused (they change about every 20 s).
const LIVE_TTL = 10;
// How often a tracked train is looked at while it runs.
const FOLLOW_EVERY = 20;

let liveMemo = null;

/** GO's two live feeds, merged (see mergeTrains), at most LIVE_TTL seconds old. */
async function liveTrains(env) {
  const now = Date.now();
  if (liveMemo && now >= liveMemo.fetched && now - liveMemo.fetched < LIVE_TTL * 1000) return liveMemo.value;
  const value = Promise.all([
    upstreamJSON(env, "/Gtfs/Feed/VehiclePosition"),
    upstreamJSON(env, "/ServiceataGlance/Trains/All"),
  ]).then(([vehicles, glance]) => {
    if (!vehicles && !glance) throw new Error("No live data");
    return mergeTrains(vehicles, glance, Date.now() / 1000);
  });
  liveMemo = { fetched: now, value };
  value.catch(() => {
    if (liveMemo?.value === value) liveMemo = null;
  });
  return value;
}

async function upstreamJSON(env, path) {
  try {
    const response = await fetch(`${UPSTREAM}${path}?key=${encodeURIComponent(env.METROLINX_API_KEY)}`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return null;
    const body = await response.json();
    const code = String(body?.Metadata?.ErrorCode ?? "200");
    return code === "200" || code === "204" ? body : null;
  } catch {
    return null;
  }
}

async function trainsNow(request, env) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return error(405, "Method not allowed", { Allow: "GET, HEAD" });
  }
  if (!env.METROLINX_API_KEY) return error(503, "Live data isn't set up yet");
  if (env.LIMITER) {
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.LIMITER.limit({ key: ip });
    if (!success) return error(429, "Too many requests", { "Retry-After": "30" });
  }
  try {
    const body = await liveTrains(env);
    return new Response(JSON.stringify(body), {
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": `public, max-age=${LIVE_TTL}` },
    });
  } catch {
    return error(502, "Live train positions are unavailable right now");
  }
}

/** How many trains the live feeds have, and how fresh the freshest is. */
async function checkLive(env) {
  try {
    const { at, trains } = await liveTrains(env);
    const newest = Math.max(...trains.map((train) => train.time));
    const standing = trains.filter((train) => train.status === "at").length;
    return `${trains.length} trains, ${standing} at a station, newest ${Number.isFinite(newest) ? at - newest : "?"} s old`;
  } catch (e) {
    return `failed: ${e?.message ?? e}`;
  }
}

/** Errors use the same envelope as Metrolinx, so the app handles them the same way. */
function error(status, message, extraHeaders = {}) {
  return new Response(
    JSON.stringify({ Metadata: { TimeStamp: "", ErrorCode: String(status), ErrorMessage: message } }),
    { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extraHeaders } },
  );
}

// --- Live Activity push updates ---------------------------------------------

const BUNDLE_ID = "com.robinzhong.Departures";
// A trip's updates are spread over at most this long.
const MAX_AHEAD = 16 * 3600;

function pushConfigured(env) {
  return Boolean(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APPLE_TEAM_ID && env.LIVE_ACTIVITIES);
}

async function activity(request, env, ending) {
  if (request.method !== "POST") return error(405, "Method not allowed", { Allow: "POST" });
  if (!pushConfigured(env)) return error(503, "Push updates aren't set up yet");

  if (env.LIMITER) {
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.LIMITER.limit({ key: ip });
    if (!success) return error(429, "Too many requests", { "Retry-After": "30" });
  }

  const text = await request.text();
  if (text.length > 8192) return error(413, "Too large");
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return error(400, "Not JSON");
  }
  const token = typeof body?.token === "string" ? body.token.toLowerCase() : "";
  if (!/^[0-9a-f]{32,512}$/.test(token)) return error(400, "Bad token");

  const pusher = env.LIVE_ACTIVITIES.get(env.LIVE_ACTIVITIES.idFromName("all"));
  if (ending) {
    await pusher.forget(token);
    return new Response(null, { status: 204 });
  }

  const now = Date.now() / 1000;
  const inRange = (t) => typeof t === "number" && Number.isFinite(t) && t > now - 3600 && t < now + MAX_AHEAD;
  const times = Array.isArray(body.times) ? body.times : [];
  const state = body.state;
  if (
    !["production", "development"].includes(body.environment) ||
    !state || typeof state !== "object" || Array.isArray(state) ||
    JSON.stringify(state).length > 3000 ||
    times.length > 60 || !times.every(inRange) ||
    !inRange(body.end) || !inRange(body.dismissal)
  ) {
    return error(400, "Bad schedule");
  }
  const accepted = await pusher.track({
    token,
    environment: body.environment,
    state,
    times: times.filter((t) => t > now && t < body.end).sort((a, b) => a - b),
    end: body.end,
    dismissal: Math.max(body.dismissal, body.end),
    live: followable(body.live, state, now),
  });
  return accepted ? new Response(null, { status: 204 }) : error(503, "Too many trips tracked");
}

/**
 * The trip's train and stops, for following it live: { trip, codes, scheduled }
 * with one code and planned departure (or null) per stop in `state.stops`. Null
 * when they're missing or don't add up.
 */
function followable(live, state, now) {
  if (!live || typeof live !== "object") return null;
  const { trip, codes, scheduled } = live;
  const stops = Array.isArray(state.stops) ? state.stops : [];
  const planned = (t) => t === null || (typeof t === "number" && Number.isFinite(t) && t > now - 8 * 3600 && t < now + MAX_AHEAD);
  if (
    typeof trip !== "string" || !/^[A-Za-z0-9]{1,12}$/.test(trip) ||
    !Array.isArray(codes) || codes.length < 2 || codes.length > 60 || codes.length !== stops.length ||
    !codes.every((code) => typeof code === "string" && /^[A-Za-z0-9]{1,8}$/.test(code)) ||
    !Array.isArray(scheduled) || scheduled.length !== codes.length || !scheduled.every(planned)
  ) {
    return null;
  }
  return { trip, codes, scheduled };
}

// What a followed trip keeps between looks at its train.
const FOLLOWED = ["obs", "arr", "dep", "delay", "leave", "eta", "followed", "seen", "pushed"];

// One object holds every tracked trip's schedule (there are only ever a few) and
// wakes at the next time any of them is due, or every FOLLOW_EVERY seconds while
// one it follows is running.
export class LiveActivities extends DurableObject {
  async track(job) {
    const key = `job:${job.token}`;
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    if (!jobs.has(key) && jobs.size >= 200) return false;
    const before = jobs.get(key);
    const kept = { revision: before?.revision ?? 0 };
    // The same train again (new times from the app): what's been seen of it stays.
    if (before?.live && job.live && before.live.trip === job.live.trip) {
      for (const field of FOLLOWED) if (before[field] !== undefined) kept[field] = before[field];
    }
    await this.ctx.storage.put(key, { ...job, ...kept, ...watchWindow(job) });
    await this.wake();
    return true;
  }

  async forget(token) {
    await this.ctx.storage.delete(`job:${token}`);
    await this.wake();
  }

  // What Apple said to the last few pushes (no tokens), for the health check.
  async recent() {
    return (await this.ctx.storage.get("log")) ?? [];
  }

  async alarm() {
    const now = Date.now() / 1000;
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    let live;
    for (const [key, job] of jobs) {
      if (watching(job, now)) {
        // Where its train is (one look at the feeds for every trip followed).
        if (live === undefined) live = await liveTrains(this.env).catch(() => null);
        const result = live ? follow(job, live.trains.find((train) => train.trip === job.live.trip), now) : null;
        if (result) {
          const next = result.job;
          if (result.push) {
            next.revision = (next.revision ?? 0) + 1;
            const state = { ...result.push.state, revision: next.revision };
            const { gone, result: said } = await sendPush(this.env, next, { ...result.push, state });
            await this.note(`${result.push.event} live`, said);
            if (gone || result.push.event === "end") {
              await this.ctx.storage.delete(key);
              continue;
            }
          }
          if (result.changed || result.push) await this.ctx.storage.put(key, next);
          continue;
        }
        // Following it, but nothing new to go on: wait for the next look.
        if (job.followed) continue;
      } else if (job.followed && now >= job.watchUntil) {
        // Followed, but never seen getting in: end it.
        job.revision = (job.revision ?? 0) + 1;
        const { result: said } = await sendPush(this.env, job, {
          event: "end", state: { ...job.state, revision: job.revision }, dismissal: now + 60,
        });
        await this.note("end live", said);
        await this.ctx.storage.delete(key);
        continue;
      }

      // Not followed: an update at each of the times the app gave, then the end.
      if (due(job) > now + 1) continue;
      job.revision = (job.revision ?? 0) + 1;
      const state = { ...job.state, revision: job.revision };
      const later = job.times.filter((t) => t > now + 1);
      const ending = now >= job.end - 1;
      const { gone, result } = ending
        ? await sendPush(this.env, job, { event: "end", state, dismissal: job.dismissal })
        : await sendPush(this.env, job, { event: "update", state, stale: later[0] ?? job.end });
      await this.note(ending ? "end" : "update", result);
      if (ending || gone) {
        await this.ctx.storage.delete(key);
      } else {
        await this.ctx.storage.put(key, { ...job, times: later });
      }
    }
    await this.wake();
  }

  /** Keeps what Apple said to the last few pushes (no tokens), for the health check. */
  async note(what, result) {
    const log = (await this.ctx.storage.get("log")) ?? [];
    log.push(`${new Date().toISOString().slice(0, 16)} ${what} ${result}`);
    await this.ctx.storage.put("log", log.slice(-12));
  }

  async wake() {
    const now = Date.now() / 1000;
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    let next = Infinity;
    for (const job of jobs.values()) {
      if (!job.followed) next = Math.min(next, due(job));
      if (job.live) {
        if (now < job.watchFrom) next = Math.min(next, job.watchFrom);
        else if (now < job.watchUntil) next = Math.min(next, now + FOLLOW_EVERY);
        else if (job.followed) next = Math.min(next, now + 1);
      }
    }
    if (next === Infinity) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(next * 1000, Date.now() + 500));
    }
  }
}

function due(job) {
  return Math.min(job.times[0] ?? Infinity, job.end);
}

/**
 * When to follow a trip's train: from 20 minutes before it's due at your
 * station (in case you're waiting for it) until well after it should have got
 * to your stop.
 */
function watchWindow(job) {
  if (!job.live) return {};
  const boarding = Math.max(0, job.state.boardingIndex ?? 0);
  const start = job.live.scheduled[boarding] ?? job.state.departure;
  return {
    watchFrom: start - 20 * 60,
    watchUntil: Math.max(job.end, start) + 45 * 60,
    summary: Math.max(60, job.dismissal - job.end),
  };
}

function watching(job, now) {
  return Boolean(job.live) && now >= job.watchFrom && now < job.watchUntil;
}

// Sends one update (or the end) to a Live Activity through Apple's push service.
// `gone` when Apple no longer knows the token (the activity ended).
async function sendPush(env, job, { event, state, stale, dismissal }) {
  const aps = { timestamp: Math.floor(Date.now() / 1000), event, "content-state": state };
  if (stale) aps["stale-date"] = Math.floor(stale);
  if (dismissal) aps["dismissal-date"] = Math.floor(dismissal);
  const host = job.environment === "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  let response;
  try {
    response = await fetch(`https://${host}/3/device/${job.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(env)}`,
        "apns-topic": `${BUNDLE_ID}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    console.log("APNs unreachable:", String(e));
    return { gone: false, result: "unreachable" };
  }
  if (response.ok) return { gone: false, result: "200" };
  const reason = (await response.json().catch(() => ({}))).reason ?? "";
  console.log(`APNs ${response.status} ${reason} (${event})`);
  // A refused key (expired, or swapped for a new one): sign a fresh token next time.
  if (response.status === 403) provider = null;
  return { gone: response.status === 410 || reason === "BadDeviceToken", result: `${response.status} ${reason}` };
}

// Asks Metrolinx for the Union board: "200 OK" means the API key works.
async function checkMetrolinx(env) {
  try {
    const response = await fetch(
      `${UPSTREAM}/ServiceUpdate/UnionDepartures/All?key=${encodeURIComponent(env.METROLINX_API_KEY)}`,
      { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(10_000) },
    );
    const text = await response.text();
    const code = /"ErrorCode"\s*:\s*"?(\d{3})/.exec(text)?.[1] ?? "";
    const message = /"ErrorMessage"\s*:\s*"([^"]{0,80})/.exec(text)?.[1] ?? "";
    return `${response.status} ${code} ${message}`.replace(/\s+/g, " ").trim();
  } catch (e) {
    return `failed: ${e?.name ?? "Error"}`;
  }
}

// Asks Apple's push service (production for TestFlight and App Store builds,
// sandbox for Xcode's) to update a made-up Live Activity: "400 BadDeviceToken"
// means the push key, Key ID and Team ID were all accepted (only the token is
// wrong); "403 BadEnvironmentKeyInToken", that the key isn't set up for that one.
async function checkApple(env, host) {
  try {
    const response = await fetch(`https://${host}/3/device/${"0".repeat(64)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(env)}`,
        "apns-topic": `${BUNDLE_ID}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { timestamp: Math.floor(Date.now() / 1000), event: "update", "content-state": {} } }),
      signal: AbortSignal.timeout(10_000),
    });
    const reason = (await response.json().catch(() => ({}))).reason ?? "";
    return `${response.status} ${reason}`.trim();
  } catch (e) {
    return `failed: ${e?.name ?? "Error"}: ${e?.message ?? e}`;
  }
}

// Apple's provider token: a JWT signed with the push key, reused for 45 minutes
// (Apple wants a new one at least hourly, and no more often than every 20).
let provider = null;

async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (provider && now - provider.issued < 45 * 60) return provider.token;
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID.trim() }));
  const claims = base64url(JSON.stringify({ iss: env.APPLE_TEAM_ID.trim(), iat: now }));
  const der = Uint8Array.from(atob(env.APNS_KEY_P8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) =>
    c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  provider = { token: `${header}.${claims}.${base64url(signature)}`, issued: now };
  return provider.token;
}

function base64url(input) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
