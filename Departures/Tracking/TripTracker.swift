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

    /// Where the train should be now, along the track, from its stop times.
    func position(at now: Date, on geometry: TrackGeometry) -> TrackGeometry.Point? {
        let codes = stopCodes
        switch state(at: now) {
        case .waiting:
            return codes.first.flatMap { geometry.station($0) }
        case .moving(let from, let fraction):
            guard from + 1 < codes.count else { return nil }
            return geometry.point(line: lineCode, from: codes[from], to: codes[from + 1], fraction: fraction)
        case .arrived:
            return codes.last.flatMap { geometry.station($0) }
        case .unknown:
            return nil
        }
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
        set(TrackedTrip(row: selection.row, boardingCode: codes[boarding], boardingIndex: boarding,
                         destinationIndex: destination, stops: detail.stops, source: detail.source,
                         startedAt: Date()))
    }

    func stop() {
        set(nil)
    }

    func isTracking(_ row: BoardRow) -> Bool {
        trip?.matches(row) ?? false
    }

    /// Stops tracking a while after the train reaches your stop.
    func dropIfFinished(now: Date = Date()) {
        guard let trip else { return }
        let end = trip.arrival ?? trip.startedAt.addingTimeInterval(4 * 3600)
        if now > end.addingTimeInterval(Self.linger) {
            set(nil)
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
