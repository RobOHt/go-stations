// GO Stations API proxy, and push updates for the tracked train's Live Activity.
//
// The app calls https://go-stations.<subdomain>.workers.dev/v1/<path>. This Worker
// adds the Metrolinx Open Data API key (a Worker secret that never ships in the app),
// forwards the request, and marks good answers cacheable for a few seconds so
// everyone looking at the same board shares one Metrolinx request. Only the
// read-only endpoints the app uses are allowed.
//
// POST /v1/activity takes a Live Activity's push token, what it shows, and when
// the train reaches each stop; at each of those times the LiveActivities Durable
// Object has Apple's push service hand the activity an update (so iOS draws it
// again while the app isn't running), and at the end, ends it. POST
// /v1/activity/end forgets one early. Nothing is kept once the trip is over.
// The Apple push key is a Worker secret too (APNS_KEY_P8, APNS_KEY_ID, APPLE_TEAM_ID).

import { DurableObject } from "cloudflare:workers";

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

    if (url.pathname === "/health") {
      const body = { ok: true, configured: Boolean(env.METROLINX_API_KEY), push: pushConfigured(env) };
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
  });
  return accepted ? new Response(null, { status: 204 }) : error(503, "Too many trips tracked");
}

// One object holds every tracked trip's schedule (there are only ever a few) and
// wakes at the next time any of them is due.
export class LiveActivities extends DurableObject {
  async track(job) {
    const key = `job:${job.token}`;
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    if (!jobs.has(key) && jobs.size >= 200) return false;
    await this.ctx.storage.put(key, { ...job, revision: 0 });
    await this.wake();
    return true;
  }

  async forget(token) {
    await this.ctx.storage.delete(`job:${token}`);
    await this.wake();
  }

  async alarm() {
    const now = Date.now() / 1000;
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    for (const [key, job] of jobs) {
      if (due(job) > now + 1) continue;
      job.revision += 1;
      const state = { ...job.state, revision: job.revision };
      const later = job.times.filter((t) => t > now + 1);
      const ending = now >= job.end - 1;
      const { gone } = ending
        ? await sendPush(this.env, job, { event: "end", state, dismissal: job.dismissal })
        : await sendPush(this.env, job, { event: "update", state, stale: later[0] ?? job.end });
      if (ending || gone) {
        await this.ctx.storage.delete(key);
      } else {
        await this.ctx.storage.put(key, { ...job, times: later });
      }
    }
    await this.wake();
  }

  async wake() {
    const jobs = await this.ctx.storage.list({ prefix: "job:" });
    let next = Infinity;
    for (const job of jobs.values()) next = Math.min(next, due(job));
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
    return { gone: false };
  }
  if (response.ok) return { gone: false };
  const reason = (await response.json().catch(() => ({}))).reason ?? "";
  console.log(`APNs ${response.status} ${reason} (${event})`);
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") provider = null;
  return { gone: response.status === 410 || reason === "BadDeviceToken" };
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
