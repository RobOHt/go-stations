#!/usr/bin/env python3
"""The pull request comment showing the simulator screenshots (Screenshots workflow).

Usage: screenshot_comment.py SHOTS_DIR REPO SHOTS_SHA BRANCH HEAD_SHA DEVICE > comment.md

SHOTS_DIR has the full-size PNGs, small copies in thumbs/, and startup.txt with
one "ok" or "FAIL" line per start-up check. Images are linked from the
screenshots branch commit, so each comment keeps showing its own run.
"""
import os
import sys

shots, repo, shots_sha, branch, head_sha, device = sys.argv[1:7]
raw = f"https://raw.githubusercontent.com/{repo}/{shots_sha}"
files = sorted(f for f in os.listdir(shots) if f.endswith(".png"))
screens = [f for f in files if not f.startswith("start-")]
starts = [f for f in files if f.startswith("start-")]

results = {}
path = os.path.join(shots, "startup.txt")
if os.path.exists(path):
    for line in open(path):
        parts = line.split(None, 2)
        if len(parts) >= 2:
            results[parts[1]] = (parts[0] == "ok", line.split(": ", 1)[-1].strip())


def grid(names, caption):
    rows = ["| | | |", "|---|---|---|"]
    for i in range(0, len(names), 3):
        cells = [f'<a href="{raw}/{f}"><img src="{raw}/thumbs/{f}" width="200"></a><br><sub>{caption(f)}</sub>'
                 for f in names[i:i + 3]]
        cells += [" "] * (3 - len(cells))
        rows.append("| " + " | ".join(cells) + " |")
    return "\n".join(rows)


def start_caption(f):
    name = f[len("start-"):-len(".png")]
    ok, detail = results.get(name, (False, "no result"))
    return f"{'✅' if ok else '❌'} {name}: {detail}"


passed = sum(1 for f in starts if results.get(f[len("start-"):-len(".png")], (False,))[0])
out = [
    "<!-- screenshots -->",
    "### Simulator screenshots",
    f"{device}, commit {head_sha[:7]} · [full size](https://github.com/{repo}/tree/{branch})",
    "",
]
if starts:
    status = "all as expected" if passed == len(starts) else f"{len(starts) - passed} wrong"
    out += [f"**Board opened on start-up** ({passed} of {len(starts)}, {status})", "", grid(starts, start_caption), ""]
if screens:
    out += ["**Screens**", "", grid(screens, lambda f: f[:-len(".png")]), ""]
print("\n".join(out))
