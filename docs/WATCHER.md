# The watcher

The watcher is a Durable Object in the Worker (`worker/src/watcher.js`). Every 5
seconds, all day, it looks at GO's two live train feeds, whether or not anyone has
the app open. It does three things with what it sees:

1. **Keeps it.** Every change in either feed goes to R2, one gzipped JSON-lines
   file an hour. That archive is what a better model of how GO's trains move gets
   trained on, and there's no public one.
2. **Scores the app.** For every train, second by second, it replays where the app
   would have drawn the train and compares that with where the train really was,
   read off all its GPS fixes afterwards.
3. **Reports.** Each finished train-minute becomes a data point in Workers
   Analytics Engine, which a Grafana dashboard reads.

Nothing in the app depends on it: if it stops, the app carries on as before.

## How a guess is scored

- **Where the train really was.** A monotone cubic curve (as the app's own replay
  uses) through all of the train's GPS fixes, in metres along its run. A second is
  scored once two of the train's later fixes are in, and at least 30 seconds after.
- **Where it was drawn.** Each model is replayed with only the reports the app had
  at that second: what `/v1/live/trains` carried, 2 seconds after the watcher first
  saw it. That's measured: the app asks every 5 seconds, and the answer can be a few
  seconds old (in a rush hour, the app had each report a median 2.1 s after the
  watcher, which first saw them 7.6 s old).
  Each trip's run is built from its stops (GO's Schedule/Trip) and the app's own
  track shapes (`Departures/Resources/network.json`), so a train is placed exactly
  where the app places it.
- **The error.** Drawn minus real, in metres along the track: negative is behind
  the train, positive ahead.

| Model | What it is |
| --- | --- |
| `today` | What build 148 draws: 10 s behind, gliding through the reports, carried on past the newest one and braking for the station ahead, with the map's 50 m slack. `worker/src/replay.js` is `TrainReplay` ported line for line. Its tests use the app's own self-check numbers. |
| `from_fix` | Option A: no delay, guessed on from each fix's own time (as far as the station's own spot), gliding to each new fix within 2 s |
| `newest` | Where the newest fix has the train: how stale the raw data is |

The first 5 minutes after the watcher starts aren't scored: its trains have no
history yet, which the app wouldn't have had either.

## What's in Analytics Engine

Dataset `go_stations_scores`. There's one data point per train, minute, phase and
model, written about a minute after the minute ends:

| Field | What it holds |
| --- | --- |
| `index1`, `blob1` | Model |
| `blob2` | Line (`LW`, `KI`, ...) |
| `blob3` | Phase: `stand` (below 0.5 m/s), `in` (within 1.5 km before a station it stops at), `out` (within 1.5 km after one), `run` |
| `blob4` | The station it's heading for, or standing at |
| `blob5` | Trip number |
| `blob6` | Direction by Union: `in`, `out`, `through`, `-` |
| `blob7`, `blob8` | Toronto hour (`07`) and weekday (`Tue`) |
| `blob9` | The run's last stop |
| `blob10` | Scoring version (`w1`) |
| `double1` | Seconds scored |
| `double2`, `double3`, `double4` | Sums of the absolute error, error, and squared error (m) |
| `double5`, `double6` | Seconds drawn over 1 m and over 25 m ahead of the train |
| `double7`, `double8` | Furthest ahead, and furthest behind, in the minute (m) |
| `double9`, `double10` | Moves backwards, and metres moved back |
| `double11` | Lurches: moved over 20 m more than the train did, in a second |
| `double12`, `double13` | Seconds off by over 50 m and over 100 m |
| `double14` | Sum of the newest fix's age (s) |
| `double15` | Sum of the train's speed (m/s) |
| `double16` | The minute (Unix seconds) |

Mean error over any slice is `SUM(_sample_interval * double2) / SUM(_sample_interval * double1)`.
Analytics Engine keeps data for 3 months. The R2 archive keeps everything.

## What's in R2

Bucket `go-stations-positions`, files `positions/YYYY/MM/DD/HH.ndjson.gz` (UTC
hours). Each file starts with a `meta` line, then one line per change:

```
{"k":"tick","t":1795554005.2,"v":{"ok":true,"ts":1795554001,"n":61},"g":{"ok":true,"ts":"2026-11-24 16:00:03","n":63}}
{"k":"v","t":1795554005.2,"e":{...GO's GTFS-Realtime vehicle entity, as sent...}}
{"k":"g","t":1795554005.2,"e":{...the train in Service at a Glance, as sent...}}
{"k":"v-","t":...,"id":"20261124-LW-1925"}    (gone from the feed)
{"k":"trip","t":...,"day":"20261124","trip":"1925","codes":["AL","BU",...],"stops":[...]}
```

`t` is when the watcher had the answer. The first look of each hour writes both
feeds in full (`"full":true`), so every file plays back on its own:

```
node tools/replay_archive.mjs 21.ndjson.gz 22.ndjson.gz
```

`tools/replay_archive.mjs` runs the watcher's own code over the files and prints
each model's numbers overall, by phase and by line. It works on R2 files and on
`tools/record_feeds.mjs` recordings alike. The probe workflow's `record` mode
makes one of those (and scores it) without anything deployed.

## Setting it up

The watcher deploys with the Worker. It needs, once:

1. **Workers Paid** ($5 a month). Each look reads both feeds and replays every
   train, which is more CPU than the free plan's 10 ms per invocation. The
   scoreboard also writes more data points than the free plan's 100,000 a day.
2. **R2**, turned on in the Cloudflare dashboard. The deploy workflow creates the
   `go-stations-positions` bucket if it isn't there. If its API token can't, create
   the bucket in the dashboard under that name.

After the deploy, `/health?check=watch` says how the watcher is doing: when it last
looked, how many trains it's placing, how old fixes are when it sees them, its
last R2 file, and each model's last hour. The deploy's health check prints it.

### The Grafana dashboard

1. In Grafana (Grafana Cloud's free tier is enough), install the **Altinity plugin
   for ClickHouse** (`vertamedia-clickhouse-datasource`).
2. In Cloudflare, create an API token with one permission: **Account → Account
   Analytics → Read**. Paste it into Grafana only.
3. Add a data source of that type:
   - URL: `https://api.cloudflare.com/client/v4/accounts/<account id>/analytics_engine/sql`
   - Auth: all off
   - Custom HTTP header: `Authorization`, value `Bearer <the token>`
4. Import `docs/grafana/watcher-dashboard.json` and pick that data source.

The dashboard shows each model's error over time, the time spent ahead of the train
and more than 100 m off, moves backwards, error by hour of the day, by phase and by
line, the stations where today's model is furthest off, and the worst minutes. The
`Line` and `Doing` menus filter it.

## Costs and limits

- The Durable Object is billed only while it's working (about a second every 5
  seconds), not while it waits for its next alarm. That's well inside the paid
  plan's 400,000 GB-s a month.
- Its alarms count as requests: about 560,000 a month with the Cron Trigger's,
  inside the plan's 1 million.
- The archive is small: in a rush hour, 25 minutes of both feeds came to 4 MB of
  JSON lines and 0.17 MB gzipped, so under 0.3 GB a month, inside R2's 10 GB free
  storage. Downloading it costs nothing.
- Analytics Engine takes at most 250 data points per invocation, so the watcher
  writes at most 200 per look and keeps the rest for the next.
- Alarms are retried only a few times after an error. The watcher catches its own
  errors and always sets its next alarm, and the Cron Trigger restarts it every
  minute if it ever stops.

## Turning it off

Set `WATCH = "off"` in `worker/wrangler.toml` and deploy. It stops at its next
look. Its archive stays in R2.
