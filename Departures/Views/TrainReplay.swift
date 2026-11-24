import Foundation
import Observation

/// A trip's run along its stops, measured along the track: where each stop is, in
/// metres from the first, and the track between them.
struct TrainRun {
    typealias Point = TrackGeometry.Point

    let codes: [String]
    /// The track from each stop to the next (nil where there's none to measure).
    let paths: [CommutePlanner.Path?]
    /// How far along the run each stop is, in metres.
    let starts: [Double]

    init(codes: [String], segment: (String, String) -> CommutePlanner.Path?) {
        self.codes = codes
        var paths: [CommutePlanner.Path?] = []
        var starts: [Double] = [0]
        for index in 0..<max(codes.count - 1, 0) {
            let path = segment(codes[index], codes[index + 1])
            paths.append(path)
            starts.append(starts[index] + (path?.cumulative.last ?? 0))
        }
        self.paths = paths
        self.starts = starts
    }

    var length: Double { starts.last ?? 0 }

    /// The stretch of track (by its first stop) that `distance` falls in.
    func segment(at distance: Double) -> Int {
        var index = 0
        while index + 1 < paths.count, starts[index + 1] <= distance { index += 1 }
        return index
    }

    /// The point `distance` metres along the run, and the way the train is going
    /// there (at a station, the way it carries on).
    func point(at distance: Double) -> (point: Point, heading: Double?)? {
        guard !paths.isEmpty else { return nil }
        let index = segment(at: distance)
        guard let path = paths[index] else { return nil }
        let along = min(max(distance - starts[index], 0), path.cumulative.last ?? 0)
        return (path.point(at: along), Self.heading(on: path, at: along))
    }

    /// The direction of travel at `along` metres into a stretch of track, across
    /// 50 m of it, in degrees clockwise from north.
    static func heading(on path: CommutePlanner.Path, at along: Double) -> Double? {
        let length = path.cumulative.last ?? 0
        let a = path.point(at: max(0, min(along, length - 25)))
        let b = path.point(at: min(length, max(along, 25) + 25))
        guard a.x != b.x || a.y != b.y else { return nil }
        let degrees = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// A report further than this from the run's track, in metres, isn't on it (a
    /// yard, a detour): the train is drawn where the report has it, off its line.
    static let onTrack = 250.0

    /// A train this far short of a station's own spot on the line, in metres, is
    /// still heading for that station, not the next (it may be at its platform).
    static let platform = 150.0

    /// Where one live report has the train: the point of the run's track nearest
    /// the position it gives, how far along the run that is, and how far off the
    /// track the position is. Nothing but that position places it: not the
    /// station's own spot when GO says it's standing there (a train can stand a
    /// couple of hundred metres from it), and not the stop GO names, which only
    /// says which stop it's at or heading for; when that isn't one of this run's
    /// (a signal, a junction, none given), it's the next one along from where the
    /// train is. Nil only when the run has no track to go by.
    func place(_ report: LiveTrain, from hint: Int = 0) -> TrainReplay.Sample? {
        let position = TrackGeometry.point(report.coordinate)
        var best: (distance: Double, off: Double)?
        for index in paths.indices {
            guard let path = paths[index] else { continue }
            let hit = path.project(position)
            if let current = best, current.off <= hit.distance { continue }
            best = (starts[index] + hit.arc, hit.distance)
        }
        guard let nearest = best else { return nil }
        var stop = starts.firstIndex(where: { $0 > nearest.distance - Self.platform }) ?? max(starts.count - 1, 0)
        var isAt = false
        if let fix = report.fix(in: codes, from: hint), starts.indices.contains(fix.index) {
            stop = fix.index
            isAt = fix.isAt
        }
        return TrainReplay.Sample(time: report.time.timeIntervalSinceReferenceDate, distance: nearest.distance,
                                  off: nearest.off, stop: stop, isAt: isAt)
    }
}

/// Where a train is along its run: exactly where its latest live report has it.
///
/// The GPS position Metrolinx reports for a train is the only thing the map takes
/// as true. Nothing is guessed between GO's reports (one about every 15 seconds, 5
/// to 25 seconds old by the time the app has it) or past the latest one, nothing
/// comes from the timetable, and nothing from where your phone is (not even on
/// board): the train is drawn where GO last had it, and goes to where the next
/// report has it, in one quick step, as soon as that comes in. Without a recent
/// report it isn't drawn at all.
enum TrainReplay {
    /// One report, as a place along the run.
    struct Sample {
        /// Seconds since 2001.
        let time: Double
        /// Metres along the run: the point of its track nearest the report's position.
        let distance: Double
        /// How far the report's position is from that point, in metres.
        let off: Double
        /// The stop it's at or heading for.
        let stop: Int
        let isAt: Bool
    }

    /// Where the latest report has the train.
    struct Position {
        /// Metres along the run.
        let distance: Double
        /// Metres per second: what it covered between its last two reports (nil
        /// without two to measure it by).
        let speed: Double?
        /// The stop it's at or heading for.
        let stop: Int
        let isAt: Bool
        /// Where the report has it, when that's away from the run's track: the train
        /// is drawn there, not on its line, heading the way the report says.
        var away: TrackGeometry.Point? = nil
        var course: Double? = nil
    }

    /// A train that moved less than this between two reports, in metres, is
    /// standing: GPS wobbles by a few metres.
    static let stirring = 15.0
    /// Two reports closer together than this, in seconds, say nothing of its speed.
    static let apart = 5.0

    /// Where the train is along `run` by its reports (oldest first): where the
    /// latest has it, with how fast it went between the last two. Nil without one.
    ///
    /// Its speed is only ever measured, from two positions: GO's word that a train
    /// is standing isn't taken for it (its feed says "stopped at" a station for most
    /// of a minute while the train is still pulling in, and "not in motion" for
    /// about as long after it has left).
    static func position(of reports: [LiveTrain], on run: TrainRun) -> Position? {
        var placed: [(sample: Sample, report: LiveTrain)] = []
        for report in reports.suffix(2) {
            guard let sample = run.place(report, from: placed.last?.sample.stop ?? 0) else { continue }
            if let last = placed.last, sample.time <= last.sample.time { continue }
            placed.append((sample: sample, report: report))
        }
        guard let last = placed.last else { return nil }
        let sample = last.sample
        var speed: Double?
        if placed.count >= 2 {
            let before = placed[placed.count - 2].sample
            let span = sample.time - before.time
            if span >= apart, sample.off <= TrainRun.onTrack, before.off <= TrainRun.onTrack {
                let moved = abs(sample.distance - before.distance)
                speed = moved < stirring ? 0 : moved / span
            }
        }
        var position = Position(distance: sample.distance, speed: speed, stop: sample.stop, isAt: sample.isAt)
        if sample.off > TrainRun.onTrack {
            position.away = TrackGeometry.point(last.report.coordinate)
            position.course = last.report.course
        }
        return position
    }
}

/// How fast each train is going, by its last two live reports: the map notes it as
/// it draws each train (see NetworkMapView), and works it out too for a train whose
/// stops are open but which it doesn't draw; the trip's stops show it. Never a
/// guess, and never your phone's speed: none is shown for a train with nothing to
/// measure it by.
@MainActor
@Observable
final class TrainMotion {
    static let shared = TrainMotion()

    private init() {}

    /// Metres per second, by trip number, to the nearest km/h (so it only changes
    /// when the figure shown does).
    private(set) var speeds: [String: Double] = [:]
    @ObservationIgnored private var noted: [String: Date] = [:]

    /// A train whose stops are open: what the map needs to work out its speed.
    struct Watched {
        let line: String
        let codes: [String]
        let times: [Date?]
        var count: Int
    }

    /// The trains whose stops are open, by trip number.
    @ObservationIgnored private(set) var watched: [String: Watched] = [:]

    func watch(_ number: String, line: String, codes: [String], times: [Date?]) {
        let count = (watched[number]?.count ?? 0) + 1
        watched[number] = Watched(line: line, codes: codes, times: times, count: count)
    }

    /// A watched train's stops have new times (it's running late, say).
    func retime(_ number: String, times: [Date?]) {
        guard let current = watched[number] else { return }
        watched[number] = Watched(line: current.line, codes: current.codes, times: times, count: current.count)
    }

    func unwatch(_ number: String) {
        guard let current = watched[number] else { return }
        if current.count > 1 {
            watched[number]?.count = current.count - 1
        } else {
            watched[number] = nil
        }
    }

    /// A train is going this fast (nil: nothing says how fast, or it isn't in service).
    func note(_ number: String, speed: Double?, at now: Date) {
        guard let speed else {
            if speeds[number] != nil { speeds[number] = nil }
            noted[number] = nil
            return
        }
        noted[number] = now
        let rounded = (max(speed, 0) * 3.6).rounded() / 3.6
        if speeds[number] != rounded { speeds[number] = rounded }
    }

    /// How fast a train is going, as last noted (in the last few seconds).
    func speed(of number: String, at now: Date = Date()) -> Double? {
        guard let speed = speeds[number], let noted = noted[number], now.timeIntervalSince(noted) < 4 else {
            return nil
        }
        return speed
    }
}
