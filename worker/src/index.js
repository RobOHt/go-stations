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
// GET /v1/live/cancelled: which trains aren't running, or won't stop somewhere
// they were due to, from GO's train exceptions and its GTFS trip updates
// together (src/live.js), cached half a minute.
//
// POST /v1/activity takes a Live Activity's push token, what it shows, and when
// the train reaches each stop; at each of those times the LiveActivities Durable
// Object has Apple's push service hand the activity an update (so iOS draws it
// again while the app isn't running), and at the end, ends it. With the trip's
// stops (`live`), it instead follows the train itself while it runs: every 20
// seconds it looks where the train is, and pushes an update when it pulls in at
// a stop or leaves one. On a journey with changes (`legs`), it takes the next
// train on once the one you're on gets in where you change. With `alerts`, the
// push 5 minutes before the train gets to where you change or get off comes with
// an alert (sound, screen on). On the first train of a trip from search
// (`missedCheck`, with the app's own push token, `device`), a couple of minutes
// after it leaves where you get on, a silent push wakes the app to check you're
// on it. A tracked train found cancelled (or not stopping where you get on or
// off) shows so in its Live Activity, with an alert (none for a trip you asked
// not to be notified about), until a while after it was due; the app is woken
// to find the next train. POST /v1/activity/end forgets one early. Nothing is kept once the trip
// is over. The Apple push key is a Worker secret too (APNS_KEY_P8, APNS_KEY_ID,
// APPLE_TEAM_ID).

import { DurableObject } from "cloudflare:workers";
import {
  alertFor, alertTime, cancelAlert, cancellationFor, cancellations, cancelledContent, cancelledUntil, connectionAlert,
  connectionFor, follow, mergeTrains, missedCheck, nextLeg, shownState, watchWindow,
} from "./live.js";

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
    if (url.pathname === "/v1/live/cancelled") return cancelledNow(request, env);

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
        if (checks.includes("cancelled") && body.configured) body.cancelled = await checkCancelled(env);
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

// How long one look at GO's live feeds is reused (each train's position changes
// about every 20 s; the app looks every 5 s while its map shows trains).
const LIVE_TTL = 5;
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

// --- Cancelled trains ---------------------------------------------------------

// How long one look at GO's cancellations is reused (the trip updates are big:
// about 700 KB to read through).
const CANCELLED_TTL = 30;

let cancelledMemo = null;

/**
 * Which trains aren't running, or won't stop somewhere they were due to (see
 * cancellations in src/live.js), at most CANCELLED_TTL seconds old:
 * { at, trips, from } (`from`: the feeds that answered).
 */
async function cancelledTrains(env) {
  const now = Date.now();
  if (cancelledMemo && now >= cancelledMemo.fetched && now - cancelledMemo.fetched < CANCELLED_TTL * 1000) {
    return cancelledMemo.value;
  }
  const value = Promise.all([
    upstreamJSON(env, "/ServiceUpdate/Exceptions/Train"),
    upstreamJSON(env, "/Gtfs/Feed/TripUpdates"),
  ]).then(([exceptions, updates]) => {
    if (!exceptions && !updates) throw new Error("No cancellation data");
    return {
      at: Math.floor(Date.now() / 1000),
      trips: cancellations(exceptions, updates),
      from: [exceptions && "exceptions", updates && "updates"].filter(Boolean),
    };
  });
  cancelledMemo = { fetched: now, value };
  value.catch(() => {
    if (cancelledMemo?.value === value) cancelledMemo = null;
  });
  return value;
}

async function cancelledNow(request, env) {
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
    const body = await cancelledTrains(env);
    return new Response(JSON.stringify(body), {
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": `public, max-age=${CANCELLED_TTL}` },
    });
  } catch {
    return error(502, "Cancellations are unavailable right now");
  }
}

/** How many trains the feeds say aren't running, or skip stations, and which feeds answered. */
async function checkCancelled(env) {
  try {
    const { trips, from } = await cancelledTrains(env);
    const all = trips.filter((trip) => trip.all).length;
    const skipping = trips.filter((trip) => !trip.all && trip.skips?.length).length;
    return `${all} cancelled, ${skipping} skipping stations (from ${from.join(" and ")})`;
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
  if (text.length > 16384) return error(413, "Too large");
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
  // The trains after this one, on a journey with changes: the same again for each.
  const legs = [];
  for (const leg of Array.isArray(body.legs) ? body.legs.slice(0, 2) : []) {
    const legTimes = Array.isArray(leg?.times) ? leg.times : [];
    if (
      !leg?.state || typeof leg.state !== "object" || Array.isArray(leg.state) ||
      JSON.stringify(leg.state).length > 3000 ||
      legTimes.length > 60 || !legTimes.every(inRange) || !inRange(leg.end) || !inRange(leg.dismissal)
    ) {
      return error(400, "Bad leg");
    }
    legs.push({
      state: leg.state,
      times: [...legTimes].sort((a, b) => a - b),
      end: leg.end,
      dismissal: Math.max(leg.dismissal, leg.end),
      live: followable(leg.live, leg.state, now),
    });
  }
  const device = typeof body.device === "string" ? body.device.toLowerCase() : "";
  const hasDevice = /^[0-9a-f]{64,200}$/.test(device);
  const accepted = await pusher.track({
    token,
    environment: body.environment,
    state,
    times: times.filter((t) => t > now && t < body.end).sort((a, b) => a - b),
    end: body.end,
    dismissal: Math.max(body.dismissal, body.end),
    live: followable(body.live, state, now),
    alerts: body.alerts === true,
    // Asked not to be notified about this trip: not even when its train is cancelled.
    quiet: body.quiet === true,
    // The app has told you its train (or the next one) is cancelled.
    ...(body.told === true ? { cancelAlerted: true } : {}),
    ...(body.toldConnection === true ? { connectionAlerted: true } : {}),
    legs,
    // The app's own token: to wake it once the first train has left (did you catch
    // it?), and when its train is cancelled (to find the next one).
    ...(hasDevice ? { device } : {}),
    ...(body.missedCheck === true && hasDevice ? { missedCheck: true } : {}),
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

// What a followed trip keeps between looks at its train (and at whether it's cancelled).
const FOLLOWED = [
  "obs", "arr", "dep", "delay", "leave", "eta", "followed", "seen", "pushed", "missedSent",
  "cancelled", "cancelledUntil", "cancelAlerted", "backAlerted", "cleared", "cancelCheckedAt", "cancelRetryAt",
];
// On a trip with changes, what's kept of the next train's while it's the same one.
const CONNECTION = [
  "connectionCancelled", "connectionCheckedAt", "connectionCleared", "connectionAlerted", "connectionBackAlerted",
  "connectionAlertDue",
];
// How often a tracked train not followed yet is looked up among the cancelled ones.
const CANCEL_EVERY = 120;
// Looks in a row without it among them before a cancelled train is taken to be running again.
const CLEARED_AFTER = 2;

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
    const connection = (each) => each?.legs?.[0]?.live?.trip;
    if (connection(before) && connection(before) === connection(job)) {
      for (const field of CONNECTION) if (before[field] !== undefined) kept[field] = before[field];
    }
    // An alert sent stays sent (it names its train and stop).
    if (before?.alerted !== undefined) kept.alerted = before.alerted;
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
    let cancelled;
    for (const [key, job] of jobs) {
      // Is its train cancelled (or running after all)? Looked up every couple of
      // minutes until it's followed, then with every look at it.
      if (job.live && now < (job.watchUntil ?? 0) &&
          (watching(job, now) || now >= lastLook(job) + CANCEL_EVERY - 1)) {
        if (cancelled === undefined) cancelled = await cancelledTrains(this.env).catch(() => null);
        if (cancelled) {
          if (await this.checkCancelled(key, job, cancelled.trips, now)) continue;
          if (!job.cancelled && (await this.checkConnection(key, job, cancelled.trips, now))) continue;
        } else if (!watching(job, now) || job.cancelled) {
          // No answer from the feeds: the next look after the usual wait. (Not a
          // look: what the app said of it stands meanwhile, see shownState.)
          job.cancelRetryAt = now;
          await this.ctx.storage.put(key, job);
        }
      }
      if (job.cancelled) {
        // Cancelled: it says so until a while after it was due, then it ends.
        if (now >= (job.cancelledUntil ?? 0)) {
          job.revision = (job.revision ?? 0) + 1;
          const { result } = await sendPush(this.env, job, {
            event: "end", state: { ...job.state, revision: job.revision }, dismissal: now + 120,
          });
          await this.note("end cancelled", result);
          await this.ctx.storage.delete(key);
        }
        continue;
      }
      if (watching(job, now)) {
        // Where its train is (one look at the feeds for every trip followed).
        if (live === undefined) live = await liveTrains(this.env).catch(() => null);
        const train = live?.trains.find((each) => each.trip === job.live.trip);
        const result = live ? follow(job, train, now) : null;
        if (result) {
          let next = result.job;
          let push = result.push;
          // Gone from where you get on a couple of minutes ago: are you on it? (The
          // app knows where you are.)
          const check = missedCheck(next, train, now);
          if (check) {
            next.missedSent = true;
            await this.note("missed check", await sendWake(this.env, next, { missed: check }));
          }
          if (push?.event === "end" && next.legs?.length) {
            // In where you change: on to the next train.
            next = nextLeg(next, now);
            push = { event: "update", state: next.state, stale: next.times[0] ?? next.end };
          } else if (push?.event !== "end") {
            // The next train found cancelled meanwhile (see checkConnection): that
            // first, then the alert before where you change.
            const connection = next.connectionAlertDue;
            const alert = connection ?? alertFor(next, result.state, now);
            if (alert) {
              if (connection) {
                next.connectionAlerted = true;
                delete next.connectionAlertDue;
              } else {
                next.alerted = alert.key;
              }
              push = { ...(push ?? { event: "update", state: result.state, stale: result.stale }), alert };
            }
          }
          if (push) {
            next.revision = (next.revision ?? 0) + 1;
            const state = { ...push.state, revision: next.revision };
            const { gone, result: said } = await sendPush(this.env, next, { ...push, state });
            await this.note(`${push.alert ? "alert" : push.event} live`, said);
            if (gone || push.event === "end") {
              await this.ctx.storage.delete(key);
              continue;
            }
          }
          if (result.changed || push || check) await this.ctx.storage.put(key, next);
          continue;
        }
        // Following it, but nothing new to go on: wait for the next look.
        if (job.followed) continue;
      } else if (job.followed && now >= job.watchUntil) {
        // Followed, but never seen getting in: on to the next train, or end it.
        if (job.legs?.length) {
          const next = nextLeg(job, now);
          next.revision = (next.revision ?? 0) + 1;
          const { gone, result: said } = await sendPush(this.env, next, {
            event: "update", state: { ...next.state, revision: next.revision }, stale: next.times[0] ?? next.end,
          });
          await this.note("change lost", said);
          if (gone) await this.ctx.storage.delete(key);
          else await this.ctx.storage.put(key, next);
          continue;
        }
        job.revision = (job.revision ?? 0) + 1;
        const { result: said } = await sendPush(this.env, job, {
          event: "end", state: { ...job.state, revision: job.revision }, dismissal: now + 60,
        });
        await this.note("end live", said);
        await this.ctx.storage.delete(key);
        continue;
      }

      // Not followed: an update at each of the times the app gave (with the alert
      // when it's due), then the end, or on to the next train where you change.
      if (due(job, now) > now + 1) continue;
      const ending = now >= job.end - 1;
      if (ending && job.legs?.length) {
        const next = nextLeg(job, now);
        next.revision = (next.revision ?? 0) + 1;
        const { gone, result } = await sendPush(this.env, next, {
          event: "update", state: { ...next.state, revision: next.revision }, stale: next.times[0] ?? next.end,
        });
        await this.note("change", result);
        if (gone) await this.ctx.storage.delete(key);
        else await this.ctx.storage.put(key, next);
        continue;
      }
      job.revision = (job.revision ?? 0) + 1;
      const state = { ...job.state, revision: job.revision };
      const later = job.times.filter((t) => t > now + 1);
      const alert = ending ? null : alertFor(job, job.state, now);
      if (alert) job.alerted = alert.key;
      const { gone, result } = ending
        ? await sendPush(this.env, job, { event: "end", state, dismissal: job.dismissal })
        : await sendPush(this.env, job, { event: "update", state, stale: later[0] ?? job.end, alert });
      await this.note(ending ? "end" : alert ? "alert" : "update", result);
      if (ending || gone) {
        await this.ctx.storage.delete(key);
      } else {
        await this.ctx.storage.put(key, { ...job, times: later });
      }
    }
    await this.wake();
  }

  /**
   * Looks the job's train up among the cancelled ones (`trips`, from
   * cancelledTrains): newly cancelled, its Live Activity says so, with an alert
   * (unless you asked not to be notified), and the app's woken to find the next
   * train; no longer cancelled two looks in a row, it's running after all (said
   * with an alert, when the cancellation was). True when that's all for the job
   * this time round.
   */
  async checkCancelled(key, job, trips, now) {
    const verdict = cancellationFor(job, trips);
    const watched = watching(job, now);
    const before = job.cancelled ?? null;
    job.cancelCheckedAt = now;
    if (verdict) {
      job.cleared = 0;
      if (before && JSON.stringify(cancelledContent(before)) === JSON.stringify(cancelledContent(verdict))) {
        // Still cancelled, as it says.
        if (!watched) await this.ctx.storage.put(key, job);
        return false;
      }
      job.cancelled = verdict;
      job.cancelledUntil = cancelledUntil(job, verdict, now);
      const alert = job.quiet || job.cancelAlerted ? null : cancelAlert(job, verdict);
      if (alert) job.cancelAlerted = true;
      job.revision = (job.revision ?? 0) + 1;
      const { gone, result } = await sendPush(this.env, job, {
        event: "update", state: { ...job.state, revision: job.revision }, stale: job.cancelledUntil, alert,
      });
      await this.note(alert ? "alert cancelled" : "cancelled", result);
      if (gone) {
        await this.ctx.storage.delete(key);
        return true;
      }
      // The app, woken, finds the next train (it knows the boards; the worker doesn't).
      if (!before && job.device) {
        await this.note("wake cancelled", await sendWake(this.env, job, { cancelled: { trip: job.live.trip } }));
      }
      await this.ctx.storage.put(key, job);
      return true;
    }
    if (before) {
      job.cleared = (job.cleared ?? 0) + 1;
      if (job.cleared < CLEARED_AFTER) {
        await this.ctx.storage.put(key, job);
        return true;
      }
      // Running after all: as it was, followed again from the next look.
      job.cancelled = null;
      delete job.cancelledUntil;
      job.pushed = null;
      const alert = !job.quiet && job.cancelAlerted && !job.backAlerted ? cancelAlert(job, null, { back: true }) : null;
      if (alert) job.backAlerted = true;
      job.revision = (job.revision ?? 0) + 1;
      const stale = job.times.find((t) => t > now) ?? job.end;
      const { gone, result } = await sendPush(this.env, job, {
        event: "update", state: { ...job.state, revision: job.revision }, stale, alert,
      });
      await this.note(alert ? "alert running" : "running", result);
      if (gone) await this.ctx.storage.delete(key);
      else await this.ctx.storage.put(key, job);
      return true;
    }
    if (!watched) await this.ctx.storage.put(key, job);
    return false;
  }

  /**
   * On a trip with changes, the next train looked up among the cancelled ones
   * (see connectionFor). Newly cancelled, the activity's change line says so,
   * with an alert (unless you asked not to be notified, or the app told you); no
   * longer listed two looks in a row, it says so no more (with an alert, when the
   * cancellation had one). Followed, that goes with the train's next report (the
   * activity shows its times as they stand, not as planned); otherwise it's
   * pushed now. True when that's all for the job this time round.
   */
  async checkConnection(key, job, trips, now) {
    if (!job.legs?.[0]?.live) return false;
    const verdict = connectionFor(job, trips);
    const first = job.connectionCheckedAt == null;
    job.connectionCheckedAt = now;
    const before = Boolean(job.connectionCancelled);
    if (verdict) job.connectionCleared = 0;
    if (Boolean(verdict) === before) {
      if (first && !watching(job, now)) await this.ctx.storage.put(key, job);
      return false;
    }
    if (!verdict) {
      // Gone from the feeds: one look isn't enough (each has had what the other hadn't).
      job.connectionCleared = (job.connectionCleared ?? 0) + 1;
      if (job.connectionCleared < CLEARED_AFTER) {
        await this.ctx.storage.put(key, job);
        return false;
      }
    }
    job.connectionCancelled = verdict ?? null;
    let alert = null;
    if (verdict && !job.quiet && !job.connectionAlerted) {
      alert = connectionAlert(job);
    } else if (!verdict && !job.quiet && job.connectionAlerted && !job.connectionBackAlerted) {
      alert = connectionAlert(job, { back: true });
      job.connectionBackAlerted = true;
    }
    if (job.followed && watching(job, now)) {
      // With the train's next report.
      job.pushed = null;
      if (alert) job.connectionAlertDue = alert;
      else delete job.connectionAlertDue;
      await this.ctx.storage.put(key, job);
      return false;
    }
    delete job.connectionAlertDue;
    if (alert && verdict) job.connectionAlerted = true;
    job.revision = (job.revision ?? 0) + 1;
    const stale = job.times.find((t) => t > now) ?? job.end;
    const { gone, result } = await sendPush(this.env, job, {
      event: "update", state: { ...job.state, revision: job.revision }, stale, alert,
    });
    await this.note(alert ? "alert connection" : "connection", result);
    if (gone) await this.ctx.storage.delete(key);
    else await this.ctx.storage.put(key, job);
    return true;
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
      if (job.cancelled) {
        // Cancelled: its end, and the next look (is it running after all?).
        const look = now < job.watchFrom ? Math.max(lastLook(job) + CANCEL_EVERY, now + 1) : now + FOLLOW_EVERY;
        next = Math.min(next, job.cancelledUntil ?? now + 60, look);
        continue;
      }
      if (!job.followed) next = Math.min(next, due(job, now));
      if (job.live) {
        if (now < job.watchFrom) {
          next = Math.min(next, job.watchFrom, Math.max(lastLook(job) + CANCEL_EVERY, now + 1));
        } else if (now < job.watchUntil) {
          next = Math.min(next, now + FOLLOW_EVERY);
        } else if (job.followed) {
          next = Math.min(next, now + 1);
        }
      }
    }
    if (next === Infinity) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(next * 1000, Date.now() + 500));
    }
  }
}

/** The next time a trip that isn't followed needs a push: an update, its alert, or the end. */
function due(job, now) {
  return Math.min(job.times[0] ?? Infinity, job.end, alertTime(job, now) ?? Infinity);
}

/** When the feeds were last looked at (or asked, without an answer) for whether its trains are cancelled. */
function lastLook(job) {
  return Math.max(job.cancelCheckedAt ?? 0, job.cancelRetryAt ?? 0);
}

function watching(job, now) {
  return Boolean(job.live) && now >= job.watchFrom && now < job.watchUntil;
}

// Sends one update (or the end) to a Live Activity through Apple's push service,
// with whether its train is cancelled as the worker last looked (see shownState).
// `gone` when Apple no longer knows the token (the activity ended).
async function sendPush(env, job, { event, state, stale, dismissal, alert }) {
  // Cancelled or not, as the worker last looked (see shownState).
  const aps = { timestamp: Math.floor(Date.now() / 1000), event, "content-state": shownState(job, state) };
  if (stale) aps["stale-date"] = Math.floor(stale);
  if (dismissal) aps["dismissal-date"] = Math.floor(dismissal);
  // Lights the screen with the Live Activity (and shows on a watch), with a sound.
  if (alert) aps.alert = { title: alert.title, body: alert.body, sound: "default" };
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

// Wakes the app in the background with a silent push to its own token (not the
// Live Activity's), carrying `payload`. Apple may hold it back a little, or
// drop it when the app was swiped away.
async function sendWake(env, job, payload) {
  const host = job.environment === "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  try {
    const response = await fetch(`https://${host}/3/device/${job.device}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(env)}`,
        "apns-topic": BUNDLE_ID,
        "apns-push-type": "background",
        "apns-priority": "5",
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { "content-available": 1 }, ...payload }),
      signal: AbortSignal.timeout(10_000),
    });
    if (response.ok) return "200";
    const reason = (await response.json().catch(() => ({}))).reason ?? "";
    console.log(`APNs ${response.status} ${reason} (wake)`);
    if (response.status === 403) provider = null;
    return `${response.status} ${reason}`;
  } catch (e) {
    console.log("APNs unreachable:", String(e));
    return "unreachable";
  }
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
