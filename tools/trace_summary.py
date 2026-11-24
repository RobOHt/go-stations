#!/usr/bin/env python3
"""How the tracked train on the map followed its live reports, from a debug build's trace.

Debug builds launched with -traceTrains YES write Documents/train-trace.tsv: each
second the tracked train is drawn from a live report, how far along its run that
report has it, and how old the report was by then. The train is only ever drawn
where its latest report has it (never where the timetable would, or where it
would be by now), so this says how often it moved to a new position, how old the
reports were while they were shown (how far behind the real train the map can
be), and the longest it went without a new one.

Usage: python3 tools/trace_summary.py train-trace.tsv
"""
import csv
import statistics
import sys


def main(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if len(rows) < 3:
        print(f"{path}: only {len(rows)} rows")
        return
    for row in rows:
        for key in ("time", "target", "target_speed", "drawn", "drawn_speed", "report_age"):
            row[key] = float(row[key])
    span = rows[-1]["time"] - rows[0]["time"]
    print(f"{len(rows)} draws from live reports over {span:.0f} s")
    off = [abs(r["drawn"] - r["target"]) for r in rows]
    print(f"drawn where the report has it: {sum(1 for x in off if x < 0.05)} of {len(rows)} draws"
          + ("" if max(off) < 0.05 else f" (up to {max(off):.1f} m away: it should never be)"))
    ages = [r["report_age"] for r in rows if r["report_age"] >= 0]
    if ages:
        print(f"age of the report shown: min {min(ages):.0f} s, median {statistics.median(ages):.0f} s, "
              f"max {max(ages):.0f} s")
    # Each move to a new position, and how long it stood between them.
    moves, waits, since = [], [], rows[0]["time"]
    for a, b in zip(rows, rows[1:]):
        step = b["drawn"] - a["drawn"]
        if abs(step) > 0.05:
            moves.append(step)
            waits.append(b["time"] - since)
            since = b["time"]
    if moves:
        print(f"moved {len(moves)} times: median step {statistics.median(abs(m) for m in moves):.0f} m, "
              f"longest {max(abs(m) for m in moves):.0f} m; back {sum(1 for m in moves if m < 0)} times; "
              f"between moves: median {statistics.median(waits):.0f} s, longest {max(waits):.0f} s")
    else:
        print("never moved (standing, or no new reports)")
    print("time     along   speed  age  stop")
    t0 = rows[0]["time"]
    for row in rows[::5]:
        speed = "    ?" if row["drawn_speed"] < 0 else f"{row['drawn_speed']:5.1f}"
        print(f"{row['time'] - t0:6.0f} {row['drawn']:7.0f}  {speed} {row['report_age']:4.0f}  {row['stop']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "train-trace.tsv")
