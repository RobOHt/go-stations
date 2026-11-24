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
seconds while the map shows the tracked train or all trains, or a train's stops are
open. Nothing is fetched in the background, apart from one check a while after a
tracked train is due at your stop, to end its Live Activity. Metrolinx has no push
feed, so polling is as fresh as it gets.

Express trips are detected from the trip's stop list: if it skips two or more
stations in a row that the line's all-stops pattern serves, it gets the ⚡. At Union
the feed marks them directly.

## Live GPS first, the timetable as the backup

One rule decides where a train is drawn: while it has a live position (the GPS
positions GO reports for it), those alone place it. Not the timetable, and not your
phone's GPS, even on the train you're riding: you're your own blue dot.

GO reports each train every 15 seconds or so (some every 5), and a report is 5 to
15 seconds old by the time the app has it. Each report is put at the nearest point
of the train's track (or just where it says, when that's well off the line: a
yard, a detour). A run's track starts and ends at its first and last stations' own
spots on the line, and a train's GPS stands a little way from those: at Union,
trains for the west wait 140 to 190 m short of where their run starts, and trains
in from the west stop that far past where theirs ends. Those reports are placed
there too, straight on along the track, so a train is seen to set off from its
first metres. So that trains move rather than jump from one report to the next,
each is drawn where it was 10 seconds ago (`TrainReplay`):

- between two reports, along a smooth curve through them (a monotone cubic: it
  never goes back or overshoots, and stands where the train stood);
- past its latest report, while the next isn't in yet, carrying on at the pace it
  last covered the ground at, slowing for the station it's heading for and
  stopping 250 m short of it: a train may come to a stand anywhere from there on
  (GO's trains stand up to 235 m short of Union's own spot on the line), so from
  there only its reports bring it in. And only while its reports have it
  measurably moving: a standing train's GPS wobbles by a metre or two, which isn't
  it setting off.

When a new report shows that carrying on was off (the train braked early, a GPS
position strayed), the train is put right in one quick slide, never eased there
over many seconds. Ten seconds is about how old a report is on arrival, so there's
usually one either side of the moment drawn and little carrying on to do. Replayed
against real trains' reports, as the app would have got them:

| | Gliding, 10 s behind | Stepping from report to report |
| --- | --- | --- |
| Into a suburban station (a report every 15 s) | 193 m from the real train (worst 254 m) | 209 m (worst 567 m) |
| Out of it again | 119 m (worst 219 m) | 148 m (worst 452 m) |
| Out of Union, between downtown's towers | 58 m (worst 187 m) | 74 m (worst 425 m) |
| Into Union (a report every 5 to 10 s) | 63 m (worst 240 m) | 86 m (worst 320 m) |

(Median distance from where the train really was, read off all its reports
afterwards.) Gliding was never ahead of the real train, and had to be put back
once in the four runs, after a stray GPS position downtown. It showed a train in
at its platform, and on its way out of one, within a couple of seconds of when
stepping did. Drawn 5 seconds behind, it was closer still (32 to 108 m) but ran
ahead of the train downtown and had to be put back more often and further; 20
seconds behind it never had to be, and was further off than stepping.

A train's speed is only ever measured: the ground between its latest report and
the newest one at least 12 seconds before it (GO's "stopped at" shows for most of
a minute while a train is still pulling in, so it isn't taken for 0 km/h). Its
pointer shows the way its track runs where it's drawn.

The timetable is the backup, for a train with no live position (none reported in
the last two minutes, or no list of live trains in the last half minute). The
tracked train is then where its times put it, as late as it was last seen running.
The other trains go by the timetable only when GO's live positions aren't coming
in at all (its feed down or frozen, the app offline): while they are, a train they
leave out isn't running as far as GO says, and isn't drawn. A train drawn by its
times goes to its live position in one quick slide the moment it has one, and
nothing is drawn by the timetable in the first seconds after the app opens or
comes back, while the live positions are on their way: it would be drawn in one
place, then moved to another.

The marker among a train's stops goes by the same rule and the same replay: it's
as far along the track between two stops as the map draws the train.

Earlier versions got this wrong in four ways, each fixed by the rule above. One
eased the drawn train toward where its reports had it over many seconds and
blended in the timetable, so it could sit somewhere its reports didn't have it (a
train standing at a platform drawn still coming in). One drew the tracked train
where your phone was once you were on it, so it wandered with the phone's GPS under
a station's roof. One stepped from report to report with nothing in between, which
was never ahead of the train but further from it, and looked it. And one held a
train at its first station's own spot until its GPS had passed it: out of Union
for the west, it sat there for most of a minute after it had set off (shown 46 to
62 seconds after the real train, where it's now 13 to 15).

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
| README media | By hand | Records the README's clips and screenshots (`tools/readme_media.py` makes `docs/media` from them, and `tools/demo_video.py` a short demo video) |

## Updating the network data

GTFS changes every few weeks, but tracks and stations rarely do. When a line or
station changes:

```sh
python3 tools/build_network.py            # downloads the official GO-GTFS.zip
# or
python3 tools/build_network.py --input path/to/GO-GTFS.zip
```
