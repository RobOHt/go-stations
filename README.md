# GO Stations

A tiny native iOS app that puts the GO Transit station departure board in your pocket. (The Xcode project and target are named `Departures`; the app shows up as **GO Stations** on your home screen.)

- **Map first.** Apple Maps with every GO rail line drawn thick in its official colour, a dot for every station, and your location.
- **Tap a station, get the board.** A native bottom sheet opens with the departure screen as it looks in the station: same bilingual headers, colours, line badges, ⚡ express marker, platform numbers with ♿, red cancellations, and Union's "Info in X min" countdowns. Adapted for portrait so nothing scrolls sideways.
- **Opens to the right board.** Set a home and a work station. On launch the app opens the board for the station you're standing at, otherwise whichever of home/work is closer.
- **No backend, no account, no ads.** Settings sync through iCloud key-value storage; your API key lives in iCloud Keychain. Live data comes straight from Metrolinx.

Trains only for now.

## Setup

1. **Get a Metrolinx API key** (free): <https://api.openmetrolinx.com/OpenDataAPI/Help/Registration/en>. Approval is manual and can take a few business days.
2. **Open `Departures.xcodeproj`** in Xcode 26 or later.
3. Select the **Departures** target → *Signing & Capabilities* → pick your team. Change the bundle identifier if it's taken.
4. Run it on your iPhone (iOS 26+). Paste the key when Settings opens and tap **Save & test key**.

To keep it installed without re-signing every week, archive it and push it to yourself through TestFlight (*Product → Archive → Distribute App → TestFlight Internal Only*).

**Free Apple ID?** Free signing can't use iCloud. Delete the `CODE_SIGN_ENTITLEMENTS` build setting (or `Departures.entitlements`); everything still works, settings just stay on the device, and the app expires after 7 days.

## How it works

| What | Where it comes from |
| --- | --- |
| Lines, colours, track shapes, stations | `Departures/Resources/network.json`, generated from the official GO GTFS feed |
| Union Station board | `ServiceUpdate/UnionDepartures/All` (platforms, "Express To" stop lists) |
| Other stations | `Stop/NextService/{station}` plus `Schedule/Trip/{date}/{trip}` for the stop list (cached per day) |
| Delays | `ComputedDepartureTime` vs `ScheduledDepartureTime` from NextService |
| Cancellations | `ServiceUpdate/Exceptions/Train`; reasons from `ServiceUpdate/ServiceAlert/All` |
| Station alerts under the board | `ServiceUpdate/ServiceAlert/All`, filtered to the station's lines |

The board refreshes every 30 seconds while it's open and stops when you close it, so the app makes no requests in the background.

Express trips are detected from the trip's stop list: if it skips a station that the line's all-stops pattern serves, it gets the ⚡. At Union the feed marks them directly.

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
  Views/        map, station sheet, settings
  Resources/    network.json, asset catalog
tools/build_network.py
```

## Licence

Code: MIT (see `LICENSE`).

Contains information licensed under the [Open Government Licence – Ontario](https://www.ontario.ca/page/open-government-licence-ontario) (Metrolinx GTFS and Open Data API). This project is not affiliated with or endorsed by Metrolinx or GO Transit.
