import Foundation

/// Picks the station whose board the app opens on start-up, from where you are,
/// the time, your home and work stations and the GO timetable.
///
/// Pure logic, Foundation only, so it also builds on Linux:
/// tools/commute_reference.py implements the same rules in Python, and the
/// Commute check workflow runs both on the real timetable over thousands of
/// random situations and fails if they ever disagree.
///
/// The rules, in order:
///
/// 1. Within a few km of home or work, and that station is about as close as
///    any: that station.
/// 2. On a train. Home→work and work→home are each planned once on a typical
///    weekday (the most common journey across the morning or evening rush). If
///    a journey has a change, and you're on the track of one of its legs where
///    the timetable puts a train (moving at constant speed along the track
///    between stops, give or take, possibly a few minutes late), the board is
///    the next change station ahead. Home's journey wins a tie.
/// 3. Near home or work at all (further out where stations are far apart):
///    that station. Otherwise the closest station for where you're going: the
///    one you'd reach home (or work) soonest from, counting 5 minutes per
///    change, getting there on foot when a station is within about a 10-minute
///    walk, otherwise by car (estimated from distance, so it's instant, and
///    counted 1.5× so it never chases a train down its line; not downtown,
///    unless you're there already).
///    Weekday mornings (until 12:00) you're going to work; afternoons,
///    evenings, weekends and holidays, home.
/// 4. Otherwise what the app did before: the station you're at, else the
///    nearer of home and work, else a station within 3 km.
struct CommutePlanner: Sendable {
    // MARK: Tuning (the same values as the reference)

    static let minTransfer = 5          // minutes to change trains
    static let changePenalty = 5        // minutes added per change when comparing journeys
    static let maxLegs = 3              // trains per journey (two changes)
    static let walkRadius = 800.0       // metres: a station this close means you're on foot
    static let walkOptions = 1200.0     // metres: stations considered on foot
    static let carFactor = 1.5          // car time counts 1.5x the distance estimate (traffic, parking), so
                                        // driving never seems to catch up with a train further down its line
    static let driveRadius = 25000.0    // metres: stations considered by car...
    static let driveMax = 40            // ...at most this many, nearest first
    static let driveFallback = 3        // with none that close, the nearest few
    static let downtownStation = "UN"   // nobody drives downtown to catch a train: stations within...
    static let downtownRadius = 6000.0  // ...this of Union aren't driven to unless you start there too
    static let nearMin = 1200.0         // metres: always "near" home/work within this...
    static let nearFactor = 1.5         // ...or within 1.5x the distance to the nearest station
    static let nearFirstMax = 5000.0    // metres: beyond this, a train ride outranks being "near"
    static let alongSlack = 1500.0      // metres along the track either side of where the timetable puts a train
    static let across = 350.0           // metres off the track (plus the location's own uncertainty)...
    static let acrossStraight = 1000.0  // ...or off the straight line where no track shape joins two stops
    static let accuracyCap = 1000.0     // metres: the most location uncertainty that widens the track
    static let late = 4                 // minutes a train may be running late
    static let early = 1                // minutes a train may be running early
    static let guardMax = 3000.0        // metres: near a leg's first station, you're waiting, not riding
    static let nearestMax = 25000.0     // metres: with no home or work set, the nearest station opens this far
    static let snap = 600.0             // metres: a station this close to a track path is on it
    static let workUntil = 12 * 60      // minute of the day (inclusive) until which weekdays are work-bound
    static let routeTimesToWork = [360, 390, 420, 450, 480, 510]
    static let routeTimesToHome = [930, 960, 990, 1020, 1050, 1080]
    static let holidayShare = 0.8       // a weekday with fewer trips than this share of the usual is a holiday

    static let metresPerDegree = 6371000 * Double.pi / 180
    /// cos(43.7°): one flat projection for the whole network.
    static let cosRef = 0.7229671459095681
    private static let unreachable = 1_000_000_000

    // MARK: Inputs

    /// A position in metres on a flat projection of southern Ontario.
    struct Point: Sendable, Equatable {
        var x: Double
        var y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        init(latitude: Double, longitude: Double) {
            x = longitude * CommutePlanner.cosRef * CommutePlanner.metresPerDegree
            y = latitude * CommutePlanner.metresPerDegree
        }
    }

    struct Network: Sendable {
        struct Station: Sendable {
            let code: String
            let latitude: Double
            let longitude: Double
        }

        struct Line: Sendable {
            let code: String
            let patterns: [[String]]
            /// Track shapes, each a list of [latitude, longitude].
            let paths: [[[Double]]]
        }

        let stations: [Station]
        let lines: [Line]
    }

    /// The timetable as built by tools/build_schedule.py: trip times are minutes
    /// from the start of the service day (noon minus 12 hours).
    struct Timetable: Sendable {
        struct Trip: Sendable {
            let number: String
            let line: String
            let pattern: Int
            let times: [Int]
        }

        let generated: String
        let patterns: [[String]]
        let trips: [Trip]
        let days: [String: [Int]]

        static let empty = Timetable(generated: "", patterns: [], trips: [], days: [:])
    }

    /// A moment, in the timetable's terms.
    struct Clock: Sendable, Equatable {
        /// The calendar day in Toronto, yyyyMMdd.
        let day: String
        /// Minutes from the start of that day's service (noon minus 12 hours).
        let now: Int
        /// The clock time: hours × 60 + minutes.
        let minuteOfDay: Int
        /// Where yesterday's, today's and tomorrow's service days start, in minutes
        /// from today's (about -1440, 0 and 1440; an hour off around DST changes).
        let shifts: [Int]

        static let zone = TimeZone(identifier: "America/Toronto") ?? TimeZone(secondsFromGMT: -5 * 3600)!

        private static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }

        /// The moment a service day's times count from: noon minus 12 hours, which
        /// stays right across DST changes.
        static func start(of day: String) -> Date? {
            guard let (year, month, date) = CommutePlanner.civil(day) else { return nil }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = date
            components.hour = 12
            guard let noon = calendar.date(from: components) else { return nil }
            return noon.addingTimeInterval(-12 * 3600)
        }

        static func at(_ date: Date) -> Clock? {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day,
                  let hour = parts.hour, let minute = parts.minute
            else { return nil }
            let day = CommutePlanner.dayKey(year, month, dayOfMonth)
            guard let start = start(of: day) else { return nil }
            let now = Int((date.timeIntervalSince(start) / 60).rounded(.down))
            return make(day: day, now: now, start: start, minuteOfDay: hour * 60 + minute)
        }

        /// A moment given as minutes from the start of a service day.
        static func on(day: String, minute: Int) -> Clock? {
            guard let start = start(of: day) else { return nil }
            let date = start.addingTimeInterval(TimeInterval(minute * 60))
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = parts.hour, let minuteOfHour = parts.minute else { return nil }
            return make(day: day, now: minute, start: start, minuteOfDay: hour * 60 + minuteOfHour)
        }

        private static func make(day: String, now: Int, start: Date, minuteOfDay: Int) -> Clock? {
            var shifts: [Int] = []
            for offset in -1...1 {
                guard let other = Self.start(of: CommutePlanner.shift(day, by: offset)) else { return nil }
                shifts.append(Int((other.timeIntervalSince(start) / 60).rounded()))
            }
            return Clock(day: day, now: now, minuteOfDay: minuteOfDay, shifts: shifts)
        }
    }

    // MARK: Outputs

    /// One train of a journey: the line, and where you get on and off.
    struct Leg: Codable, Hashable, Sendable {
        let line: String
        let board: String
        let alight: String
    }

    /// The usual journeys between home and work.
    struct Routes: Codable, Equatable, Sendable {
        let toWork: [Leg]?
        let toHome: [Leg]?
    }

    enum Reason: String, Sendable {
        case near
        case trainHome = "train-home"
        case trainWork = "train-work"
        case closestHome = "closest-home"
        case closestWork = "closest-work"
        case fallback
    }

    struct Choice: Sendable, Equatable {
        let station: String?
        let reason: Reason
    }

    // MARK: Set-up

    let timetable: Timetable
    private let codes: [String]
    private let position: [String: Point]
    private let patterns: [String: [[String]]]
    private let paths: [String: [Path]]
    private let tripCounts: [String: Int]
    private let usualCount: Int
    /// Stations you don't drive to unless you're downtown already.
    private let downtown: Set<String>

    init(network: Network, timetable: Timetable) {
        var position: [String: Point] = [:]
        for station in network.stations where position[station.code] == nil {
            position[station.code] = Point(latitude: station.latitude, longitude: station.longitude)
        }
        self.position = position
        codes = position.keys.sorted()
        if let centre = position[Self.downtownStation] {
            downtown = Set(position.filter { Self.distance($0.value, centre) <= Self.downtownRadius }.keys)
        } else {
            downtown = []
        }

        var patterns: [String: [[String]]] = [:]
        var paths: [String: [Path]] = [:]
        for line in network.lines {
            patterns[line.code] = line.patterns
            paths[line.code] = line.paths.compactMap { coordinates -> Path? in
                guard coordinates.count >= 2 else { return nil }
                let points = coordinates.compactMap { pair -> Point? in
                    guard pair.count == 2 else { return nil }
                    return Point(latitude: pair[0], longitude: pair[1])
                }
                return points.count == coordinates.count ? Path(points) : nil
            }
        }
        self.patterns = patterns
        self.paths = paths

        self.timetable = timetable
        tripCounts = timetable.days.mapValues(\.count)
        let weekdayCounts = timetable.days.keys
            .filter { (Self.weekday($0) ?? 7) < 5 }
            .compactMap { timetable.days[$0]?.count }
            .sorted()
        usualCount = weekdayCounts.isEmpty ? 0 : weekdayCounts[weekdayCounts.count / 2]
    }

    // MARK: Deciding

    /// The station to open, and why.
    /// - Parameters:
    ///   - accuracy: how uncertain the location is, in metres.
    ///   - routes: the home↔work journeys from `routes(home:work:)`, if already worked out.
    func decide(user: Point, accuracy: Double, clock: Clock, home: String?, work: String?,
                routes: Routes? = nil) -> Choice {
        let home = home.flatMap { position[$0] == nil ? nil : $0 }
        let work = work.flatMap { position[$0] == nil ? nil : $0 }
        let ranked = rankedStations(user)
        guard !ranked.isEmpty else { return Choice(station: nil, reason: .fallback) }
        if home == nil && work == nil {
            return Choice(station: fallback(user: user, ranked: ranked, home: home, work: work), reason: .fallback)
        }
        if let near = zone(user: user, ranked: ranked, home: home, work: work, cap: Self.nearFirstMax) {
            return Choice(station: near, reason: .near)
        }
        let view = self.view(day: clock.day, shifts: clock.shifts)
        if let home, let work {
            let routes = routes ?? self.routes(home: home, work: work)
            if let match = onTrain(user: user, accuracy: accuracy, now: clock.now, view: view,
                                   routes: routes, ranked: ranked) {
                return Choice(station: match.station, reason: match.homeBound ? .trainHome : .trainWork)
            }
        }
        if let near = zone(user: user, ranked: ranked, home: home, work: work, cap: nil) {
            return Choice(station: near, reason: .near)
        }
        let homeBound = isHomeBound(clock: clock, home: home, work: work)
        if let dest = homeBound ? home : work,
           let code = closest(user: user, dest: dest, now: clock.now, view: view, ranked: ranked) {
            return Choice(station: code, reason: dest == home ? .closestHome : .closestWork)
        }
        return Choice(station: fallback(user: user, ranked: ranked, home: home, work: work), reason: .fallback)
    }

    /// The usual journeys between home and work, on a typical weekday: the most
    /// common best journey across the morning (to work) or evening (home) rush.
    func routes(home: String, work: String) -> Routes {
        guard let day = typicalWeekday(), let clock = Clock.on(day: day, minute: 0) else {
            return Routes(toWork: nil, toHome: nil)
        }
        let view = self.view(day: day, shifts: clock.shifts)

        func vote(_ origin: String, _ dest: String, _ samples: [Int]) -> [Leg]? {
            var counts: [[Leg]: Int] = [:]
            var first: [[Leg]: Int] = [:]
            for (index, start) in samples.enumerated() {
                guard let journey = journey(from: origin, at: start, to: dest, in: view) else { continue }
                let key = journey.legs.map { leg -> Leg in
                    let trip = view.trips[leg.trip]
                    return Leg(line: trip.line, board: trip.stops[leg.board], alight: trip.stops[leg.alight])
                }
                if key.isEmpty { continue }
                counts[key, default: 0] += 1
                if first[key] == nil { first[key] = index }
            }
            return counts.keys.min { a, b in
                (-counts[a]!, a.count, first[a]!) < (-counts[b]!, b.count, first[b]!)
            }
        }

        return Routes(toWork: vote(home, work, Self.routeTimesToWork),
                      toHome: vote(work, home, Self.routeTimesToHome))
    }

    // MARK: The rules

    private struct Ranked {
        let distance: Double
        let code: String
    }

    private func rankedStations(_ user: Point) -> [Ranked] {
        codes
            .map { Ranked(distance: Self.distance(user, position[$0]!), code: $0) }
            .sorted { ($0.distance, $0.code) < ($1.distance, $1.code) }
    }

    private func nearRadius(_ ranked: [Ranked]) -> Double {
        max(Self.nearMin, Self.nearFactor * ranked[0].distance)
    }

    private func zone(user: Point, ranked: [Ranked], home: String?, work: String?, cap: Double?) -> String? {
        var radius = nearRadius(ranked)
        if let cap { radius = min(radius, cap) }
        var best: (distance: Double, code: String)?
        for code in [home, work] {
            guard let code, let point = position[code] else { continue }
            let d = Self.distance(user, point)
            if d <= radius, best == nil || d < best!.distance {
                best = (d, code)
            }
        }
        return best?.code
    }

    private func isHomeBound(clock: Clock, home: String?, work: String?) -> Bool {
        if home != nil && work != nil {
            if let weekday = Self.weekday(clock.day), weekday >= 5 { return true }
            if isHoliday(clock.day) { return true }
            return clock.minuteOfDay > Self.workUntil
        }
        return home != nil
    }

    private func closest(user: Point, dest: String, now: Int, view: View, ranked: [Ranked]) -> String? {
        var options: [(code: String, minutes: Double)]
        if ranked[0].distance <= Self.walkRadius {
            options = ranked.filter { $0.distance <= Self.walkOptions }.map { ($0.code, Self.walkMinutes($0.distance)) }
        } else {
            let startsDowntown = position[Self.downtownStation].map { Self.distance(user, $0) <= Self.downtownRadius } ?? true
            let others = ranked.filter { $0.code != dest && (startsDowntown || !downtown.contains($0.code)) }
            var within = Array(others.filter { $0.distance <= Self.driveRadius }.prefix(Self.driveMax))
            if within.isEmpty { within = Array(others.prefix(Self.driveFallback)) }
            options = within.map { ($0.code, Self.driveMinutes($0.distance)) }
        }
        // Nearest first: once just getting to a station takes until the best score so
        // far, it and every station after it can't win.
        var best: (score: Int, minutes: Double, code: String)?
        for option in options {
            let ready = now + Int(option.minutes.rounded(.up))
            if let best, ready >= best.score { break }
            guard let journey = journey(from: option.code, at: ready, to: dest, in: view) else { continue }
            let candidate = (score: journey.score, minutes: option.minutes, code: option.code)
            if best == nil || candidate < best! { best = candidate }
        }
        return best?.code
    }

    private func fallback(user: Point, ranked: [Ranked], home: String?, work: String?) -> String? {
        if ranked[0].distance < 400 { return ranked[0].code }
        var saved: (distance: Double, order: Int, code: String)?
        for (order, code) in [home, work].enumerated() {
            guard let code, let point = position[code] else { continue }
            let candidate = (distance: Self.distance(user, point), order: order, code: code)
            if saved == nil || candidate < saved! { saved = candidate }
        }
        if let saved { return saved.code }
        if ranked[0].distance < Self.nearestMax { return ranked[0].code }
        return nil
    }

    // MARK: On a train

    private func onTrain(user: Point, accuracy: Double, now: Int, view: View, routes: Routes,
                         ranked: [Ranked]) -> (station: String, homeBound: Bool, trip: String)? {
        let guardRadius = min(nearRadius(ranked), Self.guardMax)
        for (homeBound, route) in [(true, routes.toHome), (false, routes.toWork)] {
            guard let route, route.count >= 2 else { continue }
            var best: (distance: Double, station: String, trip: String)?
            for leg in route.dropLast() {
                guard let board = position[leg.board] else { continue }
                if Self.distance(user, board) <= guardRadius { continue }
                if let match = legMatch(user: user, accuracy: accuracy, now: now, view: view, leg: leg),
                   best == nil || match.distance < best!.distance {
                    best = (match.distance, leg.alight, match.trip)
                }
            }
            if let best { return (best.station, homeBound, best.trip) }
        }
        return nil
    }

    /// How far you are from the track where a train on this leg could be now, if
    /// close enough to be on it, and that train's number.
    private func legMatch(user: Point, accuracy: Double, now: Int, view: View,
                          leg: Leg) -> (distance: Double, trip: String)? {
        let run = segment(leg.line, leg.board, leg.alight)
        if run.isEmpty { return nil }
        var order: [String: Int] = [:]
        for (index, code) in run.enumerated() where order[code] == nil {
            order[code] = index
        }
        let widen = min(max(accuracy, 0), Self.accuracyCap)
        var best: (distance: Double, trip: String)?
        for trip in view.trips {
            guard trip.line == leg.line,
                  trip.times[0] <= now + Self.early,
                  trip.times[trip.times.count - 1] >= now - Self.late,
                  let alightIndex = trip.stops.firstIndex(of: leg.alight)
            else { continue }
            for k in 0..<alightIndex {
                let a = trip.stops[k], b = trip.stops[k + 1]
                guard let orderA = order[a], let orderB = order[b], orderA < orderB,
                      let pa = position[a], let pb = position[b]
                else { continue }
                let t0 = trip.times[k], t1 = trip.times[k + 1]
                let lo = max(t0, now - Self.late), hi = min(t1, now + Self.early)
                if lo > hi { continue }
                let fLo = t1 > t0 ? Double(lo - t0) / Double(t1 - t0) : 1.0
                let fHi = t1 > t0 ? Double(hi - t0) / Double(t1 - t0) : 1.0
                let points: [Point]
                let tolerance: Double
                if let geo = track(leg.line, a, b), let path = paths[leg.line]?[geo.path] {
                    let s0 = geo.sa + (geo.sb - geo.sa) * fLo
                    let s1 = geo.sa + (geo.sb - geo.sa) * fHi
                    let first = max(min(s0, s1) - Self.alongSlack, min(geo.sa, geo.sb))
                    let last = min(max(s0, s1) + Self.alongSlack, max(geo.sa, geo.sb))
                    points = path.piece(first, last)
                    tolerance = Self.across + widen
                } else {
                    let length = Self.distance(pa, pb)
                    let ext = length > 0 ? Self.alongSlack / length : 0.0
                    let f0 = max(fLo - ext, 0.0)
                    let f1 = min(fHi + ext, 1.0)
                    points = [
                        Point(x: pa.x + (pb.x - pa.x) * f0, y: pa.y + (pb.y - pa.y) * f0),
                        Point(x: pa.x + (pb.x - pa.x) * f1, y: pa.y + (pb.y - pa.y) * f1),
                    ]
                    tolerance = Self.acrossStraight + widen
                }
                let d = Self.distance(user, toPolyline: points)
                if d <= tolerance, best == nil || d < best!.distance {
                    best = (d, trip.number)
                }
            }
        }
        return best
    }

    /// The track shape both stations sit on, and their positions along it.
    private func track(_ line: String, _ a: String, _ b: String) -> (path: Int, sa: Double, sb: Double)? {
        guard let pa = position[a], let pb = position[b] else { return nil }
        var best: (score: Double, path: Int, sa: Double, sb: Double)?
        for (index, path) in (paths[line] ?? []).enumerated() {
            let ra = path.project(pa), rb = path.project(pb)
            if ra.distance <= Self.snap && rb.distance <= Self.snap {
                let score = ra.distance + rb.distance
                if best == nil || score < best!.score {
                    best = (score, index, ra.arc, rb.arc)
                }
            }
        }
        return best.map { ($0.path, $0.sa, $0.sb) }
    }

    /// The stations from board to alight in travel order: the longest such run on any pattern.
    private func segment(_ line: String, _ board: String, _ alight: String) -> [String] {
        var best: [String] = []
        for pattern in patterns[line] ?? [] {
            guard let i = pattern.firstIndex(of: board), let j = pattern.firstIndex(of: alight) else { continue }
            if i < j && j - i + 1 > best.count {
                best = Array(pattern[i...j])
            }
        }
        return best
    }

    // MARK: Journeys

    struct View: Sendable {
        struct Trip: Sendable {
            let number: String
            let line: String
            let stops: [String]
            let times: [Int]
        }

        struct Connection: Sendable {
            let dep: Int
            let arr: Int
            let trip: Int
            let k: Int
        }

        var trips: [Trip] = []
        var connections: [Connection] = []
    }

    /// Trips around a calendar day, times in minutes from that day's start.
    func view(day: String, shifts: [Int]) -> View {
        var view = View()
        for (slot, offset) in [-1, 0, 1].enumerated() {
            let shift = slot < shifts.count ? shifts[slot] : 1440 * offset
            for index in timetable.days[Self.shift(day, by: offset)] ?? [] {
                guard index >= 0, index < timetable.trips.count else { continue }
                let trip = timetable.trips[index]
                guard trip.pattern >= 0, trip.pattern < timetable.patterns.count else { continue }
                let stops = timetable.patterns[trip.pattern]
                let count = min(stops.count, trip.times.count)
                guard count >= 2 else { continue }
                view.trips.append(View.Trip(number: trip.number, line: trip.line,
                                            stops: Array(stops.prefix(count)),
                                            times: trip.times.prefix(count).map { $0 + shift }))
            }
        }
        for (t, trip) in view.trips.enumerated() {
            for k in 0..<(trip.stops.count - 1) where trip.times[k + 1] >= trip.times[k] {
                view.connections.append(View.Connection(dep: trip.times[k], arr: trip.times[k + 1], trip: t, k: k))
            }
        }
        view.connections.sort { ($0.dep, $0.arr, $0.trip, $0.k) < ($1.dep, $1.arr, $1.trip, $1.k) }
        return view
    }

    struct Journey {
        /// Arrival plus the change penalty.
        let score: Int
        let arrival: Int
        let legs: [(trip: Int, board: Int, alight: Int)]
    }

    /// The best journey to `dest` leaving `origin` at `ready`: the least arrival plus
    /// the change penalty, over journeys of up to `maxLegs` trains, fewer trains on
    /// ties. A connection scan with one label per number of trains.
    func journey(from origin: String, at ready: Int, to dest: String, in view: View) -> Journey? {
        if origin == dest { return Journey(score: ready, arrival: ready, legs: []) }
        let maxLegs = Self.maxLegs
        let inf = Self.unreachable
        var best = Array(repeating: [String: Int](), count: maxLegs + 1)
        var via = Array(repeating: [String: (trip: Int, board: Int, alight: Int, used: Int)](), count: maxLegs + 1)
        best[0][origin] = ready
        var boarded: [Int: [Int?]] = [:]
        var score = inf

        // The first connection leaving at or after `ready`.
        var low = 0, high = view.connections.count
        while low < high {
            let mid = (low + high) / 2
            if view.connections[mid].dep < ready { low = mid + 1 } else { high = mid }
        }

        for c in low..<view.connections.count {
            let connection = view.connections[c]
            if connection.dep > score { break }
            let stops = view.trips[connection.trip].stops
            let a = stops[connection.k]
            var boards = boarded[connection.trip]
            // A train may become boardable with fewer trains further along its run,
            // so keep checking until it's boardable for every count.
            if boards == nil || boards!.dropFirst().contains(where: { $0 == nil }) {
                let transfer = a == origin ? 0 : Self.minTransfer
                var changed = false
                for j in 1...maxLegs {
                    if let boards, boards[j] != nil { continue }
                    if (best[j - 1][a] ?? inf) + transfer <= connection.dep {
                        if boards == nil { boards = Array(repeating: nil, count: maxLegs + 1) }
                        boards![j] = connection.k
                        changed = true
                    }
                }
                if changed { boarded[connection.trip] = boards }
            }
            guard let boards else { continue }
            let b = stops[connection.k + 1]
            for j in 1...maxLegs {
                if let board = boards[j], connection.arr < (best[j][b] ?? inf) {
                    best[j][b] = connection.arr
                    via[j][b] = (connection.trip, board, connection.k + 1, j)
                }
            }
            if b == dest {
                for j in 1...maxLegs {
                    if let arrival = best[j][dest] {
                        score = min(score, arrival + Self.changePenalty * (j - 1))
                    }
                }
            }
        }

        var choice: Journey?
        for j in 1...maxLegs {
            guard via[j][dest] != nil, let arrival = best[j][dest] else { continue }
            var legs: [(trip: Int, board: Int, alight: Int)] = []
            var stop = dest
            var trains = j
            while trains > 0, let record = via[trains][stop] {
                legs.append((record.trip, record.board, record.alight))
                stop = view.trips[record.trip].stops[record.board]
                trains = record.used - 1
            }
            if stop != origin { continue }
            legs.reverse()
            let total = arrival + Self.changePenalty * (legs.count - 1)
            if choice == nil || (total, legs.count) < (choice!.score, choice!.legs.count) {
                choice = Journey(score: total, arrival: arrival, legs: legs)
            }
        }
        return choice
    }

    // MARK: Days

    private func isHoliday(_ day: String) -> Bool {
        guard let count = tripCounts[day], let weekday = Self.weekday(day), weekday < 5 else { return false }
        return Double(count) < Self.holidayShare * Double(usualCount)
    }

    /// The weekday whose trip count is most common (and not a holiday), earliest first.
    func typicalWeekday() -> String? {
        var normal = timetable.days.keys.filter { (Self.weekday($0) ?? 7) < 5 && !isHoliday($0) }.sorted()
        if normal.isEmpty { normal = timetable.days.keys.sorted() }
        guard !normal.isEmpty else { return nil }
        var tally: [Int: Int] = [:]
        for day in normal { tally[tripCounts[day] ?? 0, default: 0] += 1 }
        guard let count = tally.min(by: { (-$0.value, -$0.key) < (-$1.value, -$1.key) })?.key else { return nil }
        return normal.first { tripCounts[$0] == count }
    }

    /// Monday 0 ... Sunday 6, for a yyyyMMdd day.
    static func weekday(_ day: String) -> Int? {
        guard let (year, month, date) = civil(day) else { return nil }
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        let sundayBased = (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + date) % 7
        return (sundayBased + 6) % 7
    }

    static func civil(_ day: String) -> (Int, Int, Int)? {
        guard day.count == 8, let value = Int(day) else { return nil }
        let year = value / 10000, month = value / 100 % 100, date = value % 100
        guard (1...12).contains(month), (1...31).contains(date) else { return nil }
        return (year, month, date)
    }

    static func dayKey(_ year: Int, _ month: Int, _ date: Int) -> String {
        let digits = String(year * 10000 + month * 100 + date)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// The yyyyMMdd day `offset` days from `day`.
    static func shift(_ day: String, by offset: Int) -> String {
        guard let (year, month, date) = civil(day) else { return day }
        // Days from the civil date (Howard Hinnant's algorithm), shifted, and back.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + date - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468 + offset

        let z = days + 719468
        let era2 = (z >= 0 ? z : z - 146096) / 146097
        let doe2 = z - era2 * 146097
        let yoe2 = (doe2 - doe2 / 1460 + doe2 / 36524 - doe2 / 146096) / 365
        let doy2 = doe2 - (365 * yoe2 + yoe2 / 4 - yoe2 / 100)
        let mp2 = (5 * doy2 + 2) / 153
        let d = doy2 - (153 * mp2 + 2) / 5 + 1
        let m = mp2 < 10 ? mp2 + 3 : mp2 - 9
        let yr = yoe2 + era2 * 400 + (m <= 2 ? 1 : 0)
        return dayKey(yr, m, d)
    }

    // MARK: Geometry

    static func distance(_ p: Point, _ q: Point) -> Double {
        let dx = p.x - q.x
        let dy = p.y - q.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Distance from p to the segment ab, and how far along it (0...1) the closest point is.
    static func project(_ p: Point, onto a: Point, _ b: Point) -> (distance: Double, t: Double) {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let wx = p.x - a.x
        let wy = p.y - a.y
        let vv = vx * vx + vy * vy
        var t = 0.0
        if vv > 0 {
            t = (wx * vx + wy * vy) / vv
            t = min(max(t, 0.0), 1.0)
        }
        let closest = Point(x: a.x + vx * t, y: a.y + vy * t)
        return (distance(p, closest), t)
    }

    static func distance(_ p: Point, toPolyline points: [Point]) -> Double {
        if points.count == 1 { return distance(p, points[0]) }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            let d = project(p, onto: points[i], points[i + 1]).distance
            if d < best { best = d }
        }
        return best
    }

    static func walkMinutes(_ metres: Double) -> Double {
        metres * 1.25 / 1.3 / 60
    }

    static func driveMinutes(_ metres: Double) -> Double {
        let road = metres * 1.35 / 1000
        let local = min(road, 4.0)
        return carFactor * (3 + local / 30 * 60 + max(road - 4, 0.0) / 75 * 60)
    }

    /// A track shape, with the distance along it at each point.
    struct Path: Sendable {
        let points: [Point]
        let cumulative: [Double]

        init(_ points: [Point]) {
            self.points = points
            var cumulative = [0.0]
            for i in 0..<max(points.count - 1, 0) {
                cumulative.append(cumulative[i] + CommutePlanner.distance(points[i], points[i + 1]))
            }
            self.cumulative = cumulative
        }

        /// Distance to the closest point on the path, and how far along the path it is.
        func project(_ p: Point) -> (distance: Double, arc: Double) {
            var best: (distance: Double, arc: Double)?
            for i in 0..<(points.count - 1) {
                let r = CommutePlanner.project(p, onto: points[i], points[i + 1])
                if best == nil || r.distance < best!.distance {
                    best = (r.distance, cumulative[i] + (cumulative[i + 1] - cumulative[i]) * r.t)
                }
            }
            return best ?? (CommutePlanner.distance(p, points[0]), 0)
        }

        func point(at arc: Double) -> Point {
            if points.count == 1 { return points[0] }
            let s = min(max(arc, 0.0), cumulative[cumulative.count - 1])
            var i = 0
            while i < points.count - 2 && cumulative[i + 1] < s { i += 1 }
            let length = cumulative[i + 1] - cumulative[i]
            let u = length <= 0 ? 0.0 : (s - cumulative[i]) / length
            let a = points[i], b = points[i + 1]
            return Point(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }

        /// The stretch of the path between two distances along it.
        func piece(_ s0: Double, _ s1: Double) -> [Point] {
            let lo = min(s0, s1), hi = max(s0, s1)
            var result = [point(at: lo)]
            for i in points.indices where lo < cumulative[i] && cumulative[i] < hi {
                result.append(points[i])
            }
            result.append(point(at: hi))
            return result
        }
    }
}
