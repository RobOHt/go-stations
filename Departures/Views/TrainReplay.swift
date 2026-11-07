import Foundation

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

    /// Where one live report puts the train along the run: at the station it's
    /// standing at, or where its position falls on the track to the one it's
    /// heading for. Nil when it doesn't fit (a stop not on this run, or a position
    /// far from its track).
    func measure(_ report: LiveTrain, from hint: Int) -> TrainReplay.Sample? {
        guard let fix = report.fix(in: codes, from: hint), starts.indices.contains(fix.index) else { return nil }
        let time = report.time.timeIntervalSinceReferenceDate
        if fix.isAt { return .init(time: time, distance: starts[fix.index], stop: fix.index, isAt: true) }
        guard fix.index > 0, let path = paths[fix.index - 1] else { return nil }
        let hit = path.project(TrackGeometry.point(report.coordinate))
        guard hit.distance < 1_500 else { return nil }
        let along = min(hit.arc, starts[fix.index] - starts[fix.index - 1])
        return .init(time: time, distance: starts[fix.index - 1] + along, stop: fix.index, isAt: false)
    }

    /// Where a train's times put it along the run (TrainState): standing at a
    /// station, or the right fraction of the way between two.
    func position(of state: TrainState, times: [Date?]) -> TrainReplay.Position? {
        let last = codes.count - 1
        guard last >= 1 else { return nil }
        switch state {
        case .waiting:
            return .init(distance: 0, speed: 0, stop: 0, isAt: true)
        case .moving(let from, let fraction):
            guard from + 1 <= last else { return nil }
            let length = starts[from + 1] - starts[from]
            var speed = 15.0
            if times.indices.contains(from + 1), let start = times[from],
               let end = TrainState.arrival(at: from + 1, times: times), end > start {
                speed = length / end.timeIntervalSince(start)
            }
            return .init(distance: starts[from] + length * min(max(fraction, 0), 1), speed: speed,
                         stop: from + 1, isAt: false)
        case .stopped(let at):
            guard at <= last else { return nil }
            return .init(distance: starts[at], speed: 0, stop: at, isAt: true)
        case .arrived:
            return .init(distance: starts[last], speed: 0, stop: last, isAt: true)
        case .unknown:
            return nil
        }
    }
}

/// Replays a train's live reports a little behind them, so it moves smoothly
/// through every place GO reported it rather than guessing ahead and jumping when
/// the next report comes in.
///
/// Between two reports the train follows a smooth curve through them along the
/// track (monotone cubic: it never goes back or overshoots, and it stands still
/// where it stood). After the latest one it carries on at its pace, slowing to
/// stop at the station it's heading for and never passing it, until the next
/// report comes in.
enum TrainReplay {
    /// One report, as a place along the run.
    struct Sample {
        /// Seconds since 2001.
        let time: Double
        /// Metres along the run.
        var distance: Double
        /// The stop it's at or heading for.
        let stop: Int
        let isAt: Bool
    }

    /// Where the replay has the train.
    struct Position {
        /// Metres along the run.
        let distance: Double
        /// Metres per second.
        let speed: Double
        /// The stop it's at or heading for.
        let stop: Int
        let isAt: Bool
    }

    /// How hard a train usually brakes for a station, in m/s².
    static let braking = 0.7
    /// How long past its latest report a train is carried on before it's held.
    static let ahead: TimeInterval = 45

    /// Where the train was at `date` by its reports (oldest first). Nil when none
    /// of them fits the run.
    static func position(of reports: [LiveTrain], on run: TrainRun, at date: Date) -> Position? {
        var samples: [Sample] = []
        for report in reports {
            guard var sample = run.measure(report, from: samples.last?.stop ?? 0) else { continue }
            if let last = samples.last {
                guard sample.time > last.time else { continue }
                // GPS wobble never takes it back.
                sample.distance = max(sample.distance, last.distance)
            }
            samples.append(sample)
        }
        return position(of: samples, on: run, at: date.timeIntervalSinceReferenceDate)
    }

    static func position(of samples: [Sample], on run: TrainRun, at time: Double) -> Position? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time {
            return Position(distance: first.distance, speed: 0, stop: first.stop, isAt: first.isAt)
        }
        let slopes = self.slopes(samples)
        if time < last.time {
            var index = 0
            while samples[index + 1].time <= time { index += 1 }
            let a = samples[index], b = samples[index + 1]
            let h = b.time - a.time
            let u = (time - a.time) / h
            let u2 = u * u, u3 = u2 * u
            let distance = (2 * u3 - 3 * u2 + 1) * a.distance + (u3 - 2 * u2 + u) * h * slopes[index]
                + (-2 * u3 + 3 * u2) * b.distance + (u3 - u2) * h * slopes[index + 1]
            let speed = (6 * u2 - 6 * u) * (a.distance - b.distance) / h
                + (3 * u2 - 4 * u + 1) * slopes[index] + (3 * u2 - 2 * u) * slopes[index + 1]
            let standing = a.isAt && b.isAt && a.stop == b.stop
            return Position(distance: min(max(distance, a.distance), b.distance), speed: standing ? 0 : max(speed, 0),
                            stop: b.stop, isAt: standing)
        }
        // After the latest report.
        if last.isAt { return Position(distance: last.distance, speed: 0, stop: last.stop, isAt: true) }
        let goal = run.starts.indices.contains(last.stop) ? run.starts[last.stop] : last.distance
        let room = max(goal - last.distance, 0)
        let v = max(slopes[samples.count - 1], 0)
        let elapsed = min(time - last.time, ahead)
        let rate = max(braking, v * v / (2 * max(room, 1)))
        let coast = max(room - v * v / (2 * rate), 0)
        let coastTime = v > 0 ? coast / v : .infinity
        var travelled: Double
        var speed: Double
        if elapsed <= coastTime {
            travelled = v * elapsed
            speed = v
        } else {
            let braked = min(elapsed - coastTime, v / rate)
            travelled = coast + v * braked - rate * braked * braked / 2
            speed = max(v - rate * braked, 0)
        }
        let distance = min(last.distance + travelled, goal)
        return Position(distance: distance, speed: distance >= goal ? 0 : speed, stop: last.stop, isAt: false)
    }

    /// The train's speed at each report, for a smooth curve through them that never
    /// goes back or overshoots (Fritsch–Carlson, as in PCHIP): none at a station,
    /// none where it didn't move.
    static func slopes(_ samples: [Sample]) -> [Double] {
        let count = samples.count
        guard count >= 2 else { return Array(repeating: 0, count: count) }
        var h: [Double] = [], d: [Double] = []
        for index in 0..<(count - 1) {
            let span = samples[index + 1].time - samples[index].time
            h.append(span)
            d.append((samples[index + 1].distance - samples[index].distance) / span)
        }
        var m = [Double](repeating: 0, count: count)
        if count == 2 {
            m = [d[0], d[0]]
        } else {
            for k in 1..<(count - 1) where d[k - 1] > 0 && d[k] > 0 {
                let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
            }
            func end(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
                let slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
                if slope * d0 <= 0 { return 0 }
                if d0 * d1 <= 0, abs(slope) > 3 * abs(d0) { return 3 * d0 }
                return slope
            }
            m[0] = end(h[0], h[1], d[0], d[1])
            m[count - 1] = end(h[count - 2], h[count - 3], d[count - 2], d[count - 3])
        }
        for index in samples.indices where samples[index].isAt { m[index] = 0 }
        return m
    }
}
