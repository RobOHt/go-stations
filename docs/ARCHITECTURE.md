# Architecture

GO Stations is a native iOS app with a small serverless backend. The app does all
the planning and drawing on the phone; a Cloudflare Worker sits between it and
Metrolinx's feeds (holding the API key, caching, merging feeds), and follows
tracked trains to push their Live Activities while the app is closed.

```mermaid
flowchart LR
    actions["GitHub Actions<br/>daily timetable build"]
    app["GO Stations app<br/>SwiftUI · MapKit<br/>timetable on the phone"]
    subgraph cloudflare["Cloudflare"]
        direction TB
        worker["Worker<br/>proxy · edge cache · rate limits"]
        follower["LiveActivities<br/>Durable Object"]
    end
    metrolinx[("Metrolinx Open Data<br/>REST · GTFS-Realtime")]
    apns["Apple Push<br/>Notification service"]
    activity["Live Activity<br/>Lock Screen · Dynamic Island"]

    actions -- "timetable" --> app
    app -- "boards, trips, live trains" --> worker
    worker -- "adds the API key" --> metrolinx
    worker -- "track this train" --> follower
    follower -- "where is it? every 20 s" --> metrolinx
    follower -- "updates and alerts" --> apns
    apns --> activity
```

## The app

| Folder | What's in it |
| --- | --- |
| `Departures/App` | Entry point; debug scenes for screenshots and recordings; the in-app self-checks |
| `Departures/API` | The Metrolinx client and response shapes (read leniently), board assembly, live trains, cancellations, the timetable store |
| `Departures/Board` | The departure board: view, theme, refresh model |
| `Departures/Model` | The bundled rail network (lines, track shapes, stations), board rows, Toronto time helpers |
| `Departures/Planner` | Which board to open on launch, and trips planned from search |
| `Departures/Tracking` | The tracked train or trip: its button, alerts, missed-train check, and its Live Activity (views shared with the widget extension) |
| `Departures/Views` | Map, search, trip card, station sheet, settings |
| `DeparturesWidgets` | The widget extension that draws the Live Activity |

There are no third-party dependencies: the app uses Apple's frameworks only
(SwiftUI, MapKit, ActivityKit, WidgetKit, Core Location), and the Worker only
Cloudflare's runtime.

## Where the data comes from

| What | Where it comes from |
| --- | --- |
| Lines, colours, track shapes, stations | `Departures/Resources/network.json`, generated from the official GO GTFS feed (`tools/build_network.py`) |
| Live data | The Worker in `worker/`, which forwards to Metrolinx Open Data with the key and caches answers for 20 s to 10 min |
| Live train positions | GO's GTFS vehicle positions (every ~20 s: where each train is, and whether it's standing at a station) with Service at a Glance's delays, merged by the Worker (`/v1/live/trains`, cached 5 s) |
| Union Station board | `ServiceUpdate/UnionDepartures/All` (platforms, "Express To" stop lists) |
| Other stations | `Stop/NextService/{station}` plus `Schedule/Trip/{date}/{trip}` for the stop list (cached per day) |
| Delays | `ComputedDepartureTime` vs `ScheduledDepartureTime` from NextService |
| Cancellations | GO's GTFS trip updates (trips cancelled, stations skipped) and `ServiceUpdate/Exceptions/Train`, read together by the Worker (`/v1/live/cancelled`, cached 30 s), since either has had a cancellation the other hadn't; a station's own board too. Reasons from `ServiceUpdate/ServiceAlert/All` |
| Alerts under a board | `ServiceUpdate/ServiceAlert/All`, filtered to the station's lines |
| When live data is unavailable | `schedule.json`: the next 14 days of trains from GO's GTFS, rebuilt daily on the `schedule-data` branch (`tools/build_schedule.py`), bundled into each build and downloaded by the app |

The board refreshes every 20 seconds while it's open (matching the Worker's cache)
and right away when you come back to the app. Live train positions refresh every 5
seconds while the map shows the tracked train or all trains (every 15 seconds while
a train's stops are open). Nothing is fetched in the background, apart from one
check a while after a tracked train is due at your stop, to end its Live Activity.
Metrolinx has no push feed, so polling is as fresh as it gets.

Express trips are detected from the trip's stop list: if it skips two or more
stations in a row that the line's all-stops pattern serves, it gets the ⚡. At Union
the feed marks them directly.

## Trains that move like trains

GO reports each train's position about every 20 seconds, 5 to 15 seconds after the
fact. The map draws each train 5 seconds behind now: on a smooth curve through the
places it was reported along the track, and past the latest report carried on at its
pace, braking for the station ahead. The drawn train eases from one guess to the
next, speeding up and slowing down no harder than a train does, so it never jumps or
goes back.

## The Worker

One Worker (`worker/src/index.js`, `worker/src/live.js`), no dependencies:

| Endpoint | What it does |
| --- | --- |
| `GET /v1/{Metrolinx path}` | Forwards the five read-only Metrolinx endpoints the app uses, with the key. Only GO's data goes back, never its error pages; good answers are cached at the edge for 20 s to 10 min |
| `GET /v1/live/trains` | Every train running now: GTFS vehicle positions merged with Service at a Glance (delays, motion, heading), cached 5 s |
| `GET /v1/live/cancelled` | Cancelled trains and skipped stations from GO's two cancellation feeds together, cached 30 s |
| `POST /v1/activity` | Starts following a tracked trip for its Live Activity (and `/v1/activity/end` stops) |

Requests that reach Metrolinx are rate-limited per IP. The Metrolinx and Apple push
keys are Worker secrets; nothing secret ships in the app.

## Following a tracked train

The `LiveActivities` Durable Object keeps each tracked trip (its push token, stops
and times) until the trip ends, and wakes on an alarm:

```mermaid
sequenceDiagram
    autonumber
    participant App as GO Stations
    participant DO as LiveActivities<br/>(Durable Object)
    participant GO as Metrolinx feeds
    participant APNs as Apple Push
    App->>DO: POST /v1/activity: push token, stops, times
    loop every 20 s while the train runs
        DO->>GO: where is it? (vehicle positions, Service at a Glance)
        DO->>DO: pulled in, or left? re-time the stops ahead
        opt it changed, or you're 5 min from your change or stop
            DO->>APNs: Live Activity update (with an alert when due)
            APNs-->>App: Lock Screen and Dynamic Island redrawn
        end
        DO->>GO: cancelled? (every couple of minutes)
    end
    DO->>APNs: end, once the train is in
```

- **Arrivals and departures** come from the train's own reports: "Arrived" shows
  from when it's seen pulling in to when it's seen leaving; a report older than the
  last one looked at, or from a yard, doesn't move it.
- **On a trip with changes**, once the train you're on gets in where you change,
  the next train takes over in the same Live Activity.
- **Cancelled** (or not stopping where you get on or off), the Live Activity says
  so, with an alert, and the app is woken to find the next train.
- **Missed it?** A couple of minutes after your first train leaves, a silent push
  wakes the app to check you're on it (it knows where you are; the Worker doesn't).
- **One trip the Worker can't handle** is skipped and, after failing a few times,
  dropped, so it never holds up everyone else's.

## Built for unreliable data

Transit feeds freeze for days, answer with web pages, and say the same thing in
different shapes. The app and the Worker are tested against that, with tests written
from what a rider should see before looking at how the code handles it:

- **The Worker** (`worker/test/robustness.test.js`): GO failing in every way a proxy
  can see, frozen feeds, trains listed twice or out of order, impossible positions,
  the clock change; then thousands of seeded rounds of random junk, checking that
  every train, cancellation and push is one the app can read and show.
- **The app** (`DeparturesTests`): boards, a train's stops, live positions,
  cancellations and alerts through a stand-in for the network (`FakeNetwork`).
  Every field of GO's answers is read leniently, so one odd value costs that value,
  not the whole answer; junk in place of the answer itself falls back to the
  timetable, saying so.
- **The UI** (`DeparturesUITests`): the app driven like a rider, with made-up feeds
  the app serves itself in debug builds (`GOFixtures`), and an accessibility audit.

## Continuous delivery

| Workflow | When | What it does |
| --- | --- | --- |
| TestFlight | Every push to `main` that touches the app | Runs the app's unit and UI tests on a simulator; only if they pass, archives and uploads to TestFlight (build number = run number + 10) |
| Worker | Changes under `worker/` | Runs the Worker's tests, then deploys it |
| Tests | Pull requests, other branches | The app's unit and UI tests |
| Build | Pull requests | Compiles the app for the simulator, listing every warning |
| Commute check | Changes to the planner | The start-up planner against its Python reference (`tools/commute_reference.py`) on the current timetable: thousands of random situations must give the same station for the same reason |
| Timetable | Daily | Rebuilds `schedule.json` from GO's GTFS on the `schedule-data` branch |
| Screenshots | `preview/**` branches, or by hand | Simulator screenshots of set-up scenes, for review by eye |
| README media | By hand | Records the README's clips and screenshots (`tools/readme_media.py` makes `docs/media` from them) |

## Updating the network data

GTFS changes every few weeks, but tracks and stations rarely do. When a line or
station changes:

```sh
python3 tools/build_network.py            # downloads the official GO-GTFS.zip
# or
python3 tools/build_network.py --input path/to/GO-GTFS.zip
```
