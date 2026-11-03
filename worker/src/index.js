// GO Stations API proxy.
//
// The app calls https://go-stations.<subdomain>.workers.dev/v1/<path>. This Worker
// adds the Metrolinx Open Data API key (a Worker secret that never ships in the app),
// forwards the request, and marks good answers cacheable for a few seconds so
// everyone looking at the same board shares one Metrolinx request.
//
// Only the read-only endpoints the app uses are allowed.

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

    if (request.method !== "GET" && request.method !== "HEAD") {
      return error(405, "Method not allowed", { Allow: "GET, HEAD" });
    }

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ ok: true, configured: Boolean(env.METROLINX_API_KEY) }), {
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
