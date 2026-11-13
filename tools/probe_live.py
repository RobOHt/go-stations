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


TRAIN_LINES = {"LW", "LE", "KI", "MI", "BR", "RH", "ST", "GT", "UP"}


def is_train(entity):
    part = entity.get("vehicle") or entity.get("trip_update") or {}
    trip_id = str((part.get("trip") or {}).get("trip_id") or "")
    pieces = trip_id.split("-")
    return len(pieces) >= 3 and pieces[1] in TRAIN_LINES


def number_of(entity):
    part = entity.get("vehicle") or entity.get("trip_update") or {}
    return str((part.get("trip") or {}).get("trip_id") or "").rsplit("-", 1)[-1]


def timeline(polls, gap):
    """Trains only: Trains/All next to GTFS VehiclePosition, poll by poll, and how
    GTFS TripUpdates' stop times for one train change."""
    section(f"Train timeline: {polls} polls, {gap:.0f} s apart")
    history = []
    updates = []
    for poll in range(polls):
        stamp = time.time()
        _, _, glance, _ = get("/ServiceataGlance/Trains/All")
        _, _, vehicles, _ = get("/Gtfs/Feed/VehiclePosition")
        trips = {str(t.get("TripNumber")): t for t in find_list(glance or {}, "Trips.Trip") if isinstance(t, dict)}
        entities = find_list(vehicles or {}, "entity")
        trains = {number_of(e): e for e in entities if is_train(e) or number_of(e) in trips}
        history.append((stamp, trips, trains))
        if poll in (0, polls // 2, polls - 1):
            _, _, feed, _ = get("/Gtfs/Feed/TripUpdates")
            updates.append((stamp, {number_of(e): e for e in find_list(feed or {}, "entity")
                                    if is_train(e) or number_of(e) in trips}))
        if poll == 0:
            print(f"Trains/All: {len(trips)} trains; VehiclePosition: {len(trains)} trains "
                  f"of {len(find_list(vehicles or {}, 'entity'))} vehicles")
            kinds = {}
            for e in entities:
                part = e.get("vehicle") or {}
                trip_id = str((part.get("trip") or {}).get("trip_id") or "")
                kinds.setdefault(trip_id.split("-")[1] if trip_id.count("-") >= 2 else trip_id[:12], trip_id)
            print("trip_id kinds (middle part: example):", json.dumps(dict(sorted(kinds.items())[:60])))
            both = sorted(set(trips) & set(trains))
            print("in both:", len(both), "only Trains/All:", sorted(set(trips) - set(trains))[:10],
                  "only VehiclePosition:", sorted(set(trains) - set(trips))[:10])
            for key in both[:2]:
                print(json.dumps(trains[key], indent=1)[:2500])
        if poll + 1 < polls:
            time.sleep(gap)

    # How often each feed changes, per train.
    changes = {"glance": [], "vehicle": []}
    for key in history[0][1]:
        last_g = last_v = None
        count_g = count_v = 0
        for _, trips, trains in history:
            g = trips.get(key, {}).get("ModifiedDate")
            v = ((trains.get(key) or {}).get("vehicle") or {}).get("timestamp")
            if last_g is not None and g != last_g:
                count_g += 1
            if last_v is not None and v != last_v:
                count_v += 1
            last_g, last_v = g, v
        changes["glance"].append(count_g)
        changes["vehicle"].append(count_v)
    span = history[-1][0] - history[0][0]
    for name, counts in changes.items():
        if counts:
            print(f"{name}: changes per train over {span:.0f} s: {sorted(counts)}")

    picks = [k for k in history[0][1] if str(history[0][1][k].get("IsInMotion")).lower() == "true"][:3]
    picks += [k for k in history[0][1] if history[0][1][k].get("AtStationCode")][:1]
    for key in picks:
        print(f"\ntrain {key} ({history[0][1][key].get('Display')}):")
        for stamp, trips, trains in history:
            g = trips.get(key, {})
            v = (trains.get(key) or {}).get("vehicle") or {}
            pos = v.get("position") or {}
            print("  ", datetime.fromtimestamp(stamp, TORONTO).strftime("%H:%M:%S"),
                  "| glance", g.get("ModifiedDate", "")[11:], g.get("Latitude"), g.get("Longitude"),
                  "moving" if g.get("IsInMotion") else "still", "at", g.get("AtStationCode"),
                  g.get("PrevStopCode"), "->", g.get("NextStopCode"), "delay", g.get("DelaySeconds"),
                  "| gtfs", datetime.fromtimestamp(v["timestamp"], TORONTO).strftime("%H:%M:%S") if v.get("timestamp") else None,
                  pos.get("latitude"), pos.get("longitude"), "brg", pos.get("bearing"), "spd", pos.get("speed"),
                  v.get("current_status"), v.get("stop_id"))
        for stamp, feed in updates:
            entity = feed.get(key)
            if not entity:
                print("   TripUpdates", datetime.fromtimestamp(stamp, TORONTO).strftime("%H:%M:%S"), "missing")
                continue
            update = entity.get("trip_update") or {}
            print("   TripUpdates", datetime.fromtimestamp(stamp, TORONTO).strftime("%H:%M:%S"),
                  "timestamp", update.get("timestamp"), "delay", update.get("delay"))
            for stop in update.get("stop_time_update") or []:
                def fmt(event):
                    if not event:
                        return "-"
                    when = event.get("time")
                    clock = datetime.fromtimestamp(when, TORONTO).strftime("%H:%M:%S") if when else "?"
                    return f"{clock} ({event.get('delay')})"
                print("     ", stop.get("stop_sequence"), stop.get("stop_id"), "arr", fmt(stop.get("arrival")),
                      "dep", fmt(stop.get("departure")), stop.get("schedule_relationship"))


NETWORK = os.path.join(os.path.dirname(__file__), "..", "Departures", "Resources", "network.json")
WORKER = "https://go-stations.robinzhongsh2.workers.dev/v1/live/trains"


def metres(lat1, lon1, lat2, lon2):
    """Distance between two points, in metres."""
    from math import asin, cos, radians, sin, sqrt
    dlat, dlon = radians(lat2 - lat1), radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 2 * 6371000 * asin(sqrt(a))


def worker_trains():
    """The Worker's /v1/live/trains (what the app gets), by trip number, or {}."""
    request = Request(WORKER, headers={"Accept": "application/json", "User-Agent": "go-stations-probe"})
    try:
        with urlopen(request, timeout=20) as response:
            return {t["trip"]: t for t in json.loads(response.read()).get("trains", [])}
    except Exception:  # noqa: BLE001 - report as nothing and carry on
        return {}


def approach(code, polls, gap):
    """Trains coming into one station (e.g. UN), poll by poll, as both feeds and the
    Worker (what the app gets) have them: the stop each says it's at or on its way
    to, how late, how far out, and how old the report is. Then, for each train that
    got in while polling, when it was first reported standing there (and how late
    then), its timetabled time there, and the longest gap between its reports."""
    stations = {s["code"]: s for s in json.load(open(NETWORK))["stations"]}
    target = stations[code]
    section(f"Trains into {target['name']} ({code}): {polls} polls, {gap:.0f} s apart")
    rows = {}  # trip number -> [(clock, distance, glance, vehicle, app)]
    due = {}  # trip number -> (arrival time, delay) at the station, by TripUpdates
    odd = {}  # stop codes reported near the station that aren't stations
    for poll in range(polls):
        started = time.time()
        _, _, glance, _ = get("/ServiceataGlance/Trains/All")
        _, _, vehicles, _ = get("/Gtfs/Feed/VehiclePosition")
        app = worker_trains()
        if poll % 4 == 0:
            _, _, feed, _ = get("/Gtfs/Feed/TripUpdates")
            for entity in find_list(feed or {}, "entity"):
                for stop in (entity.get("trip_update") or {}).get("stop_time_update") or []:
                    if stop.get("stop_id") == code and (stop.get("arrival") or {}).get("time"):
                        due[number_of(entity)] = (stop["arrival"]["time"], stop["arrival"].get("delay"))
        trips = {str(t.get("TripNumber")): t for t in find_list(glance or {}, "Trips.Trip") if isinstance(t, dict)}
        trains = {number_of(e): e for e in find_list(vehicles or {}, "entity") if is_train(e) or number_of(e) in trips}
        clock = datetime.now(TORONTO).strftime("%H:%M:%S")
        for number in set(trips) | set(trains):
            g = trips.get(number, {})
            v = (trains.get(number) or {}).get("vehicle") or {}
            position = v.get("position") or {}
            lat = position.get("latitude") or g.get("Latitude")
            lon = position.get("longitude") or g.get("Longitude")
            if lat is None or lon is None:
                continue
            distance = metres(lat, lon, target["lat"], target["lon"])
            if distance > 8000:
                continue
            stop = v.get("stop_id")
            if stop and stop not in stations and distance < 4000:
                odd[stop] = odd.get(stop, 0) + 1
            rows.setdefault(number, []).append((clock, started, distance, g, v, app.get(number) or {}))
        if poll + 1 < polls:
            time.sleep(max(0, gap - (time.time() - started)))

    print("stop codes reported within 4 km that aren't stations:", json.dumps(odd) if odd else "none")
    came_in = [n for n, r in rows.items() if r[0][2] > 1200 and min(x[2] for x in r) < 400]
    print(f"trains seen within 8 km: {len(rows)}; came in while polling: {came_in}")
    for number in came_in:
        print(f"\ntrain {number} ({rows[number][0][3].get('Display') or rows[number][0][3].get('LineCode')}):")
        last = None
        stamps = []
        for clock, started, distance, g, v, a in rows[number]:
            stamp = v.get("timestamp")
            if stamp:
                stamps.append(stamp)
            line = (f"{distance:6.0f} m | glance {g.get('ModifiedDate', '')[11:]} at {g.get('AtStationCode')} "
                    f"{g.get('PrevStopCode')}->{g.get('NextStopCode')} delay {g.get('DelaySeconds')} "
                    f"{'moving' if g.get('IsInMotion') else 'still'} | gtfs "
                    f"{datetime.fromtimestamp(stamp, TORONTO).strftime('%H:%M:%S') if stamp else '-'} "
                    f"{v.get('current_status')} {v.get('stop_id')} | app {a.get('status')} {a.get('stop')} "
                    f"delay {a.get('delay')} age {started - a['time']:.0f}s" if a.get("time") else
                    f"{distance:6.0f} m | glance {g.get('ModifiedDate', '')[11:]} at {g.get('AtStationCode')} "
                    f"{g.get('PrevStopCode')}->{g.get('NextStopCode')} delay {g.get('DelaySeconds')} | gtfs "
                    f"{datetime.fromtimestamp(stamp, TORONTO).strftime('%H:%M:%S') if stamp else '-'} "
                    f"{v.get('current_status')} {v.get('stop_id')} | app: none")
            if line != last:
                print("  ", clock, line)
            last = line
        gaps = [b - a for a, b in zip(stamps, stamps[1:]) if b != a]
        standing = next((x for x in rows[number] if (x[4].get("current_status") == "STOPPED_AT"
                                                      and x[4].get("stop_id") == code)
                         or x[3].get("AtStationCode") == code), None)
        arrival = due.get(number)
        print("   timetabled here:",
              datetime.fromtimestamp(arrival[0] - (arrival[1] or 0), TORONTO).strftime("%H:%M:%S") if arrival else "?",
              "| TripUpdates expected:",
              datetime.fromtimestamp(arrival[0], TORONTO).strftime("%H:%M:%S") if arrival else "?",
              f"({arrival[1]} s)" if arrival else "",
              "| first reported standing here:", standing[0] if standing else "never",
              f"delay then {standing[3].get('DelaySeconds')}" if standing else "",
              "| longest gap between GTFS reports:", f"{max(gaps):.0f} s" if gaps else "-")


def worker(polls, gap):
    """The app's view: the Worker's /v1/live/trains, poll by poll, with the cache's
    headers, and whether each train's report moved on."""
    section(f"Worker /v1/live/trains: {polls} polls, {gap:.0f} s apart")
    url = WORKER
    before = {}
    for poll in range(polls):
        started = time.time()
        request = Request(url, headers={"Accept": "application/json", "User-Agent": "go-stations-probe"})
        try:
            with urlopen(request, timeout=20) as response:
                headers = {k.lower(): v for k, v in response.headers.items()}
                body = json.loads(response.read())
        except Exception as error:  # report and carry on
            print(f"{datetime.now(TORONTO).strftime('%H:%M:%S')} failed: {error}")
            time.sleep(gap)
            continue
        trains = {t["trip"]: t for t in body.get("trains", [])}
        now = time.time()
        ages = sorted(now - t["time"] for t in trains.values())
        moved = sum(1 for k, t in trains.items() if k in before and t["time"] != before[k]["time"])
        print(f"{datetime.now(TORONTO).strftime('%H:%M:%S')} {time.time() - started:.1f}s "
              f"cache {headers.get('cf-cache-status', '-')} age {headers.get('age', '-')} "
              f"cache-control {headers.get('cache-control', '-')} at {now - body.get('at', 0):.0f}s ago; "
              f"{len(trains)} trains, newer report than last poll for {moved}; report ages "
              f"min {ages[0]:.0f} median {ages[len(ages) // 2]:.0f} max {ages[-1]:.0f}" if ages else "no trains")
        before = trains
        time.sleep(max(0, gap - (time.time() - started)))


def truthy(value):
    return str(value).strip().lower() in ("true", "1", "yes", "y")


def cancellations(station):
    """How a cancelled train shows in each feed: the exceptions feed (what the
    app reads), GTFS TripUpdates, Trains/All, the service alerts, and, given a
    station, its NextService lines for those trains."""
    section("ServiceUpdate/Exceptions/Train")
    status, seconds, body, size = get("/ServiceUpdate/Exceptions/Train")
    report("/ServiceUpdate/Exceptions/Train", body, status, seconds, size)
    trips = find_list(body or {}, "Trip", "Trips.Trip", "Exceptions.Trip")
    print(f"{len(trips)} trips")
    numbers = set()
    for trip in trips:
        stops = trip.get("Stop") or trip.get("Stops") or []
        if isinstance(stops, dict):
            stops = [stops]
        cancelled = [stop.get("Code") for stop in stops if isinstance(stop, dict) and truthy(stop.get("IsCancelled"))]
        flat = {k: v for k, v in trip.items() if not isinstance(v, (list, dict))}
        numbers.add(str(trip.get("TripNumber") or "").strip())
        print(flat, f"| {len(stops)} stops, cancelled at {len(cancelled)}: {cancelled[:8]}")
    if trips:
        print("Shape of the first:")
        for line in shape(trips[0], limit=3):
            print("  " + line)

    section("GTFS TripUpdates: trains not running as scheduled")
    status, seconds, body, size = get("/Gtfs/Feed/TripUpdates")
    report("/Gtfs/Feed/TripUpdates", body, status, seconds, size)
    shown = 0
    for entity in find_list(body or {}, "entity"):
        if not is_train(entity):
            continue
        update = entity.get("trip_update") or {}
        relation = (update.get("trip") or {}).get("schedule_relationship")
        skipped = [stop.get("stop_id") for stop in update.get("stop_time_update") or []
                   if stop.get("schedule_relationship") not in (None, "SCHEDULED", 0)]
        if relation not in (None, "SCHEDULED", 0) or skipped:
            shown += 1
            print(json.dumps(update.get("trip")), f"| skipped {len(skipped)}: {skipped[:8]}")
    print(f"{shown} shown")

    section("Trains/All entries for the exceptions' trains")
    _, _, glance, _ = get("/ServiceataGlance/Trains/All")
    for train in find_list(glance or {}, "Trips.Trip"):
        if str(train.get("TripNumber") or "").strip() in numbers:
            print({k: v for k, v in train.items() if not isinstance(v, (list, dict))})

    section("Service alerts naming trains")
    _, _, alerts, _ = get("/ServiceUpdate/ServiceAlert/All")
    for message in find_list(alerts or {}, "Messages.Message"):
        trips = message.get("Trips") or []
        if trips:
            refs = [t.get("TripNumber") for t in trips if isinstance(t, dict)]
            print(message.get("SubjectEnglish"), "|", refs[:8])

    if station:
        section(f"Stop/NextService/{station}: every field of each line")
        status, seconds, body, size = get(f"/Stop/NextService/{station}")
        report(f"/Stop/NextService/{station}", body, status, seconds, size)
        for line in find_list(body or {}, "NextService.Lines"):
            print(json.dumps(line))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--polls", type=int, default=4)
    parser.add_argument("--gap", type=float, default=15)
    parser.add_argument("--timeline", action="store_true", help="trains only, side by side over time")
    parser.add_argument("--worker", action="store_true", help="the Worker's /v1/live/trains, as the app sees it")
    parser.add_argument("--trip", help="DAY/NUMBER: one trip's Schedule/Trip stops, in the order Metrolinx gives them")
    parser.add_argument("--approach", help="STATION: trains coming into it (e.g. UN), as the feeds and the Worker have them")
    parser.add_argument("--cancellations", action="store_true",
                        help="how cancelled trains show in each feed (with --station, its NextService too)")
    parser.add_argument("--station", help="with --cancellations: a station's NextService lines")
    args = parser.parse_args()
    print("Now:", datetime.now(TORONTO).isoformat(timespec="seconds"))
    if args.cancellations:
        cancellations(args.station)
        return
    if args.worker:
        worker(args.polls, args.gap)
        return
    if args.approach:
        approach(args.approach, args.polls, args.gap)
        return
    if args.trip:
        status, seconds, body, size = get(f"/Schedule/Trip/{args.trip}")
        report(f"/Schedule/Trip/{args.trip}", body, status, seconds, size)
        for trip in find_list(body or {}, "Trips"):
            print({k: v for k, v in trip.items() if not isinstance(v, (list, dict))})
            for stop in trip.get("Stops") or []:
                print("  ", json.dumps(stop))
        return
    if args.timeline:
        timeline(args.polls, args.gap)
        return
    trains = trains_all(args.polls, args.gap)
    gtfs("VehiclePosition", args.polls, args.gap)
    gtfs("TripUpdates", 2, args.gap)
    moving = [k for k, t in trains.items() if str(t.get("IsInMotion")).lower() in ("true", "1")]
    standing = [k for k, t in trains.items() if t.get("AtStationCode")]
    schedule_trip((moving[:1] + standing[:1]) or list(trains)[:2])
    others()


if __name__ == "__main__":
    sys.exit(main())
