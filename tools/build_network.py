#!/usr/bin/env python3
"""Build Departures/Resources/network.json from the official GO Transit GTFS feed.

The app bundles this file so the map (track shapes, stations, official line
colours) works instantly and offline. Re-run it whenever Metrolinx publishes a
new feed (roughly every 6 weeks) or when lines/stations change.

Usage:
    python3 tools/build_network.py                    # downloads the official feed
    python3 tools/build_network.py --input GO-GTFS.zip
    python3 tools/build_network.py --output Departures/Resources/network.json

Data: Metrolinx GTFS, Open Government Licence – Ontario.
"""
import argparse
import csv
import io
import json
import math
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from urllib.request import urlopen

OFFICIAL_URL = "https://assets.metrolinx.com/raw/upload/Documents/Metrolinx/Open%20Data/GO-GTFS.zip"

# GTFS route_short_name -> code the Metrolinx Open Data API uses for that line.
API_LINE_CODE = {"KI": "GT"}

SIMPLIFY_METERS = 6.0     # Douglas-Peucker tolerance
COVERED_METERS = 25.0     # a shape fully within this distance of another is redundant


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=OFFICIAL_URL, help="GTFS zip path or URL")
    ap.add_argument("--output", default="Departures/Resources/network.json")
    return ap.parse_args()


def open_zip(src):
    if src.startswith("http"):
        print("Downloading", src, file=sys.stderr)
        return zipfile.ZipFile(io.BytesIO(urlopen(src, timeout=300).read()))
    return zipfile.ZipFile(src)


def rows(z, name):
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))


# --- geometry ---------------------------------------------------------------

def to_xy(lat, lon, lat0):
    k = 111_320.0
    return (lon * k * math.cos(math.radians(lat0)), lat * 110_540.0)


def seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplify(points, tol, lat0):
    """Iterative Douglas-Peucker on (lat, lon) points, tolerance in metres."""
    if len(points) < 3:
        return points
    xy = [to_xy(la, lo, lat0) for la, lo in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        best, idx = 0.0, -1
        for k in range(i + 1, j):
            d = seg_dist(xy[k], xy[i], xy[j])
            if d > best:
                best, idx = d, k
        if best > tol and idx > 0:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))
    return [p for p, k in zip(points, keep) if k]


class SegmentIndex:
    """Grid index of a polyline's segments for fast point-to-line distance."""

    CELL = 200.0

    def __init__(self, xy):
        self.cells = defaultdict(list)
        for a, b in zip(xy, xy[1:]):
            x0, x1 = sorted((a[0], b[0]))
            y0, y1 = sorted((a[1], b[1]))
            for cx in range(int(x0 // self.CELL) - 1, int(x1 // self.CELL) + 2):
                for cy in range(int(y0 // self.CELL) - 1, int(y1 // self.CELL) + 2):
                    self.cells[(cx, cy)].append((a, b))

    def distance(self, p):
        segs = self.cells.get((int(p[0] // self.CELL), int(p[1] // self.CELL)))
        if not segs:
            return float("inf")
        return min(seg_dist(p, a, b) for a, b in segs)


def drop_covered(paths, lat0):
    """Remove paths that lie entirely on top of a longer path of the same line."""
    paths = sorted(paths, key=len, reverse=True)
    kept, kept_idx = [], []
    for path in paths:
        xy = [to_xy(la, lo, lat0) for la, lo in path]
        if any(all(ix.distance(p) <= COVERED_METERS for p in xy) for ix in kept_idx):
            continue
        kept.append(path)
        kept_idx.append(SegmentIndex(xy))
    return kept


# --- main -------------------------------------------------------------------

def main():
    args = parse_args()
    z = open_zip(args.input)

    routes = {r["route_id"]: r for r in rows(z, "routes.txt") if r["route_type"] == "2"}
    rail_trips = {t["trip_id"]: t for t in rows(z, "trips.txt") if t["route_id"] in routes}

    stop_seq = defaultdict(list)
    for st in rows(z, "stop_times.txt"):
        if st["trip_id"] in rail_trips:
            stop_seq[st["trip_id"]].append((int(st["stop_sequence"]), st["stop_id"]))

    route_short = {rid: r["route_short_name"] for rid, r in routes.items()}
    patterns = defaultdict(set)
    station_lines = defaultdict(set)
    shapes_by_line = defaultdict(set)
    for trip_id, seq in stop_seq.items():
        trip = rail_trips[trip_id]
        code = route_short[trip["route_id"]]
        codes = tuple(c for _, c in sorted(seq))
        patterns[code].add(codes)
        for c in codes:
            station_lines[c].add(code)
        if trip["shape_id"]:
            shapes_by_line[code].add(trip["shape_id"])

    stops = {s["stop_id"]: s for s in rows(z, "stops.txt") if s["stop_id"] in station_lines}

    wanted = {sid for ids in shapes_by_line.values() for sid in ids}
    raw_shapes = defaultdict(list)
    for p in rows(z, "shapes.txt"):
        if p["shape_id"] in wanted:
            raw_shapes[p["shape_id"]].append(
                (int(p["shape_pt_sequence"]), float(p["shape_pt_lat"]), float(p["shape_pt_lon"]))
            )

    lat0 = 43.7
    line_order = ["LW", "MI", "KI", "BR", "RH", "ST", "LE"]
    lines_out = []
    for rid, r in sorted(routes.items(), key=lambda kv: line_order.index(kv[1]["route_short_name"])
                         if kv[1]["route_short_name"] in line_order else 99):
        code = r["route_short_name"]
        paths = []
        for sid in sorted(shapes_by_line[code]):
            pts = [(la, lo) for _, la, lo in sorted(raw_shapes[sid])]
            if len(pts) >= 2:
                paths.append(simplify(pts, SIMPLIFY_METERS, lat0))
        paths = drop_covered(paths, lat0)
        # Keep only maximal stop patterns (drop ones that are contiguous slices of another).
        pats = sorted({p for p in patterns[code]}, key=len, reverse=True)
        lines_out.append({
            "code": code,
            "apiCode": API_LINE_CODE.get(code, code),
            "name": r["route_long_name"],
            "color": r["route_color"].upper(),
            "paths": [[[round(la, 5), round(lo, 5)] for la, lo in path] for path in paths],
            "patterns": [list(p) for p in pats],
        })

    def clean(name):
        name = name.strip()
        if name == "Union Station GO":
            return "Union Station"
        return name[:-3] if name.endswith(" GO") else name

    stations_out = []
    for sid, s in sorted(stops.items(), key=lambda kv: kv[1]["stop_name"]):
        stations_out.append({
            "code": sid,
            "name": clean(s["stop_name"]),
            "lat": round(float(s["stop_lat"]), 6),
            "lon": round(float(s["stop_lon"]), 6),
            "lines": [c for c in line_order if c in station_lines[sid]],
            "accessible": s.get("wheelchair_boarding", "") == "1",
        })

    feed_version = ""
    try:
        feed_version = next(rows(z, "feed_info.txt")).get("feed_version", "")
    except (KeyError, StopIteration):
        pass

    out = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "feedVersion": feed_version,
        "lines": lines_out,
        "stations": stations_out,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"), ensure_ascii=False)

    n_pts = sum(len(p) for l in lines_out for p in l["paths"])
    print(f"{len(lines_out)} lines, {len(stations_out)} stations, "
          f"{sum(len(l['paths']) for l in lines_out)} paths / {n_pts} points -> {args.output}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
