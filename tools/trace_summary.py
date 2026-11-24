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
far from its latest report it was drawn, how old the reports were, how far it went
at once whenever it changed between its times and its reports, and each time its
reports had it standing: that it was drawn where they had it, never carried on.

With --openings, for traces each taken from the moment the app opened: how
many positions the train had to go by at its first frame, how old the newest
was, how long it stood there before it moved, and how far it then jumped.

Usage: python3 tools/trace_summary.py train-trace.tsv
       python3 tools/trace_summary.py --openings train-opening-*.tsv
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
    # While its reports have it standing (its speed by them is 0): drawn where
    # they have it, or still coming up to there, never carried on past it.
    stands, current = [], []
    for row in rows:
        if row["source"] == "report" and row["drawn_speed"] == 0:
            current.append(row)
        elif current:
            stands.append(current)
            current = []
    if current:
        stands.append(current)
    for stand in stands:
        lead = [r["drawn"] - r["target"] for r in stand]
        print(f"at {stand[0]['time'] - t0:.0f} s: standing by its reports for {stand[-1]['time'] - stand[0]['time']:.0f} s "
              f"({stand[0]['stop']}): drawn at most {max(max(lead), 0):.0f} m past where they had it, "
              f"at most {max(-min(lead), 0):.0f} m short of it")
    # From one second to the next by its reports: evenly, or put right. (The map
    # also draws the moment a new list of trains is in: a draw less than half a
    # second before the next goes with it.)
    paced = [row for row, after in zip(rows, rows[1:] + [None])
             if after is None or after["time"] - row["time"] >= 0.5]
    even, back, jumps, still = [], [], [], 0
    for a, b in zip(paced, paced[1:]):
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


def openings(paths):
    stood_all, jumps_all = [], []
    for path in paths:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f, delimiter="\t"))
        rows = [r for r in rows if r["source"] == "report"]
        if len(rows) < 3:
            print(f"{path}: only {len(rows)} draws by live reports")
            continue
        t0, first = float(rows[0]["time"]), float(rows[0]["drawn"])
        moved = next((float(r["time"]) - t0 for r in rows if abs(float(r["drawn"]) - first) > 1), None)
        # Draws less than half a second apart go together (see main()).
        paced = [r for r, after in zip(rows, rows[1:] + [None])
                 if after is None or float(after["time"]) - float(r["time"]) >= 0.5]
        early = [r for r in paced if float(r["time"]) - t0 <= 30]
        jump = max((float(b["drawn"]) - float(a["drawn"]) for a, b in zip(early, early[1:])), default=0)
        stood = moved if moved is not None else float(rows[-1]["time"]) - t0
        stood_all.append(stood)
        jumps_all.append(jump)
        print(f"{path.rsplit('/', 1)[-1]}: {rows[0]['reports']} position(s) at its first frame, the newest "
              f"{float(rows[0]['report_age']):.0f} s old; stood {stood:.0f} s"
              + ("" if moved is not None else " (never moved)") + f"; biggest move in a second: {jump:.0f} m")
    if stood_all:
        print(f"over {len(stood_all)} openings: stood {statistics.median(stood_all):.0f} s typically "
              f"(longest {max(stood_all):.0f} s); biggest jump {max(jumps_all):.0f} m")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--openings":
        openings(sys.argv[2:])
    else:
        main(sys.argv[1] if len(sys.argv) > 1 else "train-trace.tsv")
