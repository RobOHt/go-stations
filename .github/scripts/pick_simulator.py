"""Pick a simulator for screenshots: prints "<runtime id> <device type id> <device name>"
for the newest iOS runtime that offers an ordinary iPhone, preferring the models in
PREFERRED (the iPhone Air is the phone the app is tested on). Some runtimes only
support a new two-screen model, whose screenshots need a display picked, so those
are skipped."""
import json
import subprocess
import sys

PREFERRED = ["iPhone Air", "iPhone 18 Pro", "iPhone 18", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"]
SKIP = ("Duo", "Fold", "Flip")


def simctl(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))


all_types = {d["name"]: d["identifier"] for d in simctl("devicetypes")["devicetypes"]}
runtimes = [r for r in simctl("runtimes")["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")], reverse=True)

for runtime in runtimes:
    supported = {d["name"]: d["identifier"] for d in runtime.get("supportedDeviceTypes", [])} or all_types
    print(f"{runtime['name']}: {', '.join(sorted(supported))}", file=sys.stderr)
    usable = [n for n in supported if n.startswith("iPhone") and not any(k in n for k in SKIP)]
    if not usable:
        continue
    fallback = sorted(usable, key=lambda n: ("Pro" not in n, n))
    name = next(n for n in PREFERRED + fallback if n in usable)
    print(runtime["identifier"], supported[name], name.replace(" ", "_"))
    break
else:
    sys.exit("No iOS runtime with an ordinary iPhone available")
