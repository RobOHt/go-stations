#!/usr/bin/env python3
"""How smoothly the tracked train moved on the map, from a debug build's trace.

Debug builds launched with -traceTrains YES write Documents/train-trace.tsv: each
time the tracked train is drawn (about every second), where it should be along its
run (the replay of its live reports, or its times) and where it's drawn. This says
how often it was replayed rather than placed by its times, how hard the drawing
sped up or slowed down, whether it ever went back, and how far it was from where
it should be.

Usage: python3 tools/trace_summary.py train-trace.tsv
"""
import csv
import statistics
import sys

REPLAY_DELAY = 30


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
    replayed = [r for r in rows if r["source"] == "replay"]
    print(f"{len(rows)} draws over {span:.0f} s; replayed from live reports: {len(replayed)}, "
          f"from its times: {len(rows) - len(replayed)}")
    ages = [r["report_age"] for r in rows if r["report_age"] >= 0]
    if ages:
        ahead = sum(1 for a in ages if a > REPLAY_DELAY)
        print(f"newest report age: min {min(ages):.0f} s, median {statistics.median(ages):.0f} s, max {max(ages):.0f} s; "
              f"past the newest report (guessing ahead) in {ahead} of {len(ages)} draws")
    # Second by second.
    accelerations, backwards, steps = [], 0, []
    for a, b in zip(rows, rows[1:]):
        dt = b["time"] - a["time"]
        if dt <= 0 or dt > 3:
            continue
        step = b["drawn"] - a["drawn"]
        steps.append(step / dt)
        if step < -0.05:
            backwards += 1
        accelerations.append(abs(b["drawn_speed"] - a["drawn_speed"]) / dt)
    if accelerations:
        hard = sum(1 for x in accelerations if x > 1.6)
        print(f"drawn speed: max {max(r['drawn_speed'] for r in rows):.1f} m/s; speed change: max "
              f"{max(accelerations):.2f} m/s per s, over 1.6 in {hard} of {len(accelerations)}; went back {backwards} times")
    gaps = [abs(r["drawn"] - r["target"]) for r in replayed]
    if gaps:
        print(f"drawn vs replay: median {statistics.median(gaps):.1f} m, max {max(gaps):.1f} m")
    print("time     source  target   drawn  speed  age  stop")
    t0 = rows[0]["time"]
    for row in rows[::5]:
        print(f"{row['time'] - t0:6.0f}  {row['source']:6} {row['target']:7.0f} {row['drawn']:7.0f} "
              f"{row['drawn_speed']:6.1f} {row['report_age']:4.0f}  {row['stop']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "train-trace.tsv")
