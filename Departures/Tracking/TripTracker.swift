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

    var lineCode: String { row.lineCode }
    var tripNumber: String { row.tripNumber }
    var stopCodes: [String] { stops.map(\.code) }
    var destinationCode: String { stops[destinationIndex].code }

    private func time(_ index: Int) -> Date? {
        guard stops.indices.contains(index) else { return nil }
        return stops[index].expected ?? stops[index].time
    }

    /// When it leaves your station.
    var departure: Date? { time(boardingIndex) }
    /// When it reaches your stop.
    var arrival: Date? { time(destinationIndex) }

    func state(at now: Date) -> TrainState {
        TrainState(stops: stops, now: now)
    }

    /// What's next for you: waiting for it to leave your station, riding to your
    /// stop, or there.
    enum Phase: Equatable {
        case departs(Date)
        case arrives(Date)
        case arrived
    }

    func phase(at now: Date) -> Phase {
        if let departure, now < departure { return .departs(departure) }
        if let arrival, now < arrival { return .arrives(arrival) }
        return .arrived
    }

    /// Whether this is the train a board row shows (from any station's board).
    func matches(_ other: BoardRow) -> Bool {
        other.tripNumber == row.tripNumber
            && abs(other.scheduled.timeIntervalSince(row.scheduled)) < 6 * 3600
    }
}

/// The one trip being tracked, if any. Kept across launches until a while after
/// the train reaches your stop.
@MainActor
@Observable
final class TripTracker {
    static let shared = TripTracker()

    private(set) var trip: TrackedTrip?

    private static let storageKey = "trackedTrip"
    /// How long after reaching your stop the trip stays tracked.
    static let linger: TimeInterval = 10 * 60

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
                               startedAt: Date())
        set(trip)
        TripActivityController.shared.start(trip)
    }

    func stop() {
        set(nil)
        TripActivityController.shared.endAll()
    }

    func isTracking(_ row: BoardRow) -> Bool {
        trip?.matches(row) ?? false
    }

    /// Keeps the Live Activity in step (the train leaving your station, then
    /// getting in), and stops tracking a while after the train reaches your stop.
    func dropIfFinished(now: Date = Date()) {
        TripActivityController.shared.sync(trip, now: now)
        guard let trip else { return }
        let end = trip.arrival ?? trip.startedAt.addingTimeInterval(4 * 3600)
        if now > end.addingTimeInterval(Self.linger) {
            set(nil)
        }
    }

    /// Fetches the tracked train's latest times (live ones when there are any),
    /// so the map and the Live Activity keep up with delays.
    func refresh() async {
        guard let trip, let station = RailNetwork.shared.station(trip.boardingCode) else { return }
        let detail = await BoardService.shared.tripDetail(for: trip.row, from: station)
        // Still the same trip, and no worse times than it has (never live ones
        // replaced by the timetable's).
        guard let current = self.trip, current.startedAt == trip.startedAt, detail.source != nil,
              detail.source == .live || current.source != .live
        else { return }
        // Your stations again, in the new list of stops.
        let codes = detail.stops.map(\.code)
        guard let boarding = codes.firstIndex(of: current.boardingCode),
              let destination = codes.indices.first(where: { $0 > boarding && codes[$0] == current.destinationCode })
        else { return }
        let updated = TrackedTrip(row: current.row, boardingCode: current.boardingCode, boardingIndex: boarding,
                                  destinationIndex: destination, stops: detail.stops, source: detail.source,
                                  startedAt: current.startedAt)
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
    }

    private func save() {
        if let trip, let data = try? JSONEncoder().encode(trip) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
