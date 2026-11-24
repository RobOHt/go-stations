// The rail network's track, and a trip's run along it: the same geometry the app
// draws trains on (TrackGeometry, CommutePlanner.Path and TrainRun in the app),
// so a train is placed here exactly where the app places it.
//
// Positions are metres on one flat projection of southern Ontario (cos 43.7°),
// as in the app. The network is the app's own bundled file, built from GO's GTFS
// by tools/build_network.py.

const METRES_PER_DEGREE = (6371000 * Math.PI) / 180;
/** cos(43.7°): one flat projection for the whole network. */
const COS_REF = 0.7229671459095681;
/** A station closer than this to a track shape is on it, in metres. */
const SNAP = 600;

export function point(latitude, longitude) {
  return { x: longitude * COS_REF * METRES_PER_DEGREE, y: latitude * METRES_PER_DEGREE };
}

export function coordinate(p) {
  return { latitude: p.y / METRES_PER_DEGREE, longitude: p.x / (COS_REF * METRES_PER_DEGREE) };
}

function distance(p, q) {
  const dx = p.x - q.x;
  const dy = p.y - q.y;
  return Math.sqrt(dx * dx + dy * dy);
}

/** Distance from p to the segment ab, and how far along it (0...1) the closest point is. */
function project(p, a, b) {
  const vx = b.x - a.x;
  const vy = b.y - a.y;
  const wx = p.x - a.x;
  const wy = p.y - a.y;
  const vv = vx * vx + vy * vy;
  let t = 0;
  if (vv > 0) t = Math.min(Math.max((wx * vx + wy * vy) / vv, 0), 1);
  return { distance: distance(p, { x: a.x + vx * t, y: a.y + vy * t }), t };
}

/** A line of track: its points, and how far along it each one is. */
export class Path {
  constructor(points) {
    this.points = points;
    this.cumulative = [0];
    for (let i = 0; i < points.length - 1; i++) {
      this.cumulative.push(this.cumulative[i] + distance(points[i], points[i + 1]));
    }
  }

  get length() {
    return this.cumulative[this.cumulative.length - 1];
  }

  /** Distance to the closest point on the path, and how far along the path it is. */
  project(p) {
    let best = null;
    for (let i = 0; i < this.points.length - 1; i++) {
      const r = project(p, this.points[i], this.points[i + 1]);
      if (best == null || r.distance < best.distance) {
        best = { distance: r.distance, arc: this.cumulative[i] + (this.cumulative[i + 1] - this.cumulative[i]) * r.t };
      }
    }
    return best ?? { distance: distance(p, this.points[0]), arc: 0 };
  }

  pointAt(arc) {
    const points = this.points;
    if (points.length === 1) return points[0];
    const s = Math.min(Math.max(arc, 0), this.length);
    let i = 0;
    while (i < points.length - 2 && this.cumulative[i + 1] < s) i++;
    const length = this.cumulative[i + 1] - this.cumulative[i];
    const u = length <= 0 ? 0 : (s - this.cumulative[i]) / length;
    const a = points[i];
    const b = points[i + 1];
    return { x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u };
  }

  /** The stretch of the path between two distances along it. */
  piece(s0, s1) {
    const lo = Math.min(s0, s1);
    const hi = Math.max(s0, s1);
    const result = [this.pointAt(lo)];
    for (let i = 0; i < this.points.length; i++) {
      if (lo < this.cumulative[i] && this.cumulative[i] < hi) result.push(this.points[i]);
    }
    result.push(this.pointAt(hi));
    return result;
  }
}

/** The network's stations and track shapes (the app's network.json). */
export class Network {
  constructor(file) {
    this.version = String(file?.feedVersion ?? "");
    this.position = new Map();
    for (const station of file?.stations ?? []) {
      if (!this.position.has(station.code)) this.position.set(station.code, point(station.lat, station.lon));
    }
    this.paths = new Map();
    this.lineCode = new Map();
    this.patterns = new Map();
    for (const line of file?.lines ?? []) {
      const paths = [];
      for (const coordinates of line.paths ?? []) {
        const points = coordinates.filter((pair) => pair.length === 2).map(([lat, lon]) => point(lat, lon));
        if (points.length >= 2) paths.push(new Path(points));
      }
      this.paths.set(line.code, paths);
      this.patterns.set(line.code, line.patterns ?? []);
      this.lineCode.set(line.code, line.code);
      if (!this.lineCode.has(line.apiCode)) this.lineCode.set(line.apiCode, line.code);
    }
    this.segments = new Map();
  }

  /** A line's code as the network has it (Kitchener is "GT" in GO's feeds, "KI" here). */
  line(code) {
    return this.lineCode.get(String(code ?? "").trim().toUpperCase()) ?? null;
  }

  station(code) {
    return this.position.get(code) ?? null;
  }

  /** The track shape both stops sit on, and how far along it each one is. */
  locate(line, a, b) {
    const pa = this.position.get(a);
    const pb = this.position.get(b);
    if (!pa || !pb) return null;
    let best = null;
    for (const path of this.paths.get(line) ?? []) {
      const ra = path.project(pa);
      const rb = path.project(pb);
      if (ra.distance > SNAP || rb.distance > SNAP) continue;
      const score = ra.distance + rb.distance;
      if (best == null || score < best.score) best = { score, path, sa: ra.arc, sb: rb.arc };
    }
    return best;
  }

  /** The track between two neighbouring stops, in travel order (a straight line where no shape joins them). */
  segment(line, a, b) {
    const key = `${line}|${a}|${b}`;
    if (this.segments.has(key)) return this.segments.get(key);
    let found = null;
    const pa = this.position.get(a);
    const pb = this.position.get(b);
    if (pa && pb) {
      const hit = this.locate(line, a, b);
      let points;
      if (hit) {
        points = hit.path.piece(hit.sa, hit.sb);
        if (hit.sa > hit.sb) points.reverse();
      } else {
        points = [pa, pb];
      }
      if (points.length >= 2) found = new Path(points);
    }
    this.segments.set(key, found);
    return found;
  }
}

/**
 * One end of a stretch of track: the way it runs over its first (or last) 100 m,
 * so a kink in the last metre of a track shape doesn't turn it.
 */
function end(path, atStart) {
  if (!path) return null;
  const length = path.length;
  if (!(length > 1)) return null;
  const span = Math.min(100, length);
  const from = path.pointAt(atStart ? 0 : length - span);
  const to = path.pointAt(atStart ? span : length);
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const size = Math.sqrt(dx * dx + dy * dy);
  if (!(size > 0)) return null;
  return { point: atStart ? from : to, east: dx / size, north: dy / size };
}

/** How far `position` is past an end the way trains travel (negative: short of it), and how far to one side. */
function offset(edge, position) {
  const dx = position.x - edge.point.x;
  const dy = position.y - edge.point.y;
  return { on: dx * edge.east + dy * edge.north, beside: Math.abs(dx * edge.north - dy * edge.east) };
}

/**
 * A trip's run along its stops, measured along the track: where each stop is, in
 * metres from the first, and the track between them (TrainRun in the app).
 */
export class Run {
  /** A report further than this from the run's track, in metres, isn't on it (a yard, a detour). */
  static ON_TRACK = 250;
  /** A train within this of a station's own spot on the line, in metres, may be at its platform. */
  static PLATFORM = 150;
  /** A train carried on past its latest report is taken no nearer the station it's heading for than this. */
  static CLEAR = 250;
  /** A train is placed up to this far short of the run's start or past its end, straight along the track. */
  static BEYOND = 400;
  /** Within this of an end of the run's track, a position past that end is placed beyond it. */
  static AT_END = 10;

  /** `segment(a, b)`: the Path between two neighbouring stops, or null. */
  constructor(codes, segment) {
    this.codes = codes;
    this.paths = [];
    this.starts = [0];
    for (let i = 0; i < Math.max(codes.length - 1, 0); i++) {
      const path = segment(codes[i], codes[i + 1]);
      this.paths.push(path);
      this.starts.push(this.starts[i] + (path ? path.length : 0));
    }
    this.head = end(this.paths[0] ?? null, true);
    this.tail = end(this.paths[this.paths.length - 1] ?? null, false);
  }

  /** A trip's run along its line through its stops, by the network's track. */
  static on(network, line, codes) {
    return new Run(codes, (a, b) => network.segment(line, a, b));
  }

  get length() {
    return this.starts[this.starts.length - 1] ?? 0;
  }

  /**
   * Where one report has the train: how far along the run the nearest point of
   * its track is, how far off the track the position is, and the stop it's at
   * or heading for (GO's word for it when that's one of the run's stops, from
   * `hint` on; otherwise the next one along). Null when the run has no track.
   */
  place(report, hint = 0) {
    const position = point(report.lat, report.lon);
    let best = null;
    for (let index = 0; index < this.paths.length; index++) {
      const path = this.paths[index];
      if (!path) continue;
      const hit = path.project(position);
      if (best && best.off <= hit.distance) continue;
      best = { distance: this.starts[index] + hit.arc, off: hit.distance };
    }
    if (!best) return null;
    if (best.distance < Run.AT_END && this.head) {
      const past = offset(this.head, position);
      if (past.on < 0 && past.on >= -Run.BEYOND) best = { distance: past.on, off: past.beside };
    } else if (best.distance > this.length - Run.AT_END && this.tail) {
      const past = offset(this.tail, position);
      if (past.on > 0 && past.on <= Run.BEYOND) best = { distance: this.length + past.on, off: past.beside };
    }
    let stop = this.starts.findIndex((start) => start > best.distance - Run.PLATFORM);
    if (stop < 0) stop = Math.max(this.starts.length - 1, 0);
    let isAt = false;
    const fix = stopFix(report, this.codes, hint);
    if (fix && fix.index < this.starts.length) {
      stop = fix.index;
      isAt = fix.isAt;
    }
    return { time: report.time, distance: best.distance, off: best.off, stop, isAt };
  }
}

/** The stop a report says the train is at or heading for, among `codes` from `hint` on (LiveTrain.fix in the app). */
function stopFix(report, codes, hint) {
  if (!report.stop || (report.status !== "at" && report.status !== "to")) return null;
  const start = Math.min(Math.max(hint, 0), codes.length);
  for (let i = start; i < codes.length; i++) {
    if (codes[i] === report.stop) return { index: i, isAt: report.status === "at" };
  }
  return null;
}
