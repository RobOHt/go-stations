"""Pick a simulator for screenshots: prints "<runtime id> <device type id> <device name>"
for the newest iOS runtime that offers an ordinary iPhone, preferring the models in
PREFERRED (the iPhone Air is the phone the app is tested on). Some runtimes only
support a new two-screen model, whose screenshots need a display picked, so those
are skipped.

IOS_VERSION (say "18") picks the newest runtime of that version instead, and
DEVICE (say "iPhone 16 Pro") that model when the runtime has it. Exits 2 when no
runtime of IOS_VERSION is installed."""
import json
import os
import subprocess
import sys

PREFERRED = ["iPhone Air", "iPhone 18 Pro", "iPhone 18", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"]
SKIP = ("Duo", "Fold", "Flip")

want_ios = os.environ.get("IOS_VERSION", "").strip()
want_device = os.environ.get("DEVICE", "").strip()


def simctl(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))


def matches(version):
    return not want_ios or version == want_ios or version.startswith(want_ios + ".")


all_types = {d["name"]: d["identifier"] for d in simctl("devicetypes")["devicetypes"]}
runtimes = [r for r in simctl("runtimes")["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
print("Installed: " + ", ".join(r["name"] for r in runtimes), file=sys.stderr)
runtimes = [r for r in runtimes if matches(r["version"])]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")], reverse=True)

for runtime in runtimes:
    supported = {d["name"]: d["identifier"] for d in runtime.get("supportedDeviceTypes", [])} or all_types
    print(f"{runtime['name']}: {', '.join(sorted(supported))}", file=sys.stderr)
    usable = [n for n in supported if n.startswith("iPhone") and not any(k in n for k in SKIP)]
    if not usable:
        continue
    fallback = sorted(usable, key=lambda n: ("Pro" not in n, n))
    name = next(n for n in [want_device] + PREFERRED + fallback if n in usable)
    print(runtime["identifier"], supported[name], name.replace(" ", "_"))
    break
else:
    if want_ios:
        print(f"No iOS {want_ios} runtime installed", file=sys.stderr)
        sys.exit(2)
    sys.exit("No iOS runtime with an ordinary iPhone available")
