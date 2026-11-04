"""Pick a simulator for screenshots: prints "<runtime id> <device type id> <device name>"
for the newest available iOS runtime and the first device type in PREFERRED that it
supports (the iPhone Air is the phone the app is tested on)."""
import json
import subprocess
import sys

PREFERRED = ["iPhone Air", "iPhone 18 Pro", "iPhone 18", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"]
# Foldable or two-screen models: screenshots need a display picked, so skip them.
SKIP = ("Duo", "Fold", "Flip")


def simctl(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))


runtimes = [r for r in simctl("runtimes")["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
if not runtimes:
    sys.exit("No iOS simulator runtime installed")
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
runtime = runtimes[-1]
supported = {d["name"]: d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
if not supported:
    supported = {d["name"]: d["identifier"] for d in simctl("devicetypes")["devicetypes"]}

print("Supported:", ", ".join(sorted(supported)), file=sys.stderr)
fallback = sorted((n for n in supported if n.startswith("iPhone") and not any(k in n for k in SKIP)),
                  key=lambda n: ("Pro" not in n, n))
for name in PREFERRED + fallback:
    if name in supported:
        print(runtime["identifier"], supported[name], name.replace(" ", "_"))
        break
else:
    sys.exit("No iPhone device type available")
