#!/usr/bin/env python3
"""Print the TestFlight status of the app: recent builds and their processing /
beta state, plus internal testing groups. No personal data (tester names or
emails) is printed, because workflow logs on a public repo are public.

Usage: asc_status.py <bundle-id>
"""
import sys
import urllib.parse

from register_bundle_id import call, errors


def get(path: str, **params):
    query = urllib.parse.urlencode(params)
    status, data = call("GET", f"{path}?{query}" if query else path)
    if status >= 300:
        raise SystemExit(f"::error title=App Store Connect::{path} ({status}): {errors(data)}")
    return data


def main() -> int:
    bundle = sys.argv[1]
    lines = []

    apps = get("/apps", **{"filter[bundleId]": bundle, "limit": 10}).get("data", [])
    app = next((a for a in apps if a["attributes"].get("bundleId") == bundle), None)
    if not app:
        print(f"::warning title=TestFlight status::No App Store Connect app for {bundle} yet.")
        return 0
    lines.append(f"App: {app['attributes'].get('name')} ({bundle})")

    builds = get("/builds", **{"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 5}).get("data", [])
    if not builds:
        lines.append("Builds: none uploaded yet")
    for build in builds:
        attributes = build["attributes"]
        detail = get(f"/builds/{build['id']}/buildBetaDetail").get("data", {}).get("attributes", {})
        lines.append(
            f"Build {attributes.get('version')}: processing={attributes.get('processingState')}"
            f" internal={detail.get('internalBuildState')} expired={attributes.get('expired')}"
            f" uploaded={attributes.get('uploadedDate')}"
        )

    groups = get(f"/apps/{app['id']}/betaGroups", limit=50).get("data", [])
    if not groups:
        lines.append("Testing groups: none (create one under TestFlight > Internal Testing)")
    for group in groups:
        attributes = group["attributes"]
        testers = get(f"/betaGroups/{group['id']}/betaTesters", limit=200).get("data", [])
        group_builds = get(f"/betaGroups/{group['id']}/builds", limit=50).get("data", [])
        states = sorted({t["attributes"].get("state") or "?" for t in testers})
        lines.append(
            f"Group '{attributes.get('name')}': internal={attributes.get('isInternalGroup')}"
            f" testers={len(testers)} tester_states={','.join(states) or '-'}"
            f" builds={','.join(b['attributes'].get('version', '?') for b in group_builds) or 'none'}"
            f" auto_distribution={attributes.get('hasAccessToAllBuilds')}"
        )

    for line in lines:
        print(line)
    body = "%0A".join(line.replace("%", "%25") for line in lines)
    print(f"::notice title=TestFlight status::{body}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
