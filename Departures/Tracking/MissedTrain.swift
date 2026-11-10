import CoreLocation
import Foundation

/// Whether you caught the first train of a trip from search, once it has left
/// where you get on (#16). If you're nowhere near the line where it is by then,
/// you missed it: the app says so and stops tracking, so the Live Activity
/// doesn't carry on as if you were on board, and no alerts come for the trip.
///
/// Only trips from search (planned from where you are, to ride), not trains
/// tracked from a board or the map, which may be someone else's. Only the first
/// train: missing a later one is another matter. And only on good evidence: the
/// train seen leaving (or, with nothing live, long after its time), a couple of
/// minutes gone, and a recent, accurate fix well away from the line around it.
/// On the platform, or with no fix to go on, it isn't called missed.
extension TrackedTrip {
    enum Boarding: Equatable {
        /// It hasn't left where you get on yet (or it's not the first train, or
        /// not a trip from search).
        case notYet
        /// Too soon to say, or nothing to go on.
        case unsure
        /// You're by the line where the train is: on it, or near enough to be.
        case caught
        /// It left, and you're nowhere near it.
        case missed
    }

    /// How long after it left before where you are says anything.
    static let missedAfter: TimeInterval = 2 * 60
    /// With nothing live about it, it's taken to have left this long after its
    /// time (long enough for all but a badly late train).
    static let missedWithoutLive: TimeInterval = 10 * 60
    /// Farther than this from the line where the train is, you're not on it.
    static let offTheLine: CLLocationDistance = 1_000
    /// A fix older or rougher than this says nothing.
    static let fixMaxAge: TimeInterval = 3 * 60
    static let fixMaxError: CLLocationDistance = 300

    /// When the first train left where you get on: seen leaving it, or seen past
    /// it; with nothing live, a while after its time. Nil while it hasn't, and
    /// on later trains.
    func leftBoarding(at now: Date) -> Date? {
        guard (legIndex ?? 0) == 0, stops.indices.contains(boardingIndex) else { return nil }
        if let left = stops[boardingIndex].departed { return left }
        if let live, live.index > boardingIndex { return live.time }
        if live?.isFresh(at: now) != true, let departure,
           now.timeIntervalSince(departure) >= Self.missedWithoutLive {
            return departure
        }
        return nil
    }

    /// Whether you caught the first train, by where you are (`location`) once it
    /// has left where you get on.
    func boarding(at now: Date, location: CLLocation?, on geometry: TrackGeometry) -> Boarding {
        guard journeyKey != nil, let left = leftBoarding(at: now) else { return .notYet }
        guard now.timeIntervalSince(left) >= Self.missedAfter, let location,
              now.timeIntervalSince(location.timestamp) < Self.fixMaxAge,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.fixMaxError
        else { return .unsure }
        // The line around the train: from two stops behind where it is (or where it
        // was last reported, if that's further back: held up since, it can't be
        // past its times, but it can't be behind its last report either; never
        // reported, from where you get on) to the next stop. From where you get on
        // while it's just left, not once it's well past there (so someone still on
        // that platform isn't taken to be on it).
        let estimated = trainIndex(at: now)
        let at = max(estimated, boardingIndex + 1)
        let from = max(boardingIndex, min(estimated, live?.index ?? boardingIndex) - 2)
        let to = min(at + 1, stops.count - 1)
        let here = CommutePlanner.Point(latitude: location.coordinate.latitude,
                                        longitude: location.coordinate.longitude)
        var nearest = Double.infinity
        for index in from..<to {
            let points = geometry.segment(line: lineCode, from: stops[index].code, to: stops[index + 1].code)
            if points.count >= 2 {
                nearest = min(nearest, CommutePlanner.Path(points).project(here).distance)
            }
            for code in [stops[index].code, stops[index + 1].code] {
                if let stop = geometry.stop(code) { nearest = min(nearest, hypot(stop.x - here.x, stop.y - here.y)) }
            }
        }
        guard nearest.isFinite else { return .unsure }
        return nearest > Self.offTheLine ? .missed : .caught
    }

    /// The stop the train is at or on its way to now: by its latest live report,
    /// else by its times.
    private func trainIndex(at now: Date) -> Int {
        if let live, live.isFresh(at: now) { return live.index }
        switch state(at: now) {
        case .waiting: return 0
        case .moving(let from, _): return min(from + 1, stops.count - 1)
        case .stopped(let at): return at
        case .arrived: return stops.count - 1
        case .unknown: return live?.index ?? boardingIndex
        }
    }
}
