// What the watcher writes down: every change in GO's two live train feeds, as
// JSON lines, so that any stretch of them can be played back exactly as the
// watcher saw it (tools/replay_archive.mjs does, through the same code).
//
// One line per change:
//
//   {"k":"tick","t":<seen>,"full":true?,"v":{"ok","ts","n"},"g":{"ok","ts","n"}}
//                                   one look at the feeds (`full`: what follows
//                                   is all of both feeds, not just what changed)
//   {"k":"v","t":<seen>,"e":<entity>}    a train's GTFS vehicle position, new or changed
//   {"k":"v-","t":<seen>,"id":"<id>"}    ...gone from the feed
//   {"k":"g","t":<seen>,"e":<trip>}      a train in Service at a Glance, new or changed
//   {"k":"g-","t":<seen>,"id":"<trip>"}  ...gone from it
//   {"k":"trip","t":<seen>,"day","trip","codes",["stops"]}  a trip's stops (GO's Schedule/Trip)
//   {"k":"meta",...}                     at the top of each file: what wrote it
//
// `t` is when the watcher had the answer (Unix seconds). Only trains are kept
// (GO's vehicle positions carry its buses too). The entities are GO's own,
// unchanged: nothing is dropped that a model might later want.

const TRIP_ID = /^(\d{8})-([A-Z]{2})-([A-Za-z0-9]{1,12})$/;

function list(value) {
  return Array.isArray(value) ? value : value && typeof value === "object" ? [value] : [];
}

/** The id a GTFS vehicle position's train goes by (its trip id), or null for a bus or junk. */
export function vehicleId(entity) {
  const id = String(entity?.vehicle?.trip?.trip_id ?? "");
  return TRIP_ID.test(id) ? id : null;
}

/** A trip id's service day and trip number ("20261124-LW-1925": "20261124", "1925"). */
export function tripParts(id) {
  const match = TRIP_ID.exec(String(id ?? ""));
  return match ? { day: match[1], line: match[2], trip: match[3] } : null;
}

function glanceId(trip) {
  const value = trip?.TripNumber;
  const text = typeof value === "string" ? value.trim() : Number.isInteger(value) ? String(value) : "";
  return /^[A-Za-z0-9]{1,12}$/.test(text) ? text : null;
}

/** Notes what changed in the feeds since the last look, as lines (see above). */
export class Recorder {
  constructor() {
    this.vehicles = new Map();
    this.glance = new Map();
  }

  /**
   * One look at the feeds at `now` (either may be null: that feed didn't answer,
   * and what was known of it stands). `full`: write all of both feeds.
   */
  look(vehicles, glance, now, { full = false } = {}) {
    const t = Math.round(now * 1000) / 1000;
    const trains = vehicles ? list(vehicles.entity).filter((entity) => vehicleId(entity)) : null;
    const trips = glance ? list(glance?.Trips?.Trip).filter((trip) => glanceId(trip)) : null;
    const lines = [{
      k: "tick", t, ...(full ? { full: true } : {}),
      v: { ok: Boolean(vehicles), ts: vehicles?.header?.timestamp ?? null, n: trains?.length ?? 0 },
      g: { ok: Boolean(glance), ts: glance?.Metadata?.TimeStamp ?? null, n: trips?.length ?? 0 },
    }];
    if (trains) lines.push(...this.changes(this.vehicles, trains, vehicleId, "v", t, full));
    else if (full) for (const text of this.vehicles.values()) lines.push({ k: "v", t, e: JSON.parse(text) });
    if (trips) lines.push(...this.changes(this.glance, trips, glanceId, "g", t, full));
    else if (full) for (const text of this.glance.values()) lines.push({ k: "g", t, e: JSON.parse(text) });
    return lines;
  }

  changes(known, items, idOf, kind, t, full) {
    const lines = [];
    const seen = new Set();
    for (const item of items) {
      const id = idOf(item);
      if (seen.has(id)) continue;
      seen.add(id);
      const text = JSON.stringify(item);
      if (full || known.get(id) !== text) lines.push({ k: kind, t, e: item });
      known.set(id, text);
    }
    for (const id of [...known.keys()]) {
      if (seen.has(id)) continue;
      known.delete(id);
      if (!full) lines.push({ k: `${kind}-`, t, id });
    }
    return lines;
  }
}

/** Plays recorded lines back into the two feeds as they stood (GO's own shapes). */
export class Player {
  constructor() {
    this.vehicles = new Map();
    this.glance = new Map();
    this.header = { v: null, g: null };
    this.ok = { v: false, g: false };
    /** Each trip's stops as recorded, by `${day}|${trip}`: { codes, stops }. */
    this.trips = new Map();
  }

  apply(line) {
    switch (line?.k) {
      case "tick":
        if (line.full) {
          this.vehicles.clear();
          this.glance.clear();
        }
        this.ok = { v: Boolean(line.v?.ok), g: Boolean(line.g?.ok) };
        this.header = { v: line.v?.ok ? line.v.ts : this.header.v, g: line.g?.ok ? line.g.ts : this.header.g };
        break;
      case "v": {
        const id = vehicleId(line.e);
        if (id) this.vehicles.set(id, line.e);
        break;
      }
      case "v-":
        this.vehicles.delete(line.id);
        break;
      case "g": {
        const id = glanceId(line.e);
        if (id) this.glance.set(id, line.e);
        break;
      }
      case "g-":
        this.glance.delete(line.id);
        break;
      case "trip": {
        const key = `${line.day}|${line.trip}`;
        const before = this.trips.get(key);
        this.trips.set(key, { codes: line.codes, stops: line.stops ?? before?.stops ?? null });
        break;
      }
    }
  }

  /** The feeds as the last look had them (null: that feed didn't answer then): what mergeTrains takes. */
  feeds() {
    return {
      vehicles: this.ok.v ? { header: { timestamp: this.header.v }, entity: [...this.vehicles.values()] } : null,
      glance: this.ok.g
        ? { Metadata: { TimeStamp: this.header.g ?? "", ErrorCode: "200" }, Trips: { Trip: [...this.glance.values()] } }
        : null,
    };
  }
}
