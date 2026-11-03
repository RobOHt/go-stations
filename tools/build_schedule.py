#!/usr/bin/env python3
"""Build schedule.json: the next couple of weeks of GO train departures, from GTFS.

The app uses it when live data is unavailable (no API key yet, Metrolinx or the
proxy down). It is published daily by .github/workflows/schedule.yml and bundled
into every app build.

Usage:
    python3 tools/build_schedule.py                       # official feed, 14 days from today
    python3 tools/build_schedule.py --input GO-GTFS.zip --start 20261020 --days 7
    python3 tools/build_schedule.py --output Departures/Resources/schedule.json

Format (version 1):
    patterns  stop-code sequences, shared by trips
    trips     [tripNumber, lineCode, patternIndex, [minutes after service-day midnight per stop]]
              times can pass 1440 for trips that run past midnight (GTFS convention)
    days      {"yyyyMMdd": [trip indices running that service day]}

Data: Metrolinx GTFS, Open Government Licence – Ontario.
"""
import argparse
import csv
import io
import json
import sys
import zipfile
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

SOURCES = [
    "https://assets.metrolinx.com/raw/upload/Documents/Metrolinx/Open%20Data/GO-GTFS.zip",
    "https://files.mobilitydatabase.org/mdb-1993/latest.zip",
]
TORONTO = ZoneInfo("America/Toronto")


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="GTFS zip path or URL (default: official feed, then a mirror)")
    ap.add_argument("--output", default="schedule.json")
    ap.add_argument("--start", help="first service day, yyyyMMdd (default: today in Toronto)")
    ap.add_argument("--days", type=int, default=14)
    return ap.parse_args()


def download(url):
    request = Request(url, headers={"User-Agent": "go-stations-schedule/1.0"})
    with urlopen(request, timeout=300) as response:
        return response.read()


def open_feed(src):
    if src and not src.startswith("http"):
        return zipfile.ZipFile(src)
    errors = []
    for url in [src] if src else SOURCES:
        try:
            print("Downloading", url, file=sys.stderr)
            return zipfile.ZipFile(io.BytesIO(download(url)))
        except Exception as error:  # try the next source
            errors.append(f"{url}: {error}")
    raise SystemExit("Could not download GTFS:\n  " + "\n  ".join(errors))


def rows(z, name):
    if name not in z.namelist():
        return
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))


def to_minutes(hms):
    hours, minutes, *_ = hms.strip().split(":")
    return int(hours) * 60 + int(minutes)


def service_dates(z, window):
    """service_id -> set of yyyyMMdd within the window, from calendar.txt + calendar_dates.txt."""
    wanted = set(window)
    dates = defaultdict(set)
    weekday_keys = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    for row in rows(z, "calendar.txt"):
        start = datetime.strptime(row["start_date"], "%Y%m%d").date()
        end = datetime.strptime(row["end_date"], "%Y%m%d").date()
        for key in window:
            day = datetime.strptime(key, "%Y%m%d").date()
            if start <= day <= end and row.get(weekday_keys[day.weekday()]) == "1":
                dates[row["service_id"]].add(key)
    for row in rows(z, "calendar_dates.txt"):
        key = row["date"]
        if key not in wanted:
            continue
        if row["exception_type"] == "1":
            dates[row["service_id"]].add(key)
        elif row["exception_type"] == "2":
            dates[row["service_id"]].discard(key)
    return dates


def trip_number(trip):
    short = (trip.get("trip_short_name") or "").strip()
    if short:
        return short
    return trip["trip_id"].rsplit("-", 1)[-1]


def main():
    args = parse_args()
    start = (datetime.strptime(args.start, "%Y%m%d").date() if args.start
             else datetime.now(TORONTO).date())
    window = [(start + timedelta(days=i)).strftime("%Y%m%d") for i in range(args.days)]

    z = open_feed(args.input)

    routes = {r["route_id"]: r["route_short_name"] for r in rows(z, "routes.txt") if r["route_type"] == "2"}
    dates_by_service = service_dates(z, window)
    trips = {}
    for t in rows(z, "trips.txt"):
        if t["route_id"] in routes and dates_by_service.get(t["service_id"]):
            trips[t["trip_id"]] = t

    stop_times = defaultdict(list)
    for st in rows(z, "stop_times.txt"):
        if st["trip_id"] in trips:
            time = st["departure_time"] or st["arrival_time"]
            if time:
                stop_times[st["trip_id"]].append((int(st["stop_sequence"]), st["stop_id"], to_minutes(time)))

    patterns, pattern_index = [], {}
    templates, template_index = [], {}
    days = defaultdict(list)

    for trip_id, trip in trips.items():
        ordered = sorted(stop_times.get(trip_id, []))
        if len(ordered) < 2:
            continue
        codes = tuple(code for _, code, _ in ordered)
        times = tuple(minutes for _, _, minutes in ordered)
        if codes not in pattern_index:
            pattern_index[codes] = len(patterns)
            patterns.append(list(codes))
        key = (trip_number(trip), routes[trip["route_id"]], pattern_index[codes], times)
        if key not in template_index:
            template_index[key] = len(templates)
            templates.append([key[0], key[1], key[2], list(times)])
        for day in dates_by_service[trip["service_id"]]:
            days[day].append(template_index[key])

    feed_version = ""
    for row in rows(z, "feed_info.txt"):
        feed_version = row.get("feed_version", "")
        break

    out = {
        "version": 1,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "feedVersion": feed_version,
        "startDate": window[0],
        "patterns": patterns,
        "trips": templates,
        "days": {day: sorted(set(indices)) for day, indices in sorted(days.items())},
    }
    if not out["days"]:
        raise SystemExit("No rail trips in the window; is the feed current?")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))

    per_day = {day: len(v) for day, v in out["days"].items()}
    print(f"{len(templates)} trips, {len(patterns)} stop patterns, {len(per_day)} days "
          f"({min(per_day.values())}-{max(per_day.values())} trips/day) -> {args.output}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
