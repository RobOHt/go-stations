#!/usr/bin/env python3
"""Make sure the app's bundle ID exists in the Apple Developer account, with iCloud
enabled. The App Store Connect app record can only be created once the bundle ID
exists. Uses the App Store Connect API key from the environment:

    KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID

Usage: register_bundle_id.py <bundle-id> <name>
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"


def make_token() -> str:
    now = int(time.time())
    with open(os.environ["KEY_PATH"], encoding="utf-8") as f:
        key = f.read()
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


TOKEN = make_token()


def call(method: str, path: str, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return error.code, {"raw": raw.decode(errors="replace")}


def errors(data) -> str:
    return "; ".join(e.get("detail") or e.get("title", "") for e in data.get("errors", [])) or json.dumps(data)[:500]


def main() -> int:
    bundle, name = sys.argv[1], sys.argv[2]

    query = urllib.parse.urlencode({"filter[identifier]": bundle, "limit": 200})
    status, data = call("GET", f"/bundleIds?{query}")
    if status >= 300:
        print(f"::error title=Bundle ID::Couldn't list bundle IDs ({status}): {errors(data)}")
        return 1

    match = [d for d in data.get("data", []) if d["attributes"].get("identifier") == bundle]
    if match:
        bundle_id = match[0]["id"]
        print(f"Bundle ID {bundle} already registered.")
    else:
        status, data = call("POST", "/bundleIds", {
            "data": {"type": "bundleIds", "attributes": {"identifier": bundle, "name": name, "platform": "IOS"}}
        })
        if status >= 300:
            print(f"::error title=Bundle ID::Couldn't register {bundle} ({status}): {errors(data)}")
            return 1
        bundle_id = data["data"]["id"]
        print(f"::notice title=Bundle ID::Registered {bundle}")

    status, data = call("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities")
    capabilities = {c["attributes"].get("capabilityType") for c in data.get("data", [])} if status < 300 else set()
    if "ICLOUD" not in capabilities:
        status, data = call("POST", "/bundleIdCapabilities", {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {
                    "capabilityType": "ICLOUD",
                    "settings": [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6"}]}],
                },
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}},
            }
        })
        if status >= 300:
            # Not fatal: automatic signing during export can still enable it.
            print(f"::warning title=iCloud capability::Couldn't enable ({status}): {errors(data)}")
        else:
            print("Enabled iCloud capability.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
