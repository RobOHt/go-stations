import Foundation
import Observation

/// A train being followed: its stops and times, where you get on, and where you get off.
struct TrackedTrip: Codable, Equatable, Sendable {
    /// The board row it was tracked from (reopens the trip's details).
    let row: BoardRow
    /// The station whose board it was tracked from.
    let boardingCode: String
    let boardingIndex: Int
    /// Your stop: home or work if the train gets there after you board, otherwise its last stop.
    let destinationIndex: Int
    var stops: [TripDetail.Stop]
    var source: BoardSnapshot.Source?
    let startedAt: Date
    /// Tracked from your station's board: until the train gets there, its Live
    /// Activity counts down to that. (Optional so trips saved before it still load.)
    var startsAtStop: Bool? = nil
    /// Where the train is among the stops, by its latest live report (nil before
    /// the first, or without live data).
    var live: LiveFix? = nil
    /// How late it runs, by its live reports, in seconds (negative: early).
    var liveDelay: Double? = nil

    // A trip planned from search can have changes: the train you're on now is the
    // one above, and the rest are `onward`. At each change the next one takes over
    // (see `changingTrains(at:)`), in the same Live Activity.

    /// The trains after this one, in order (nil or empty: none).
    var onward: [OnwardLeg]? = nil
    /// Which trip it is, as the trip card lists it (nil: tracked from a board).
    var journeyKey: String? = nil
    /// The first train's row, once it has changed trains: its Live Activity's.
    var journeyID: String? = nil
    /// This train's place in the trip (0 for the first), and how many trains there are.
    var legIndex: Int? = nil
    var legCount: Int? = nil
    /// When this train became the one followed.
    var legStartedAt: Date? = nil
    /// Alerts for this trip: before it leaves, before changes, before your stop.
    /// Nil until you say: on if you've allowed them before.
    var alerts: Bool? = nil

    var hasStartingStop: Bool { startsAtStop ?? false }

    /// The Live Activity this trip shows in (the first train's, after a change).
    var activityID: String { journeyID ?? row.id }
    /// A train to change to after this one.
    var hasOnward: Bool { !(onward ?? []).isEmpty }
    /// Where the whole trip ends.
    var finalDestinationCode: String { onward?.last?.destinationCode ?? destinationCode }

    /// How long tracking goes on after the train reaches your stop, when it runs
    /// on well past it.
    static let linger: TimeInterval = 10 * 60

    var lineCode: String { row.lineCode }
    var tripNumber: String { row.tripNumber }
    var stopCodes: [String] { stops.map(\.code) }
    var destinationCode: String { stops[destinationIndex].code }

    private func time(_ index: Int) -> Date? {
        guard stops.indices.contains(index) else { return nil }
        return stops[index].expected ?? stops[index].time
    }

    /// When it leaves your station (when it was seen leaving, once it has).
    var departure: Date? {
        guard stops.indices.contains(boardingIndex) else { return nil }
        return stops[boardingIndex].departed ?? time(boardingIndex)
    }
    /// When it reaches your stop (when it was seen getting there, once it has).
    var arrival: Date? {
        guard stops.indices.contains(destinationIndex) else { return nil }
        return stops[destinationIndex].arrived ?? time(destinationIndex)
    }

    func state(at now: Date) -> TrainState {
        TrainState(stops: stops, now: now, live: live)
    }

    /// Its train has been seen at your stop, or past it.
    var isSeenIn: Bool {
        guard let live else { return false }
        return live.index > destinationIndex || (live.isAt && live.index == destinationIndex)
    }

    /// When tracking stops and the train leaves the map: a minute after it gets to
    /// the end of its run, or a while after it reaches your stop when it runs on
    /// well past it.
    var endsAt: Date? {
        let end = stops.last.flatMap { $0.expected ?? $0.time }?.addingTimeInterval(TrainState.lingerAtEnd)
        let yours = arrival?.addingTimeInterval(Self.linger)
        return [end, yours].compactMap { $0 }.min()
    }

    /// What's next for you: waiting for it to leave your station, riding to your
    /// stop, or there.
    enum Phase: Equatable {
        case departs(Date)
        case arrives(Date)
        case arrived
    }

    func phase(at now: Date) -> Phase {
        if isSeenIn { return .arrived }
        // A fresh live report outranks the times: a train still at (or on its way
        // to) your station hasn't left it, one not yet at your stop isn't in.
        let fresh = live.map { $0.isFresh(at: now) } ?? false
        let notLeft = fresh && (live?.index ?? 0) <= boardingIndex
        if let departure, now < departure || notLeft { return .departs(max(departure, now)) }
        if let arrival, now < arrival || fresh { return .arrives(max(arrival, now)) }
        return .arrived
    }

    /// Whether this is the train a board row shows (from any station's board).
    func matches(_ other: BoardRow) -> Bool {
        other.tripNumber == row.tripNumber
            && abs(other.scheduled.timeIntervalSince(row.scheduled)) < 6 * 3600
    }

    /// The trip as its train's latest live report has it: where the train is among
    /// its stops (standing at one, or on its way to one), when it was seen pulling
    /// in at each and leaving, and its times ahead as late as it's running (it
    /// never leaves a station early, whatever its delay says).
    func following(_ train: LiveTrain, now: Date) -> TrackedTrip {
        guard train.isFresh(at: now), var fix = train.fix(in: stopCodes, from: live?.index ?? 0) else { return self }
        var stops = self.stops
        let before = live
        if let before, before.isAt, before.index == fix.index, !fix.isAt {
            // Creeping along the platform it's at: still there.
            fix = LiveFix(index: fix.index, isAt: true, time: fix.time)
        }
        if let before, before.isAt, before.index < fix.index, stops.indices.contains(before.index),
           stops[before.index].departed == nil {
            stops[before.index].departed = train.time
        }
        let pulledIn = fix.isAt && !(before?.isAt == true && before?.index == fix.index)
        if pulledIn, fix.index > 0, stops.indices.contains(fix.index), stops[fix.index].arrived == nil {
            stops[fix.index].arrived = train.time
        }
        // How late it runs, ignoring small wobbles.
        var delay = liveDelay
        if let reported = train.delay, delay.map({ abs(reported - $0) >= 30 }) ?? true { delay = reported }
        let late = max(0, delay ?? 0)
        // Seen leaving the stop before later than that: the stops ahead are that late too.
        var extra: TimeInterval = 0
        if fix.index > 0, let left = stops[fix.index - 1].departed, let planned = stops[fix.index - 1].time {
            extra = max(0, left.timeIntervalSince(planned) - late)
        }
        for index in stops.indices where index >= fix.index {
            let stop = stops[index]
            guard let planned = stop.time else { continue }
            stops[index] = TripDetail.Stop(index: stop.index, code: stop.code, time: stop.time,
                                           expected: planned.addingTimeInterval(late + extra), platform: stop.platform,
                                           arrived: stop.arrived, departed: stop.departed)
        }
        var next = self
        next.stops = stops
        next.source = .live
        next.live = fix
        next.liveDelay = delay
        return next
    }

    /// New stops and times for the same trip (from a refresh), keeping what was
    /// seen of its train, and the rest of the trip.
    func carrying(_ seen: TrackedTrip) -> TrackedTrip {
        var next = self
        next.onward = seen.onward
        next.journeyKey = seen.journeyKey
        next.journeyID = seen.journeyID
        next.legIndex = seen.legIndex
        next.legCount = seen.legCount
        next.legStartedAt = seen.legStartedAt
        next.alerts = seen.alerts
        for (index, stop) in next.stops.enumerated() {
            guard let old = seen.stops.first(where: { $0.code == stop.code }) else { continue }
            next.stops[index].arrived = old.arrived
            next.stops[index].departed = old.departed
        }
        if let fix = seen.live, seen.stops.indices.contains(fix.index),
           let index = next.stopCodes.firstIndex(of: seen.stops[fix.index].code) {
            next.live = LiveFix(index: index, isAt: fix.isAt, time: fix.time)
        }
        next.liveDelay = seen.liveDelay
        return next
    }

    /// At a change, once the train you're on is in: the trip with the next train
    /// as the one followed, counting down to it getting where you change. Nil
    /// without one.
    func changingTrains(at now: Date) -> TrackedTrip? {
        guard var rest = onward, !rest.isEmpty else { return nil }
        let next = rest.removeFirst()
        let codes = next.stops.map(\.code)
        guard let boarding = codes.firstIndex(of: next.boardingCode),
              let destination = codes.indices.first(where: { $0 > boarding && codes[$0] == next.destinationCode })
        else { return nil }
        var trip = TrackedTrip(row: next.row, boardingCode: next.boardingCode, boardingIndex: boarding,
                               destinationIndex: destination, stops: next.stops, source: next.source,
                               startedAt: startedAt, startsAtStop: true)
        trip.onward = rest
        trip.journeyKey = journeyKey
        trip.journeyID = activityID
        trip.legIndex = (legIndex ?? 0) + 1
        trip.legCount = legCount
        trip.legStartedAt = now
        trip.alerts = alerts
        return trip
    }

    /// Each train of the trip from this one on, as it would be tracked: this one,
    /// then each onward one as it would be once you've changed to it.
    func legsFromHere() -> [TrackedTrip] {
        var legs = [self]
        while let last = legs.last, let next = last.changingTrains(at: last.arrival ?? startedAt) {
            legs.append(next)
        }
        return legs
    }

    /// Where the train should be now, along the track, from its stop times: on
    /// the line, at a station while it stands there.
    func position(at now: Date, on geometry: TrackGeometry) -> TrackGeometry.Point? {
        let codes = stopCodes
        guard codes.count >= 2 else { return codes.first.flatMap { geometry.stop($0) } }
        switch state(at: now) {
        case .waiting:
            return geometry.point(line: lineCode, from: codes[0], to: codes[1], fraction: 0)
        case .moving(let from, let fraction):
            guard from + 1 < codes.count else { return nil }
            return geometry.point(line: lineCode, from: codes[from], to: codes[from + 1], fraction: fraction)
        case .stopped(let at):
            guard at > 0, at < codes.count else { return nil }
            return geometry.point(line: lineCode, from: codes[at - 1], to: codes[at], fraction: 1)
        case .arrived:
            return geometry.point(line: lineCode, from: codes[codes.count - 2], to: codes[codes.count - 1],
                                  fraction: 1)
        case .unknown:
            return nil
        }
    }

    /// Which way the train is heading now, in degrees clockwise from north (the way
    /// it will leave while it waits, the way it came in once it's there).
    func heading(at now: Date, on geometry: TrackGeometry) -> Double? {
        let codes = stopCodes
        guard codes.count >= 2 else { return nil }
        switch state(at: now) {
        case .waiting:
            return geometry.heading(line: lineCode, from: codes[0], to: codes[1], fraction: 0)
        case .moving(let from, let fraction):
            guard from + 1 < codes.count else { return nil }
            return geometry.heading(line: lineCode, from: codes[from], to: codes[from + 1], fraction: fraction)
        case .stopped(let at):
            // The way it will carry on.
            guard at > 0, at < codes.count else { return nil }
            return at + 1 < codes.count
                ? geometry.heading(line: lineCode, from: codes[at], to: codes[at + 1], fraction: 0)
                : geometry.heading(line: lineCode, from: codes[at - 1], to: codes[at], fraction: 1)
        case .arrived:
            return geometry.heading(line: lineCode, from: codes[codes.count - 2], to: codes[codes.count - 1],
                                    fraction: 1)
        case .unknown:
            return nil
        }
    }
}

/// A train you'll change to, on a trip with changes.
struct OnwardLeg: Codable, Equatable, Sendable {
    /// The train as a row on the board of the station you change to it at.
    let row: BoardRow
    let boardingCode: String
    let destinationCode: String
    /// Its stops and times: the timetable's, until it's the train followed.
    let stops: [TripDetail.Stop]
    let source: BoardSnapshot.Source?
}

/// The one trip being tracked, if any. Kept across launches until a while after
/// the train reaches your stop.
@MainActor
@Observable
final class TripTracker {
    static let shared = TripTracker()

    private(set) var trip: TrackedTrip?
    /// Stops tracking right when the trip ends, rather than at the next check.
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private static let storageKey = "trackedTrip"

    private init() {
        #if DEBUG
        if DebugScene.startsUntracked {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
            trip = try? JSONDecoder().decode(TrackedTrip.self, from: data)
        }
        dropIfFinished()
        scheduleExpiry()
    }

    /// Starts following a train from the station whose board it was picked on.
    func track(_ selection: TripSelection, detail: TripDetail, home: String?, work: String?) {
        let codes = detail.stops.map(\.code)
        guard !codes.isEmpty else { return }
        let boarding = codes.firstIndex(of: selection.station.code) ?? 0
        let later = codes.indices.filter { $0 > boarding }
        let destination = later.first { codes[$0] == home || codes[$0] == work } ?? later.last ?? boarding
        let trip = TrackedTrip(row: selection.row, boardingCode: codes[boarding], boardingIndex: boarding,
                               destinationIndex: destination, stops: detail.stops, source: detail.source,
                               startedAt: Date(), startsAtStop: selection.fromBoard)
        set(trip)
        TripActivityController.shared.start(trip)
    }

    /// Starts following a trip planned from search: its first train from where you
    /// get on (`detail`: its stops, live when Metrolinx has them), and at each
    /// change the next, all in one Live Activity.
    func track(_ journey: Journey, row: BoardRow, detail: TripDetail) {
        guard let first = journey.legs.first else { return }
        // The live stops when they have where you get on and off, else the timetable's.
        var stops = detail.stops
        var source = detail.source
        func has(_ list: [TripDetail.Stop]) -> Bool {
            let codes = list.map(\.code)
            guard let board = codes.firstIndex(of: first.boardCode) else { return false }
            return codes[(board + 1)...].contains(first.alightCode)
        }
        if source == nil || !has(stops) {
            let planned = TripPlanner.detail(for: first)
            stops = planned.stops
            source = planned.source
        }
        let codes = stops.map(\.code)
        guard let boarding = codes.firstIndex(of: first.boardCode),
              let destination = codes.indices.first(where: { $0 > boarding && codes[$0] == first.alightCode })
        else { return }
        var trip = TrackedTrip(row: row, boardingCode: first.boardCode, boardingIndex: boarding,
                               destinationIndex: destination, stops: stops, source: source,
                               startedAt: Date(), startsAtStop: true)
        trip.onward = journey.legs.dropFirst().compactMap { leg in
            TripPlanner.row(for: leg).map { row in
                OnwardLeg(row: row, boardingCode: leg.boardCode, destinationCode: leg.alightCode,
                          stops: TripPlanner.detail(for: leg).stops, source: .schedule)
            }
        }
        trip.journeyKey = journey.id
        trip.legIndex = 0
        trip.legCount = journey.legs.count
        set(trip)
        TripActivityController.shared.start(trip)
    }

    /// Alerts for the tracked trip on or off (the trip card asks once it's tracked).
    func setAlerts(_ on: Bool) {
        guard var trip else { return }
        trip.alerts = on
        set(trip)
        TripActivityController.shared.sync(trip)
    }

    func stop() {
        set(nil)
        TripActivityController.shared.endAll()
    }

    func isTracking(_ row: BoardRow) -> Bool {
        trip?.matches(row) ?? false
    }

    /// Keeps the Live Activity in step (the train reaching each stop, then your
    /// stop), and stops tracking once the trip ends (see `TrackedTrip.endsAt`),
    /// unless live reports say the train is still on its way to your stop.
    func dropIfFinished(now: Date = Date()) {
        changeTrainsIfDue(now: now)
        TripActivityController.shared.sync(trip, now: now)
        guard let trip else { return }
        // A train with another after it changes over once it's in (above), whatever.
        if trip.hasOnward { return }
        let running = (trip.live?.isFresh(at: now) ?? false) && !trip.isSeenIn
        if now >= trip.endsAt ?? trip.startedAt.addingTimeInterval(4 * 3600), !running {
            set(nil)
        }
    }

    /// Takes in the tracked train's latest live report (see `TrackedTrip.following`).
    func follow(_ live: LiveTrains) {
        guard let trip, let train = live.train(trip.tripNumber) else { return }
        let updated = trip.following(train, now: Date())
        guard updated != trip else { return }
        set(updated)
        if changeTrainsIfDue(now: Date()) { return }
        TripActivityController.shared.sync(updated)
    }

    /// At a change, once the train you're on is in where you change: the next one
    /// becomes the train followed (its live times fetched right away), in the same
    /// Live Activity. True when it changed.
    @discardableResult
    private func changeTrainsIfDue(now: Date) -> Bool {
        guard let trip, trip.hasOnward, trip.phase(at: now) == .arrived,
              let next = trip.changingTrains(at: now) else { return false }
        set(next)
        TripActivityController.shared.sync(next, now: now)
        Task { await refresh() }
        return true
    }

    /// Fetches the tracked train's latest times (live ones when there are any),
    /// so the map and the Live Activity keep up with delays.
    func refresh() async {
        guard let trip, let station = RailNetwork.shared.station(trip.boardingCode) else { return }
        let detail = await BoardService.shared.tripDetail(for: trip.row, from: station)
        // Still the same trip, and no worse times than it has (never live ones
        // replaced by the timetable's).
        // (Not a train you've since changed from.)
        guard let current = self.trip, current.startedAt == trip.startedAt, current.tripNumber == trip.tripNumber,
              detail.source != nil, detail.source == .live || current.source != .live
        else { return }
        // Your stations again, in the new list of stops.
        let codes = detail.stops.map(\.code)
        guard let boarding = codes.firstIndex(of: current.boardingCode),
              let destination = codes.indices.first(where: { $0 > boarding && codes[$0] == current.destinationCode })
        else { return }
        var updated = TrackedTrip(row: current.row, boardingCode: current.boardingCode, boardingIndex: boarding,
                                  destinationIndex: destination, stops: detail.stops, source: detail.source,
                                  startedAt: current.startedAt, startsAtStop: current.startsAtStop)
            .carrying(current)
        // Live times from its train's position outrank the board's.
        if let train = LiveTrains.shared.train(current.tripNumber) {
            updated = updated.following(train, now: Date())
        }
        guard updated != current else { return }
        set(updated)
        TripActivityController.shared.sync(updated)
        TripActivityController.shared.scheduleRefresh(for: updated)
    }

    /// Run by iOS in the background a while after the train is due at your stop:
    /// catches up on its times and, once it's in, ends the Live Activity, for when
    /// the app isn't opened after the ride.
    func backgroundRefresh() async {
        guard trip != nil else { return }
        await refresh()
        dropIfFinished()
        if let trip, trip.phase(at: Date()) != .arrived {
            TripActivityController.shared.scheduleRefresh(for: trip)
        }
    }

    private func set(_ trip: TrackedTrip?) {
        self.trip = trip
        save()
        scheduleExpiry()
        TripAlerts.shared.update(for: trip)
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        // At a change: when the train's due in, to change over on time.
        let due = trip.flatMap { $0.hasOnward ? $0.arrival?.addingTimeInterval(5) : $0.endsAt }
        guard let end = due else { return }
        expiry = Task { [weak self] in
            let wait = end.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.dropIfFinished()
        }
    }

    private func save() {
        if let trip, let data = try? JSONEncoder().encode(trip) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
