// Loads the Worker's watcher code (worker/src/watcher.js) outside Cloudflare, for
// tools/record_feeds.mjs and tools/replay_archive.mjs: "cloudflare:workers" is
// only there on Cloudflare, so a stand-in DurableObject takes its place.
import { register } from "node:module";

const stub = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
register("data:text/javascript," + encodeURIComponent(`
  export async function resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") {
      return { url: "data:text/javascript," + encodeURIComponent(${JSON.stringify(stub)}), shortCircuit: true };
    }
    return next(specifier, context);
  }`));

export const watcher = await import("../worker/src/watcher.js");
export const watch = await import("../worker/src/watch.js");
export const record = await import("../worker/src/record.js");
