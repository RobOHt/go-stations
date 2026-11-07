#!/usr/bin/env python3
"""Print the shape of Metrolinx's live train feeds, and how often they change.

For working on the app's live train positions and stop times: what each feed
returns right now, a few sample entries, and how many trains moved between
polls. Run by .github/workflows/probe.yml (workflow_dispatch), which has the
key; it needs METROLINX_API_KEY in the environment and never prints it.

Usage:
    METROLINX_API_KEY=... python3 tools/probe_live.py [--polls 4] [--gap 15]
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

UPSTREAM = "https://api.openmetrolinx.com/OpenDataAPI/api/V1"
TORONTO = ZoneInfo("America/Toronto")
KEY = os.environ.get("METROLINX_API_KEY", "").strip()


def get(path):
    """(status, seconds, parsed JSON or None, text length) for one API path."""
    if not KEY:
        raise SystemExit("METROLINX_API_KEY is not set")
    started = time.time()
    request = Request(f"{UPSTREAM}{path}?key={KEY}", headers={"Accept": "application/json"})
    try:
        with urlopen(request, timeout=30) as response:
            status, text = response.status, response.read().decode("utf-8", "replace")
    except HTTPError as error:
        status, text = error.code, error.read().decode("utf-8", "replace")
    except URLError as error:
        return f"failed ({error.reason})", time.time() - started, None, 0
    try:
        body = json.loads(text)
    except ValueError:
        body = None
    return status, time.time() - started, body, len(text)


def shape(value, depth=0, limit=5):
    """A skeleton of a JSON value: keys with types, arrays by length and first item."""
    pad = "  " * depth
    if isinstance(value, dict):
        lines = []
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                size = f" [{len(item)}]" if isinstance(item, list) else ""
                lines.append(f"{pad}{key}{size}:")
                if depth < limit:
                    lines.extend(shape(item, depth + 1, limit))
            else:
                lines.append(f"{pad}{key}: {json.dumps(item)[:60]}")
        return lines
    if isinstance(value, list):
        return shape(value[0], depth, limit) if value else [f"{pad}(empty)"]
    return [f"{pad}{json.dumps(value)[:60]}"]


def section(title):
    print(f"\n===== {title} =====", flush=True)


def report(path, body, status, seconds, size):
    print(f"{path}: HTTP {status}, {size} bytes, {seconds:.1f} s")
    if isinstance(body, dict) and isinstance(body.get("Metadata"), dict):
        print("Metadata:", json.dumps(body["Metadata"]))


def find_list(body, *names):
    """The first list under any of the nested key paths in `names`."""
    for name in names:
        node = body
        for key in name.split("."):
            node = node.get(key) if isinstance(node, dict) else None
        if isinstance(node, list):
            return node
    return []


def trains_all(polls, gap):
    section("ServiceataGlance/Trains/All")
    path = "/ServiceataGlance/Trains/All"
    snapshots = []
    for poll in range(polls):
        status, seconds, body, size = get(path)
        if poll == 0:
            report(path, body, status, seconds, size)
            if isinstance(body, dict):
                print("\n".join(shape(body)))
        trips = find_list(body or {}, "Trips.Trip", "Trips")
        snapshots.append((time.time(), {str(t.get("TripNumber")): t for t in trips if isinstance(t, dict)}))
        if poll + 1 < polls:
            time.sleep(gap)
    first = snapshots[0][1]
    print(f"\n{len(first)} trains. First three in full:")
    for trip in list(first.values())[:3]:
        print(json.dumps(trip, indent=1))
    now = datetime.now(TORONTO)
    ages = []
    for trip in first.values():
        stamp = trip.get("ModifiedDate")
        try:
            when = datetime.fromisoformat(str(stamp)).replace(tzinfo=TORONTO)
            ages.append((now - when).total_seconds())
        except ValueError:
            pass
    if ages:
        ages.sort()
        print(f"ModifiedDate age (s): min {ages[0]:.0f}, median {ages[len(ages) // 2]:.0f}, max {ages[-1]:.0f}")
    fields = ["Latitude", "Longitude", "IsInMotion", "AtStationCode", "PrevStopCode", "NextStopCode",
              "DelaySeconds", "Course", "ModifiedDate"]
    for index in range(1, len(snapshots)):
        before, after = snapshots[index - 1][1], snapshots[index][1]
        moved = sum(1 for k, t in after.items() if k in before and
                    (t.get("Latitude"), t.get("Longitude")) != (before[k].get("Latitude"), before[k].get("Longitude")))
        changed = {f: sum(1 for k, t in after.items() if k in before and t.get(f) != before[k].get(f)) for f in fields}
        span = snapshots[index][0] - snapshots[index - 1][0]
        print(f"poll {index} (+{span:.0f} s): {moved}/{len(after)} moved; changed: {json.dumps(changed)}")
    # One train over all polls.
    for key in list(first)[:2]:
        print(f"train {key} over the polls:")
        for stamp, trips in snapshots:
            t = trips.get(key, {})
            print("  ", datetime.fromtimestamp(stamp, TORONTO).strftime("%H:%M:%S"),
                  {f: t.get(f) for f in fields})
    return first


def gtfs(name, polls, gap):
    section(f"Gtfs/Feed/{name}")
    path = f"/Gtfs/Feed/{name}"
    snapshots = []
    for poll in range(polls):
        status, seconds, body, size = get(path)
        if poll == 0:
            report(path, body, status, seconds, size)
            if isinstance(body, dict):
                print("\n".join(shape(body, limit=6)))
        entities = find_list(body or {}, "entity", "Entity")
        snapshots.append((time.time(), body, entities))
        if poll + 1 < polls:
            time.sleep(gap)
    body, entities = snapshots[0][1], snapshots[0][2]
    if isinstance(body, dict):
        print("header:", json.dumps(body.get("header") or body.get("Header")))
    print(f"{len(entities)} entities. First two in full (long lists cut to 3 + last 2):")
    for entity in entities[:2]:
        entity = json.loads(json.dumps(entity))
        update = entity.get("trip_update") or entity.get("TripUpdate") or {}
        for key in ("stop_time_update", "StopTimeUpdate"):
            if isinstance(update.get(key), list) and len(update[key]) > 5:
                update[key] = update[key][:3] + ["..."] + update[key][-2:]
        print(json.dumps(entity, indent=1)[:4000])
    ids = [str((((e.get("vehicle") or e.get("trip_update") or {}).get("trip") or {}).get("trip_id"))) for e in entities]
    print("trip_ids (first 12):", ids[:12])
    for index in range(1, len(snapshots)):
        def stamps(entities):
            out = {}
            for e in entities:
                part = e.get("vehicle") or e.get("trip_update") or {}
                out[e.get("id")] = (part.get("timestamp"), json.dumps(part.get("position")))
            return out
        before, after = stamps(snapshots[index - 1][2]), stamps(snapshots[index][2])
        changed = sum(1 for k, v in after.items() if k in before and v != before[k])
        span = snapshots[index][0] - snapshots[index - 1][0]
        print(f"poll {index} (+{span:.0f} s): {changed}/{len(after)} entities changed")
    now = time.time()
    ages = []
    for e in entities:
        part = e.get("vehicle") or e.get("trip_update") or {}
        try:
            ages.append(now - float(part.get("timestamp")))
        except (TypeError, ValueError):
            pass
    if ages:
        ages.sort()
        print(f"timestamp age (s): min {ages[0]:.0f}, median {ages[len(ages) // 2]:.0f}, max {ages[-1]:.0f}")
    return entities


def schedule_trip(numbers):
    section("Schedule/Trip (computed arrival and departure)")
    day = datetime.now(TORONTO).strftime("%Y%m%d")
    for number in numbers:
        path = f"/Schedule/Trip/{day}/{number}"
        status, seconds, body, size = get(path)
        report(f"/Schedule/Trip/{day}/<{number}>", body, status, seconds, size)
        if not isinstance(body, dict):
            continue
        print("\n".join(shape(body, limit=6)))
        trips = find_list(body, "Trips", "Trips.Trip")
        for trip in trips[:1]:
            print({k: v for k, v in trip.items() if not isinstance(v, (list, dict))})
            for stop in (trip.get("Stops") or [])[:40]:
                print("  ", json.dumps(stop))


def others():
    section("Other paths (status only)")
    for path in ["/ServiceataGlance/UPX/All", "/Gtfs/Feed/Alerts", "/Fleet/Consist/All"]:
        status, seconds, body, size = get(path)
        report(path, body, status, seconds, size)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--polls", type=int, default=4)
    parser.add_argument("--gap", type=float, default=15)
    args = parser.parse_args()
    print("Now:", datetime.now(TORONTO).isoformat(timespec="seconds"))
    trains = trains_all(args.polls, args.gap)
    gtfs("VehiclePosition", args.polls, args.gap)
    gtfs("TripUpdates", 2, args.gap)
    moving = [k for k, t in trains.items() if str(t.get("IsInMotion")).lower() in ("true", "1")]
    standing = [k for k, t in trains.items() if t.get("AtStationCode")]
    schedule_trip((moving[:1] + standing[:1]) or list(trains)[:2])
    others()


if __name__ == "__main__":
    sys.exit(main())
