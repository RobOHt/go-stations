# GO Stations

A tiny native iOS app that puts the GO Transit station departure board in your pocket. (The Xcode project and target are named `Departures`; the app shows up as **GO Stations** on your home screen.) It runs on iOS 18 and later, in Liquid Glass from iOS 26; on iOS 18 the controls are frosted, as iOS drew them then.

- **Map first.** Apple Maps with every GO rail line drawn thick in its official colour, and every station a dot with a pin standing on it, its name on a tag you tap to open it (home and work in blue and brown). Where the stations crowd together, the ones that matter most keep their pins: the one you have open, home, work, Union, then where lines meet and end. Pins stay clear of the map's buttons, Apple's logo, the search bar and the sheet's edge, and sit above the trains, so a passing train never hides a name.
- **Tap a station, get the board.** A native bottom sheet opens with the departure screen as it looks in the station: same bilingual headers, colours, line badges, ⚡ express marker, platform numbers with ♿, red cancellations, and Union's "Info in X min" countdowns. Adapted for portrait so nothing scrolls sideways.
- **Opens to the right board.** Set a home and a work station. On launch the app opens the board you most likely want, worked out on the phone from the timetable, so it's instant:
  - near home or work, that station;
  - on a train of your commute (judged from where the timetable puts the trains), the next station where you change;
  - anywhere else, the station you'd get home from soonest (on weekday mornings, to work), on foot if one is within a 10-minute walk, otherwise by car.

  With neither set, it opens the nearest station (up to 25 km away), and a hint on the board says how to make it home or work.
- **Any day this week.** Above each board, today and the next seven days: tap one for that day's trains, all day, as timetabled. The day stays picked for every board you open after it, until you tap Today (or come back to the app later). Today's board runs on past the live trains to the rest of the day's. A day with more than ten trains can narrow to its morning (to 11:00), noon (to 14:00) or afternoon (to the last train).
- **Your direction.** With home and work set, your home station's board shows only the trains toward work, and your work station's only the ones toward home (or toward where you change, like Union). A switch at the top of the board shows every direction.
- **Track a train.** Tap *Track this train* on a train's stops. It moves along its line on the map where it really is, with a pointer showing which way it's going (one pin with your location when you're on it), a button bottom left opens it again, and a Live Activity on the Lock Screen and in the Dynamic Island counts down to its next stop, with the stops either side of it. Tracked from your station's board, it first counts down to the train getting to you ("Your Lakeshore East line 08:12 westbound train to Union Station will arrive in 6 minutes"). "Arrived" shows while the train actually stands at a station, from when it's seen pulling in to when it's seen leaving, and the stops ahead are as late as the train runs. A train's stops show how fast it's going: the speed the map draws it moving at. With push set up (step 5 below), the Worker follows the train while it runs and pushes the Live Activity an update when it pulls in at a stop or leaves one, so it keeps up with the app closed.
- **Every train at once.** The map shows every train running now moving along its line (turn off *Show all trains* in Settings for just the one you track), from GO's live train positions (the timetable when those aren't available). Trains fade in as they set off and fade out a minute after their last stop. Tap one for its stops.
- **No accounts, no ads.** Home/work sync through iCloud key-value storage. Live data comes from Metrolinx through a tiny Cloudflare Worker that holds the API key, so nothing secret ships in the app.

Trains only for now.

## Setup

1. **Metrolinx API key** (free): <https://api.openmetrolinx.com/OpenDataAPI/Help/Registration/en>. Approval is manual and can take a few business days.
2. **Cloudflare** (free): create an API token from the *Edit Cloudflare Workers* template. Add these GitHub repository secrets:
   - `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
   - `METROLINX_API_KEY`, which the Worker workflow stores as a Worker secret
3. **App Store Connect** (for TestFlight builds from GitHub): create an API key with the Admin role and add `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `APPLE_TEAM_ID`.
4. Point `ProxyConfig.baseURL` (in `Departures/API/MetrolinxClient.swift`) at your Worker.
5. **Live Activity push updates** (optional): in your Apple Developer account, create a key with *Apple Push Notifications service* (Sandbox & Production, Team Scoped) and turn on *Push Notifications* for the app's identifier. Add `APNS_KEY_P8` (the whole .p8 file) and `APNS_KEY_ID`; the Worker workflow stores them as Worker secrets, and TestFlight builds then get push tokens. The Worker keeps a tracked trip's push token and stop times only until the trip ends.

Every push to `main` builds the app and uploads it to TestFlight. Changes under `worker/` redeploy the Worker.

To build locally instead, open `Departures.xcodeproj` in Xcode 26 or later, pick your team under *Signing & Capabilities*, and run.

## How it works

| What | Where it comes from |
| --- | --- |
| Lines, colours, track shapes, stations | `Departures/Resources/network.json`, generated from the official GO GTFS feed |
| Live data | the Worker in `worker/`, which forwards to Metrolinx Open Data with the key and caches answers for 20 s to 10 min |
| Live train positions | GO's GTFS vehicle positions (every ~20 s: where each train is, and whether it's standing at a station) with Service at a Glance's delays, merged by the Worker (`/v1/live/trains`, cached 5 s). The map draws each train 5 seconds behind now: on a smooth curve through the places it was reported along the track, and past the latest report (GO's come about every 20 s, 5 to 15 s after the fact) carried on at its pace, braking for the station ahead. The drawn train eases from one guess to the next, speeding up and slowing down no harder than a train does, so it never jumps or goes back |
| Union Station board | `ServiceUpdate/UnionDepartures/All` (platforms, "Express To" stop lists) |
| Other stations | `Stop/NextService/{station}` plus `Schedule/Trip/{date}/{trip}` for the stop list (cached per day) |
| Delays | `ComputedDepartureTime` vs `ScheduledDepartureTime` from NextService |
| Cancellations | `ServiceUpdate/Exceptions/Train`; reasons from `ServiceUpdate/ServiceAlert/All` |
| Station alerts under the board | `ServiceUpdate/ServiceAlert/All`, filtered to the station's lines |
| Fallback when live data is unavailable | `schedule.json`: the next 14 days of trains from GO's GTFS, rebuilt daily on the `schedule-data` branch and bundled into each build (`tools/build_schedule.py`) |

The board refreshes every 20 seconds while it's open (matching the Worker's cache) and right away when you come back to the app. Live train positions refresh every 5 seconds while the map shows the tracked train or all trains (every 15 seconds while a train's stops are open), so each report is in soon after GO has it. It stops when you close it, so the app makes no requests in the background (apart from one check, a while after a tracked train is due at your stop, to end its Live Activity). Metrolinx has no push feed, so polling is as fresh as it gets.

Express trips are detected from the trip's stop list: if it skips two or more stations in a row that the line's all-stops pattern serves, it gets the ⚡. At Union the feed marks them directly.

## Updating the network data

GTFS changes every few weeks, but tracks and stations rarely do. When a line or station changes:

```sh
python3 tools/build_network.py            # downloads the official GO-GTFS.zip
# or
python3 tools/build_network.py --input path/to/GO-GTFS.zip
```

## Project layout

```
Departures/
  App/          entry point
  API/          Metrolinx client, response types, board assembly
  Board/        the departure board view, theme, refresh model
  Model/        bundled rail network, board row types, time helpers
  Settings/     iCloud KV + Keychain settings
  Location/     one-shot location
  Planner/      which board to open on launch
  Tracking/     the tracked train: its button, its Live Activity (views shared with the widget extension)
  Views/        map, station sheet, settings
  Resources/    network.json, asset catalog
DeparturesWidgets/   widget extension that draws the Live Activity
tools/build_network.py
tools/commute_reference.py   the launch logic again in Python; CI checks the app against it
```

## Licence

Code: MIT (see `LICENSE`).

Contains information licensed under the [Open Government Licence – Ontario](https://www.ontario.ca/page/open-government-licence-ontario) (Metrolinx GTFS and Open Data API). This project is not affiliated with or endorsed by Metrolinx or GO Transit.
