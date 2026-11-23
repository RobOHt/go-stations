# Setting up your own copy

Building the app from source needs only Xcode: it talks to the project's Worker out
of the box. To run your own backend and ship your own TestFlight builds, set up the
pieces below. Keys go into GitHub Actions secrets and Cloudflare Worker secrets
only, never into the code, a commit, an issue or a chat.

## Build and run

1. Open `Departures.xcodeproj` in Xcode 26 or later (CI builds with Xcode 27).
2. Pick your team under *Signing & Capabilities* for the `Departures` and
   `DeparturesWidgets` targets.
3. Run on an iPhone or a simulator with iOS 18 or later.

Run the tests with *Product → Test*, and the Worker's with:

```sh
node --test worker/test/*.test.js
```

## Your own Worker

1. **Metrolinx API key** (free): register at
   <https://api.openmetrolinx.com/OpenDataAPI/Help/Registration/en>. Approval is
   manual and can take a few business days.
2. **Cloudflare** (free plan): create an API token from the *Edit Cloudflare
   Workers* template. Add these GitHub repository secrets:
   - `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
   - `METROLINX_API_KEY`, which the Worker workflow stores as a Worker secret
3. Push a change under `worker/` (or run the *Worker* workflow by hand): it runs
   the Worker's tests, then deploys it, and prints its `workers.dev` URL.
4. Point `ProxyConfig.baseURL` (in `Departures/API/MetrolinxClient.swift`) at your
   Worker.

## Live Activity push updates (optional)

With these, the Worker follows a tracked train while it runs and updates its Live
Activity at each stop with the app closed.

1. In your Apple Developer account, create a key with *Apple Push Notifications
   service* (Sandbox & Production, Team Scoped) and turn on *Push Notifications*
   for the app's identifier.
2. Add `APNS_KEY_P8` (the whole .p8 file) and `APNS_KEY_ID` as GitHub repository
   secrets; the Worker workflow stores them as Worker secrets, and TestFlight builds
   then get push tokens.

The Worker keeps a tracked trip's push token and stop times only until the trip
ends.

## TestFlight builds from GitHub

1. In App Store Connect, create an API key with the Admin role.
2. Add the GitHub repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
   (the whole .p8 file) and `APPLE_TEAM_ID`.

Every push to `main` that touches the app then runs the app's tests and, if they
pass, archives the app and uploads it to TestFlight. Until the secrets exist, the
workflow stops at a "not configured" notice.

## The timetable

The app falls back to GO's published timetable when live data isn't available. The
*Timetable* workflow rebuilds it daily from GO's public GTFS feed onto the
`schedule-data` branch, where the app downloads it; each TestFlight build bundles a
fresh copy too. To build it by hand:

```sh
python3 tools/build_schedule.py --output Departures/Resources/schedule.json
```
