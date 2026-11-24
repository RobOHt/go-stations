#!/usr/bin/env python3
"""How the tracked train on the map was drawn, from a debug build's trace.

Debug builds launched with -traceTrains YES write Documents/train-trace.tsv: each
second the tracked train is drawn, by what ("report": its live reports; "times":
where its times put it, the backup for want of a live position), how far along its
run it's drawn and where its latest report has it, and how old that report and the
list of live trains were by then.

While a train has a live position (GO reported it in the last two minutes, in a
list that came in within the last half minute), only its reports place it: it
glides through them a few seconds behind, carrying on past the latest one until
the next is in, and is put right in one quick slide when a new report shows it
drawn in the wrong place. So this says how often it was drawn each way, that it
never went by its times with a live position to hand, how it moved from second to
second (evenly, or put right: how often and how far, and whether ever back), how
far from its latest report it was drawn, how old the reports were, and how far it
went at once whenever it changed between its times and its reports.

Usage: python3 tools/trace_summary.py train-trace.tsv
"""
import csv
import statistics
import sys

# (As LiveFix.freshFor and LiveContact.inTouchFor in the app.)
FRESH_FOR, IN_TOUCH_FOR = 120, 30
# (As Spot.carriesOn in the app: further than this in a second is being put right.)
GLIDE = 80


def main(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if len(rows) < 3:
        print(f"{path}: only {len(rows)} rows")
        return
    for row in rows:
        for key in ("time", "target", "target_speed", "drawn", "drawn_speed", "report_age"):
            row[key] = float(row[key])
        row["list_age"] = float(row.get("list_age") or -1)
    span = rows[-1]["time"] - rows[0]["time"]
    t0 = rows[0]["time"]
    live = [r for r in rows if r["source"] == "report"]
    timed = [r for r in rows if r["source"] != "report"]
    print(f"{len(rows)} draws over {span:.0f} s: {len(live)} by its live reports, "
          f"{len(timed)} by its times (no live position)")
    # By its times only for want of a live position.
    wrong = [r for r in timed if 0 <= r["report_age"] < FRESH_FOR and 0 <= r["list_age"] < IN_TOUCH_FOR]
    if timed:
        print(f"by its times with a live position to hand: {len(wrong)} of {len(timed)}"
              + ("" if not wrong else " (it should never be)"))
    if live:
        ages = [r["report_age"] for r in live if r["report_age"] >= 0]
        if ages:
            print(f"age of its latest report: min {min(ages):.0f} s, median {statistics.median(ages):.0f} s, "
                  f"max {max(ages):.0f} s")
        lead = [r["drawn"] - r["target"] for r in live]
        print(f"drawn against where its latest report has it: median {statistics.median(lead):+.0f} m, "
              f"from {min(lead):+.0f} m (behind it) to {max(lead):+.0f} m (carried on past it)")
    # Each change between its times and its reports: how far it went at once.
    for a, b in zip(rows, rows[1:]):
        if a["source"] != b["source"]:
            print(f"at {b['time'] - t0:.0f} s: from {a['source']} to {b['source']}, "
                  f"{abs(b['drawn'] - a['drawn']):.0f} m at once")
    # From one second to the next by its reports: evenly, or put right.
    even, back, jumps, still = [], [], [], 0
    for a, b in zip(rows, rows[1:]):
        if a["source"] != "report" or b["source"] != "report" or b["time"] - a["time"] > 2.5:
            continue
        step = b["drawn"] - a["drawn"]
        if step < -0.5:
            back.append(-step)
        elif step > GLIDE:
            jumps.append(step)
        elif step < 0.05:
            still += 1
        else:
            even.append(step / (b["time"] - a["time"]))
    if even or back or jumps:
        print(f"second to second by its reports: moved evenly {len(even)} times"
              + (f" (median {statistics.median(even) * 3.6:.0f} km/h, fastest {max(even) * 3.6:.0f} km/h)" if even else "")
              + f", stood {still} times; put right {len(back) + len(jumps)} times: "
              f"back {len(back)}" + (f" (by {', '.join(f'{b:.0f}' for b in back)} m)" if back else "")
              + f", on {len(jumps)}" + (f" (by {', '.join(f'{j:.0f}' for j in jumps)} m)" if jumps else ""))
    print("time   by      report   drawn  ahead  speed  age  stop")
    for row in rows[::5]:
        speed = "    ?" if row["drawn_speed"] < 0 else f"{row['drawn_speed']:5.1f}"
        print(f"{row['time'] - t0:6.0f} {row['source']:<6} {row['target']:7.0f} {row['drawn']:7.0f} "
              f"{row['drawn'] - row['target']:+6.0f}  {speed} {row['report_age']:4.0f}  {row['stop']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "train-trace.tsv")
