#!/usr/bin/env python3
"""Reference model of the station the app opens on start-up.

Departures/Planner/CommutePlanner.swift implements the same rules. The Commute
check workflow runs both on the day's real timetable over thousands of random
situations and fails if they ever pick a different station.

The rules, in order:

1. Within a few km of home or work, and that station is about as close as any:
   that station.
2. On a train. Home->work and work->home are each planned once on a typical
   weekday (the most common journey across the morning or evening rush). If a
   journey has a change, and you're on the track of one of its legs where the
   timetable puts a train (moving at constant speed along the track between
   stops, give or take, possibly a few minutes late), the board is the next
   change station ahead. Home's journey wins a tie.
3. Near home or work at all (further out where stations are far apart): that
   station. Otherwise the closest station for where you're going: the one you'd reach
   home (or work) soonest from, counting 5 minutes per change, getting there on
   foot when a station is within about a 10-minute walk, otherwise by car
   (estimated from distance, so it's instant). Weekday mornings (until 12:00)
   you're going to work; afternoons, evenings, weekends and holidays, home.
4. Otherwise what the app did before: the station you're at, else the nearer of
   home and work, else a station within 3 km.

Usage:
  commute_reference.py NETWORK SCHEDULE OUT [--count N] [--seed S]
writes OUT (JSON): the situations and the station this model picks for each.
  commute_reference.py --e2e NETWORK SCHEDULE OUT
writes OUT (tab-separated): a few everyday situations for the simulator check
(Screenshots workflow), with the station the app should open in each.
"""
import datetime
import json
from bisect import bisect_left
import math
import random
import sys
from zoneinfo import ZoneInfo

# Tuning. The Swift planner uses the same values.
MIN_TRANSFER = 5          # minutes to change trains
CHANGE_PENALTY = 5        # minutes added per change when comparing journeys
MAX_LEGS = 3              # trains per journey (two changes)
WALK_RADIUS = 800.0       # metres: a station this close means you're on foot
WALK_OPTIONS = 1200.0     # metres: stations considered on foot
DRIVE_RADIUS = 25000.0    # metres: stations considered by car...
DRIVE_MAX = 16            # ...at most this many, nearest first
DRIVE_FALLBACK = 3        # with none that close, the nearest few
NEAR_MIN = 1200.0         # metres: always "near" home/work within this...
NEAR_FACTOR = 1.5         # ...or within 1.5x the distance to the nearest station
NEAR_FIRST_MAX = 5000.0   # metres: beyond this, a train ride outranks being "near"
ALONG_SLACK = 1500.0      # metres along the track either side of where the timetable puts a train
ACROSS = 350.0            # metres off the track (plus the location's own uncertainty)...
ACROSS_STRAIGHT = 1000.0  # ...or off the straight line where no track shape joins two stops
ACCURACY_CAP = 1000.0     # metres: the most location uncertainty that widens the track
LATE = 4                  # minutes a train may be running late
EARLY = 1                 # minutes a train may be running early
GUARD_MAX = 3000.0        # metres: near a leg's first station, you're waiting, not riding
SNAP = 600.0              # metres: a station this close to a track path is on it
WORK_UNTIL = 12 * 60      # minute of the day (inclusive) until which weekdays are work-bound
ROUTE_TIMES_TO_WORK = [360, 390, 420, 450, 480, 510]
ROUTE_TIMES_TO_HOME = [930, 960, 990, 1020, 1050, 1080]
HOLIDAY_SHARE = 0.8       # a weekday with fewer trips than this share of the usual is a holiday

METRES_PER_DEGREE = 6371000 * math.pi / 180
COS_REF = 0.7229671459095681  # cos(43.7 degrees): one flat projection for the whole network


def xy(lat, lon):
    return (lon * COS_REF * METRES_PER_DEGREE, lat * METRES_PER_DEGREE)


def dist(p, q):
    dx = p[0] - q[0]
    dy = p[1] - q[1]
    return math.sqrt(dx * dx + dy * dy)


def seg_project(p, a, b):
    """Distance from p to segment ab, and how far along it (0...1) the closest point is."""
    vx = b[0] - a[0]
    vy = b[1] - a[1]
    wx = p[0] - a[0]
    wy = p[1] - a[1]
    vv = vx * vx + vy * vy
    t = 0.0
    if vv > 0:
        t = (wx * vx + wy * vy) / vv
        t = min(max(t, 0.0), 1.0)
    c = (a[0] + vx * t, a[1] + vy * t)
    return dist(p, c), t


def polyline_distance(p, pts):
    if len(pts) == 1:
        return dist(p, pts[0])
    best = None
    for i in range(len(pts) - 1):
        d, _ = seg_project(p, pts[i], pts[i + 1])
        if best is None or d < best:
            best = d
    return best


def walk_minutes(metres):
    return metres * 1.25 / 1.3 / 60


def drive_minutes(metres):
    road = metres * 1.35 / 1000
    local = min(road, 4.0)
    return 3 + local / 30 * 60 + max(road - 4, 0.0) / 75 * 60


def ceil_int(x):
    return int(math.ceil(x))


TORONTO = ZoneInfo("America/Toronto")


def day_start(day):
    """When a service day's times count from: noon minus 12 hours (UTC seconds)."""
    noon = datetime.datetime(int(day[:4]), int(day[4:6]), int(day[6:]), 12, tzinfo=TORONTO)
    return noon.timestamp() - 12 * 3600


def day_shift(day, offset):
    """Where the service day `offset` days away starts, in minutes from this one's."""
    return round((day_start(shift_day(day, offset)) - day_start(day)) / 60)


def clock_time(day, minute):
    """The clock time (hours * 60 + minutes) `minute` minutes into a service day."""
    local = datetime.datetime.fromtimestamp(day_start(day) + minute * 60, TORONTO)
    return local.hour * 60 + local.minute


def clock_at(timestamp):
    """The service day, minutes into it, clock time and day shifts at a UTC instant."""
    local = datetime.datetime.fromtimestamp(timestamp, TORONTO)
    day = local.strftime("%Y%m%d")
    now = math.floor((timestamp - day_start(day)) / 60)
    return {"day": day, "now": now, "minuteOfDay": local.hour * 60 + local.minute,
            "shifts": [day_shift(day, o) for o in (-1, 0, 1)]}


def weekday(day):
    return datetime.date(int(day[:4]), int(day[4:6]), int(day[6:])).weekday()  # Monday 0


def shift_day(day, offset):
    d = datetime.date(int(day[:4]), int(day[4:6]), int(day[6:])) + datetime.timedelta(days=offset)
    return d.strftime("%Y%m%d")


class Path:
    def __init__(self, coords):
        self.pts = [xy(lat, lon) for lat, lon in coords]
        self.cum = [0.0]
        for i in range(len(self.pts) - 1):
            self.cum.append(self.cum[-1] + dist(self.pts[i], self.pts[i + 1]))

    def project(self, p):
        """(distance, arc position) of the closest point on the path; first one on ties."""
        best = None
        for i in range(len(self.pts) - 1):
            d, t = seg_project(p, self.pts[i], self.pts[i + 1])
            if best is None or d < best[0]:
                best = (d, self.cum[i] + (self.cum[i + 1] - self.cum[i]) * t)
        if best is None:
            return (dist(p, self.pts[0]), 0.0)
        return best

    def point_at(self, s):
        if len(self.pts) == 1:
            return self.pts[0]
        s = min(max(s, 0.0), self.cum[-1])
        i = 0
        while i < len(self.pts) - 2 and self.cum[i + 1] < s:
            i += 1
        length = self.cum[i + 1] - self.cum[i]
        u = 0.0 if length <= 0 else (s - self.cum[i]) / length
        a, b = self.pts[i], self.pts[i + 1]
        return (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)

    def piece(self, s0, s1):
        lo, hi = min(s0, s1), max(s0, s1)
        pts = [self.point_at(lo)]
        for i in range(len(self.pts)):
            if lo < self.cum[i] < hi:
                pts.append(self.pts[i])
        pts.append(self.point_at(hi))
        return pts


class Network:
    def __init__(self, data):
        self.pos = {}
        for s in data["stations"]:
            self.pos[s["code"]] = xy(s["lat"], s["lon"])
        self.codes = sorted(self.pos)
        self.patterns = {}
        self.paths = {}
        for line in data["lines"]:
            self.patterns[line["code"]] = line.get("patterns", [])
            self.paths[line["code"]] = [Path(p) for p in line.get("paths", []) if len(p) >= 2]
        self._track = {}
        self._segment = {}

    def track(self, line, a, b):
        """The path both stations sit on, and their positions along it."""
        key = (line, a, b)
        if key not in self._track:
            best = None
            for index, path in enumerate(self.paths.get(line, [])):
                da, sa = path.project(self.pos[a])
                db, sb = path.project(self.pos[b])
                if da <= SNAP and db <= SNAP:
                    score = da + db
                    if best is None or score < best[0]:
                        best = (score, index, sa, sb)
            self._track[key] = None if best is None else (best[1], best[2], best[3])
        return self._track[key]

    def segment(self, line, board, alight):
        """The stations from board to alight in travel order: the longest such run on any pattern."""
        key = (line, board, alight)
        if key not in self._segment:
            best = []
            for pattern in self.patterns.get(line, []):
                if board in pattern and alight in pattern:
                    i, j = pattern.index(board), pattern.index(alight)
                    if i < j and j - i + 1 > len(best):
                        best = pattern[i:j + 1]
            self._segment[key] = best
        return self._segment[key]


class Timetable:
    def __init__(self, data):
        self.generated = data["generated"]
        self.patterns = data["patterns"]
        self.trips = data["trips"]
        self.days = data["days"]
        self.counts = {d: len(v) for d, v in self.days.items()}
        weekdays = sorted(self.counts[d] for d in self.days if weekday(d) < 5)
        self.usual = weekdays[len(weekdays) // 2] if weekdays else 0
        self._views = {}

    def is_holiday(self, day):
        return day in self.counts and weekday(day) < 5 and self.counts[day] < HOLIDAY_SHARE * self.usual

    def typical_weekday(self):
        normal = sorted(d for d in self.days if weekday(d) < 5 and not self.is_holiday(d))
        if not normal:
            normal = sorted(self.days)
        if not normal:
            return None
        tally = {}
        for d in normal:
            tally[self.counts[d]] = tally.get(self.counts[d], 0) + 1
        count = min(tally, key=lambda c: (-tally[c], -c))
        return min(d for d in normal if self.counts[d] == count)

    def view(self, day):
        """Trips around a calendar day, times in minutes from that day's start."""
        if day not in self._views:
            trips = []
            for offset in (-1, 0, 1):
                key = shift_day(day, offset)
                for index in self.days.get(key, []):
                    if index >= len(self.trips):
                        continue
                    number, line, pattern, times = self.trips[index]
                    if pattern >= len(self.patterns):
                        continue
                    stops = self.patterns[pattern]
                    n = min(len(stops), len(times))
                    if n < 2:
                        continue
                    shift = day_shift(day, offset)
                    trips.append((number, line, stops[:n], [m + shift for m in times[:n]]))
            conns = []
            for t, (_, _, stops, times) in enumerate(trips):
                for k in range(len(stops) - 1):
                    if times[k + 1] >= times[k]:
                        conns.append((times[k], times[k + 1], t, k))
            conns.sort()
            self._views[day] = (trips, conns, [c[0] for c in conns])
        return self._views[day]


def journey(origin, ready, dest, view):
    """Best journey to dest leaving origin at `ready`: the least arrival plus
    CHANGE_PENALTY per change, over journeys of up to MAX_LEGS trains, fewer
    trains on ties (connection scan with a label per number of trains).
    Returns (score, arrival, legs) with legs [(trip, board index, alight index)], or None."""
    if origin == dest:
        return ready, ready, []
    trips, conns, deps = view
    INF = 10 ** 9
    best = [dict() for _ in range(MAX_LEGS + 1)]     # best[j][stop]: earliest arrival using <= j trains
    via = [dict() for _ in range(MAX_LEGS + 1)]      # via[j][stop]: (trip, board index, alight index, trains)
    best[0][origin] = ready
    board = {}                                       # trip -> [board index for <= j trains]
    score = INF
    for c in range(bisect_left(deps, ready), len(conns)):
        dep, arr, t, k = conns[c]
        if dep > score:
            break
        stops = trips[t][2]
        a = stops[k]
        boards = board.get(t)
        if boards is None or boards[MAX_LEGS] is None:
            transfer = 0 if a == origin else MIN_TRANSFER
            for j in range(1, MAX_LEGS + 1):
                if boards is not None and boards[j] is not None:
                    continue
                if best[j - 1].get(a, INF) + transfer <= dep:
                    if boards is None:
                        boards = [None] * (MAX_LEGS + 1)
                        board[t] = boards
                    boards[j] = k
        if boards is None:
            continue
        b = stops[k + 1]
        for j in range(1, MAX_LEGS + 1):
            if boards[j] is not None and arr < best[j].get(b, INF):
                best[j][b] = arr
                via[j][b] = (t, boards[j], k + 1, j)
        if b == dest:
            for j in range(1, MAX_LEGS + 1):
                if dest in best[j]:
                    score = min(score, best[j][dest] + CHANGE_PENALTY * (j - 1))
    choice = None
    for j in range(1, MAX_LEGS + 1):
        if dest not in via[j]:
            continue
        legs = []
        stop, n = dest, j
        while n > 0 and stop in via[n]:
            t, kb, ka, used = via[n][stop]
            legs.append((t, kb, ka))
            stop, n = trips[t][2][kb], used - 1
        if stop != origin:
            continue
        legs.reverse()
        total = best[j][dest] + CHANGE_PENALTY * (len(legs) - 1)
        if choice is None or (total, len(legs)) < (choice[0], len(choice[2])):
            choice = (total, best[j][dest], legs)
    return choice


def legs_of(view, legs):
    trips = view[0]
    return [(trips[t][1], trips[t][2][kb], trips[t][2][ka]) for t, kb, ka in legs]


class Planner:
    def __init__(self, network, timetable):
        self.net = network
        self.tt = timetable

    # Routes between home and work, planned once.
    def routes(self, home, work):
        day = self.tt.typical_weekday()
        if day is None:
            return None, None
        view = self.tt.view(day)

        def vote(a, b, samples):
            counts, first = {}, {}
            for index, start in enumerate(samples):
                result = journey(a, start, b, view)
                if result is None:
                    continue
                key = tuple(legs_of(view, result[2]))
                if not key:
                    continue
                counts[key] = counts.get(key, 0) + 1
                first.setdefault(key, index)
            if not counts:
                return None
            return list(min(counts, key=lambda k: (-counts[k], len(k), first[k])))

        return vote(home, work, ROUTE_TIMES_TO_WORK), vote(work, home, ROUTE_TIMES_TO_HOME)

    def sorted_stations(self, user):
        return sorted((dist(user, self.net.pos[c]), c) for c in self.net.codes)

    @staticmethod
    def near_radius(ranked):
        return max(NEAR_MIN, NEAR_FACTOR * ranked[0][0])

    def leg_match(self, user, accuracy, now, view, leg):
        """How far you are from the track where a train on this leg could be now,
        if close enough to be on it, and that train's number."""
        line, board, alight = leg
        seg = self.net.segment(line, board, alight)
        if not seg:
            return None
        order = {}
        for j, c in enumerate(seg):
            order.setdefault(c, j)
        widen = min(max(accuracy, 0.0), ACCURACY_CAP)
        trips = view[0]
        best = None
        for number, tline, stops, times in trips:
            if tline != line or times[0] > now + EARLY or times[-1] < now - LATE:
                continue
            if alight not in stops:
                continue
            ai = stops.index(alight)
            for k in range(ai):
                a, b = stops[k], stops[k + 1]
                if a not in order or b not in order or order[a] >= order[b]:
                    continue
                if a not in self.net.pos or b not in self.net.pos:
                    continue
                t0, t1 = times[k], times[k + 1]
                lo, hi = max(t0, now - LATE), min(t1, now + EARLY)
                if lo > hi:
                    continue
                f_lo = (lo - t0) / (t1 - t0) if t1 > t0 else 1.0
                f_hi = (hi - t0) / (t1 - t0) if t1 > t0 else 1.0
                geo = self.net.track(line, a, b)
                if geo is not None:
                    index, sa, sb = geo
                    path = self.net.paths[line][index]
                    s0, s1 = sa + (sb - sa) * f_lo, sa + (sb - sa) * f_hi
                    first = max(min(s0, s1) - ALONG_SLACK, min(sa, sb))
                    last = min(max(s0, s1) + ALONG_SLACK, max(sa, sb))
                    pts = path.piece(first, last)
                    tolerance = ACROSS + widen
                else:
                    pa, pb = self.net.pos[a], self.net.pos[b]
                    length = dist(pa, pb)
                    ext = ALONG_SLACK / length if length > 0 else 0.0
                    f0 = max(f_lo - ext, 0.0)
                    f1 = min(f_hi + ext, 1.0)
                    pts = [(pa[0] + (pb[0] - pa[0]) * f0, pa[1] + (pb[1] - pa[1]) * f0),
                           (pa[0] + (pb[0] - pa[0]) * f1, pa[1] + (pb[1] - pa[1]) * f1)]
                    tolerance = ACROSS_STRAIGHT + widen
                d = polyline_distance(user, pts)
                if d <= tolerance and (best is None or d < best[0]):
                    best = (d, number)
        return best

    def on_train(self, user, accuracy, now, view, routes, ranked):
        guard = min(self.near_radius(ranked), GUARD_MAX)
        for direction, route in (("home", routes[1]), ("work", routes[0])):
            if route is None or len(route) < 2:
                continue
            best = None
            for leg in route[:-1]:
                if leg[1] not in self.net.pos:
                    continue
                if dist(user, self.net.pos[leg[1]]) <= guard:
                    continue
                match = self.leg_match(user, accuracy, now, view, leg)
                if match is not None and (best is None or match[0] < best[0]):
                    best = (match[0], leg[2], match[1])
            if best is not None:
                return best[1], direction, best[2]
        return None

    def zone(self, user, ranked, home, work, cap=None):
        radius = self.near_radius(ranked)
        if cap is not None:
            radius = min(radius, cap)
        best = None
        for code in (home, work):
            if code is None:
                continue
            d = dist(user, self.net.pos[code])
            if d <= radius and (best is None or d < best[0]):
                best = (d, code)
        return None if best is None else best[1]

    def direction(self, day, minute_of_day, home, work):
        if home is not None and work is not None:
            if weekday(day) >= 5 or self.tt.is_holiday(day):
                return "home"
            return "work" if minute_of_day <= WORK_UNTIL else "home"
        return "home" if home is not None else "work"

    def closest(self, user, dest, now, view, ranked):
        if ranked[0][0] <= WALK_RADIUS:
            options = [(c, walk_minutes(d)) for d, c in ranked if d <= WALK_OPTIONS]
        else:
            others = [(d, c) for d, c in ranked if c != dest]
            within = [(d, c) for d, c in others if d <= DRIVE_RADIUS][:DRIVE_MAX]
            if not within:
                within = others[:DRIVE_FALLBACK]
            options = [(c, drive_minutes(d)) for d, c in within]
        scored = []
        for code, minutes in options:
            result = journey(code, now + ceil_int(minutes), dest, view)
            if result is None:
                continue
            scored.append((result[0], minutes, code))
        if not scored:
            return None
        scored.sort()
        return scored[0][2]

    @staticmethod
    def fallback(ranked, home, work, net, user):
        if ranked[0][0] < 400:
            return ranked[0][1]
        saved = [(dist(user, net.pos[c]), i, c) for i, c in enumerate((home, work)) if c is not None]
        if saved:
            return min(saved)[2]
        if ranked[0][0] < 3000:
            return ranked[0][1]
        return None

    def decide(self, user, accuracy, day, now, minute_of_day, home, work, routes=None):
        """The station to open, and why. `now` counts minutes from the start of `day`."""
        home = home if home in self.net.pos else None
        work = work if work in self.net.pos else None
        ranked = self.sorted_stations(user)
        if home is None and work is None:
            return self.fallback(ranked, home, work, self.net, user), "fallback"
        near = self.zone(user, ranked, home, work, NEAR_FIRST_MAX)
        if near is not None:
            return near, "near"
        view = self.tt.view(day)
        if home is not None and work is not None:
            if routes is None:
                routes = self.routes(home, work)
            match = self.on_train(user, accuracy, now, view, routes, ranked)
            if match is not None:
                return match[0], "train-" + match[1]
        near = self.zone(user, ranked, home, work)
        if near is not None:
            return near, "near"
        dest = home if self.direction(day, minute_of_day, home, work) == "home" else work
        code = self.closest(user, dest, now, view, ranked)
        if code is not None:
            return code, "closest-" + ("home" if dest == home else "work")
        return self.fallback(ranked, home, work, self.net, user), "fallback"


# Situations for the Swift check.

def latlon(p):
    return (p[1] / METRES_PER_DEGREE, p[0] / (COS_REF * METRES_PER_DEGREE))


def random_situations(net, tt, planner, count, seed):
    rng = random.Random(seed)
    days = sorted(tt.days)
    codes = net.codes
    out = []
    pairs_routes = {}
    while len(out) < count:
        home, work = rng.sample(codes, 2)
        kind = rng.random()
        if kind < 0.08:
            home = None
        elif kind < 0.16:
            work = None
        elif kind < 0.2:
            home = work = None
        day = rng.choice(days)
        now = rng.randrange(0, 1440)
        where = rng.random()
        if where < 0.3:
            # Around a station.
            base = net.pos[rng.choice(codes)]
            r = rng.choice([150, 600, 1100, 2500, 6000])
            angle = rng.random() * 2 * math.pi
            p = (base[0] + math.cos(angle) * r * rng.random(), base[1] + math.sin(angle) * r * rng.random())
        elif where < 0.55 and home is not None and work is not None:
            # On (or beside) a train of the commute.
            key = (home, work)
            if key not in pairs_routes:
                pairs_routes[key] = planner.routes(home, work)
            p = None
            view = tt.view(day)
            legs = [l for r in pairs_routes[key] if r for l in r]
            if legs:
                line, board, alight = rng.choice(legs)
                running = []
                for number, tline, stops, times in view[0]:
                    if tline == line and times[0] <= now <= times[-1]:
                        for k in range(len(stops) - 1):
                            if times[k] <= now <= times[k + 1]:
                                running.append((stops[k], stops[k + 1], times[k], times[k + 1]))
                if running:
                    a, b, t0, t1 = rng.choice(running)
                    late = rng.choice([0, 0, 1, 2, 3, 5, 8])
                    at = max(t0, now - late)
                    f = (at - t0) / (t1 - t0) if t1 > t0 else 1.0
                    geo = net.track(line, a, b)
                    if geo:
                        index, sa, sb = geo
                        p = net.paths[line][index].point_at(sa + (sb - sa) * f)
                    else:
                        pa, pb = net.pos[a], net.pos[b]
                        p = (pa[0] + (pb[0] - pa[0]) * f, pa[1] + (pb[1] - pa[1]) * f)
                    jitter = rng.choice([0, 50, 300, 1200, 2000])
                    p = (p[0] + rng.uniform(-jitter, jitter), p[1] + rng.uniform(-jitter, jitter))
            if p is None:
                continue
        elif where < 0.8:
            # Beside the track somewhere.
            line = rng.choice(sorted(net.paths))
            path = rng.choice(net.paths[line])
            q = path.point_at(rng.random() * path.cum[-1])
            off = rng.choice([0, 100, 400, 1000, 2500])
            p = (q[0] + rng.uniform(-off, off), q[1] + rng.uniform(-off, off))
        else:
            # Anywhere in the network's area.
            lat = rng.uniform(43.15, 44.45)
            lon = rng.uniform(-80.7, -78.8)
            p = xy(lat, lon)
        lat, lon = latlon(p)
        p = xy(lat, lon)
        accuracy = rng.choice([5.0, 16.0, 35.0, 65.0, 165.0, 1414.0])
        minute_of_day = clock_time(day, now)
        station, reason = planner.decide(p, accuracy, day, now, minute_of_day, home, work)
        out.append({"home": home, "work": work, "lat": lat, "lon": lon, "accuracy": accuracy,
                    "day": day, "minute": now, "minuteOfDay": minute_of_day,
                    "station": station, "reason": reason})
    return out


def e2e_cases(net, tt, planner):
    """Everyday situations for a made-up commuter: home Guelph, work Mimico (the
    Kitchener line into Union, then Lakeshore West back out)."""
    home, work = "GL", "MI"
    weekday_day = tt.typical_weekday()
    saturday = min((d for d in tt.days if weekday(d) == 5), default=None)
    routes = planner.routes(home, work)
    cases = [
        ("mississauga-morning", home, work, 43.652, -79.638, weekday_day, 7 * 60 + 30),
        ("mississauga-evening", home, work, 43.652, -79.638, weekday_day, 17 * 60 + 30),
        ("near-home", home, work, 43.5500, -80.2550, weekday_day, 8 * 60),
        ("union-evening", home, work, 43.6453, -79.3806, weekday_day, 17 * 60 + 40),
        ("no-home-or-work", None, None, 43.6453, -79.3806, weekday_day, 9 * 60),
    ]
    if saturday:
        cases.append(("mississauga-saturday", home, work, 43.652, -79.638, saturday, 10 * 60))
    # Riding a Kitchener-line train towards Union in the morning rush, past Georgetown.
    view = tt.view(weekday_day)
    for now in range(7 * 60, 9 * 60, 5):
        found = None
        for number, line, stops, times in view[0]:
            if line != "KI" or "UN" not in stops or "GE" not in stops:
                continue
            for k in range(stops.index("GE"), stops.index("UN") - 2):
                if times[k] < now < times[k + 1]:
                    geo = net.track(line, stops[k], stops[k + 1])
                    if geo:
                        index, sa, sb = geo
                        f = (now - times[k]) / (times[k + 1] - times[k])
                        found = latlon(net.paths[line][index].point_at(sa + (sb - sa) * f))
                    break
            if found:
                break
        if found:
            cases.append(("on-train-to-work", home, work, found[0], found[1], weekday_day, now))
            break
    rows = []
    for name, h, w, lat, lon, day, minute in cases:
        station, reason = planner.decide(xy(lat, lon), 10.0, day, minute, clock_time(day, minute), h, w,
                                         routes if (h, w) == (home, work) else None)
        when = datetime.datetime.fromtimestamp(day_start(day) + minute * 60, TORONTO).isoformat()
        rows.append("\t".join([name, h or "-", w or "-", f"{lat:.6f}", f"{lon:.6f}", when,
                               station or "none", reason]))
    return rows


def main():
    args = sys.argv[1:]
    if args and args[0] == "--e2e":
        network_path, schedule_path, out_path = args[1:]
        net = Network(json.load(open(network_path)))
        tt = Timetable(json.load(open(schedule_path)))
        rows = e2e_cases(net, tt, Planner(net, tt))
        open(out_path, "w").write("\n".join(rows) + "\n")
        print("\n".join(rows))
        return
    count, seed = 3000, 1
    if "--count" in args:
        i = args.index("--count")
        count = int(args[i + 1])
        del args[i:i + 2]
    if "--seed" in args:
        i = args.index("--seed")
        seed = int(args[i + 1])
        del args[i:i + 2]
    network_path, schedule_path, out_path = args
    net = Network(json.load(open(network_path)))
    tt = Timetable(json.load(open(schedule_path)))
    planner = Planner(net, tt)
    situations = random_situations(net, tt, planner, count, seed)
    routes = {}
    for s in situations:
        if s["home"] and s["work"]:
            key = s["home"] + "|" + s["work"]
            if key not in routes:
                to_work, to_home = planner.routes(s["home"], s["work"])
                routes[key] = {"toWork": to_work, "toHome": to_home}
    # Calendar arithmetic and clocks, including both DST changes of a few years.
    calendar = []
    for n in range(0, 1600, 7):
        day = shift_day("20240101", n)
        calendar.append({"day": day, "weekday": weekday(day),
                         "next": shift_day(day, 1), "previous": shift_day(day, -1), "later": shift_day(day, 45)})
    clocks = []
    start = datetime.datetime(2026, 3, 7, tzinfo=datetime.timezone.utc).timestamp()
    for spot in (start, start + 238 * 86400, start + 364 * 86400, start + 602 * 86400):
        for k in range(0, 4 * 24 * 60, 37):
            clocks.append({"utc": spot + k * 60 + 17, **clock_at(spot + k * 60 + 17)})
    json.dump({"generated": tt.generated, "typicalDay": tt.typical_weekday(),
               "routes": routes, "situations": situations, "calendar": calendar, "clocks": clocks},
              open(out_path, "w"), indent=0)
    tally = {}
    for s in situations:
        tally[s["reason"]] = tally.get(s["reason"], 0) + 1
    print(f"{len(situations)} situations, typical weekday {tt.typical_weekday()}: {tally}")


if __name__ == "__main__":
    main()
