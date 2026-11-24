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

    /// The run's track at one of its ends: the point there, and the way a train
    /// travels along it there (a unit vector, east and north).
    struct End {
        let point: Point
        let east: Double
        let north: Double

        /// In degrees clockwise from north.
        var heading: Double {
            let degrees = atan2(east, north) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }

        /// How far `position` is past this end the way trains travel (negative:
        /// short of it), and how far to one side of the track's line there.
        func offset(of position: Point) -> (on: Double, beside: Double) {
            let dx = position.x - point.x, dy = position.y - point.y
            return (dx * east + dy * north, abs(dx * north - dy * east))
        }

        /// The point `metres` on from this end, straight along the track's line there.
        func point(on metres: Double) -> Point {
            Point(x: point.x + east * metres, y: point.y + north * metres)
        }
    }

    /// Where the run starts and ends (nil without track there to go by).
    let head: End?
    let tail: End?

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
        head = Self.end(of: paths.first ?? nil, atStart: true)
        tail = Self.end(of: paths.last ?? nil, atStart: false)
    }

    /// One end of a stretch of track: the way it runs over its first (or last)
    /// 100 m, so a kink in the last metre of a track shape doesn't turn it.
    private static func end(of path: CommutePlanner.Path?, atStart: Bool) -> End? {
        guard let path, let length = path.cumulative.last, length > 1 else { return nil }
        let span = min(100, length)
        let from = path.point(at: atStart ? 0 : length - span)
        let to = path.point(at: atStart ? span : length)
        let dx = to.x - from.x, dy = to.y - from.y
        let size = (dx * dx + dy * dy).squareRoot()
        guard size > 0 else { return nil }
        return End(point: atStart ? from : to, east: dx / size, north: dy / size)
    }

    /// A trip's run along its line through its stops, by the network's track.
    init(line: String, codes: [String], geometry: TrackGeometry) {
        self.init(codes: codes) { a, b in
            let points = geometry.segment(line: line, from: a, to: b)
            return points.count >= 2 ? CommutePlanner.Path(points) : nil
        }
    }

    var length: Double { starts.last ?? 0 }

    /// The stretch of track (by its first stop) that `distance` falls in.
    func segment(at distance: Double) -> Int {
        var index = 0
        while index + 1 < paths.count, starts[index + 1] <= distance { index += 1 }
        return index
    }

    /// `distance` metres along the run, in stops: 2.5 is halfway along the track
    /// from its third stop to its fourth. (For the train's marker among its stops.)
    func progress(at distance: Double) -> Double {
        guard !paths.isEmpty else { return 0 }
        let index = segment(at: distance)
        let length = starts[index + 1] - starts[index]
        guard length > 0 else { return Double(index) }
        return Double(index) + min(max((distance - starts[index]) / length, 0), 1)
    }

    /// The point `distance` metres along the run, and the way the train is going
    /// there (at a station, the way it carries on). Short of the run's start
    /// (`distance` below 0) or past its end: straight on along the track's line
    /// there (see `beyond`).
    func point(at distance: Double) -> (point: Point, heading: Double?)? {
        guard !paths.isEmpty else { return nil }
        if distance < 0, let head { return (head.point(on: distance), head.heading) }
        if distance > length, let tail { return (tail.point(on: distance - length), tail.heading) }
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

    /// Where a train's times put it along the run (see `TrainState`): standing at a
    /// station, or the fraction of the way between two that the clock makes it.
    /// The backup, for a train with no live position: never used while it has one.
    func position(of state: TrainState) -> TrainReplay.Position? {
        let last = codes.count - 1
        guard last >= 1, starts.count == codes.count else { return nil }
        var position: TrainReplay.Position
        switch state {
        case .waiting:
            position = .init(distance: 0, speed: nil, stop: 0, isAt: true)
        case .moving(let from, let fraction):
            guard from >= 0, from + 1 <= last else { return nil }
            let length = starts[from + 1] - starts[from]
            position = .init(distance: starts[from] + length * min(max(fraction, 0), 1), speed: nil,
                             stop: from + 1, isAt: false)
        case .stopped(let at):
            guard at >= 0, at <= last else { return nil }
            position = .init(distance: starts[at], speed: nil, stop: at, isAt: true)
        case .arrived:
            position = .init(distance: starts[last], speed: nil, stop: last, isAt: true)
        case .unknown:
            return nil
        }
        position.isLive = false
        return position
    }

    /// A report further than this from the run's track, in metres, isn't on it (a
    /// yard, a detour): the train is drawn where the report has it, off its line.
    static let onTrack = 250.0

    /// A train within this of a station's own spot on the line, in metres, may be
    /// at its platform: one that far past the spot is still at or heading for that
    /// station, not the next, when GO doesn't say which.
    static let platform = 150.0

    /// A train carried on past its latest report (see `TrainReplay`) is taken no
    /// nearer the station it's heading for than this, in metres short of the
    /// station's own spot on the line. It may come to a stand anywhere from there
    /// on (GO's trains stand up to 235 m short of Union's spot, and up to 160 m
    /// past others'), so from there only its reports bring it in, but for as far
    /// as it's sure to get from the speed it has (`TrainReplay.hard`).
    static let clear = 250.0

    /// A train is placed along its run up to this far short of the run's start or
    /// past its end, in metres, straight on along the track's line there. A run
    /// starts and ends at its first and last stations' own spots on the line, and
    /// a train stands with its GPS up to a couple of hundred metres from those:
    /// at Union, trains for the west wait 140 to 190 m short of where their run
    /// starts, and trains in from the west stop that far past where theirs ends.
    /// They're drawn there, and seen to set off from there, not held at the spot
    /// until their GPS has passed it.
    static let beyond = 400.0
    /// Within this of an end of the run's track, in metres, a position past that
    /// end is placed beyond it. (Track shapes can end in a kink a metre long,
    /// so the nearest point of the track isn't always its very end.)
    private static let atEnd = 10.0

    /// Where one live report has the train: the point of the run's track nearest
    /// the position it gives, how far along the run that is, and how far off the
    /// track the position is. Nothing but that position places it: not the
    /// station's own spot when GO says it's standing there (a train can stand a
    /// couple of hundred metres from it, short of the run's start or past its end
    /// too: see `beyond`), and not the stop GO names, which only says which stop
    /// it's at or heading for; when that isn't one of this run's (a signal, a
    /// junction, none given), it's the next one along from where the train is.
    /// Nil only when the run has no track to go by.
    func place(_ report: LiveTrain, from hint: Int = 0) -> TrainReplay.Sample? {
        let position = TrackGeometry.point(report.coordinate)
        var best: (distance: Double, off: Double)?
        for index in paths.indices {
            guard let path = paths[index] else { continue }
            let hit = path.project(position)
            if let current = best, current.off <= hit.distance { continue }
            best = (starts[index] + hit.arc, hit.distance)
        }
        guard var nearest = best else { return nil }
        // Short of the run's start, or past its end: along the track's line there.
        if nearest.distance < Self.atEnd, let head {
            let offset = head.offset(of: position)
            if offset.on < 0, offset.on >= -Self.beyond { nearest = (offset.on, offset.beside) }
        } else if nearest.distance > length - Self.atEnd, let tail {
            let offset = tail.offset(of: position)
            if offset.on > 0, offset.on <= Self.beyond { nearest = (length + offset.on, offset.beside) }
        }
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

/// Where a train is drawn along its run by its live reports: gliding through them.
///
/// While a train has a live position (the GPS positions Metrolinx reports for it),
/// those alone place it: nothing comes from the timetable, and nothing from where
/// your phone is (not even on board). GO reports each train every 15 seconds or so
/// (some every 5), and a report is 5 to 15 seconds old by the time the app has it.
/// So that a train moves smoothly rather than jumping from one report to the next,
/// it's drawn where it was a few seconds ago (`delay`):
///
/// - Between two reports it follows a smooth curve through them along the track
///   (monotone cubic: it never goes back or overshoots, and stands where it stood).
/// - Past its latest report, while the next isn't in yet, it carries on at the pace
///   it last covered the ground at, for no more than `ahead` seconds, slowing for
///   the station it's heading for and stopping well short of it (`TrainRun.clear`:
///   the train may come to a stand anywhere from there on, so from there only its
///   reports bring it in), or as far on as it's sure to get from the speed it has
///   however hard it brakes (`hard`). Only while it's measurably moving: a
///   standing train's GPS wobbles by a metre or two, which isn't it setting off.
///
/// A new report can show that carrying on was off (the train braked, or a GPS
/// position strayed): the map then puts it right in one quick slide, never easing
/// to it over many seconds (see NetworkMapView). Tried against real trains' reports
/// (into and out of a suburban station, and Union), drawing `delay` seconds behind
/// keeps a train closer to the real one than stepping from report to report did,
/// and never ahead of it, with a correction to make only now and then.
///
/// Only a train with no live position is placed by its times (the backup: see
/// `TrainRun.position(of:)`), and it goes to its live position the moment it has one.
enum TrainReplay {
    /// One report, as a place along the run.
    struct Sample {
        /// Seconds since 2001.
        let time: Double
        /// Metres along the run: the point of its track nearest the report's position
        /// (below 0 short of the run's start, more than its length past its end).
        var distance: Double
        /// How far the report's position is from that point, in metres.
        let off: Double
        /// The stop it's at or heading for.
        let stop: Int
        let isAt: Bool
    }

    /// Where a train is along its run: by its live reports, or with no live
    /// position, where its times put it (`isLive` false).
    struct Position {
        /// Metres along the run (below 0 short of its start, more than its length
        /// past its end: see `TrainRun.beyond`).
        var distance: Double
        /// Metres per second: what it covered over the last quarter of a minute or so
        /// of its reports (nil without two far enough apart to measure it by).
        let speed: Double?
        /// The stop it's at or heading for, by its latest report.
        let stop: Int
        let isAt: Bool
        /// Where the report has it, when that's away from the run's track: the train
        /// is drawn there, not on its line, heading the way the report says.
        var away: TrackGeometry.Point? = nil
        var course: Double? = nil
        /// By its live reports: not by its times for want of them.
        var isLive = true
    }

    /// A train's reports as places along its run, to draw it by: worked out once per
    /// report (they come every 5 to 15 seconds; the map draws every second).
    struct Track {
        /// Its reports on the run's track, oldest first, each later than the one
        /// before and no further back (GPS wobble never takes it back).
        let samples: [Sample]
        /// Its speed at each, for a smooth curve through them (see `slopes`).
        let slopes: [Double]
        /// Where its latest report has it, with how fast it has been going.
        let latest: Position

        /// Measurably on the move, by its latest reports (see `TrainReplay.stirring`).
        var isMoving: Bool { (latest.speed ?? 0) > 0 }
    }

    /// A train that moved less than this over the stretch its speed is measured
    /// over, in metres, is standing: a standing train's GPS wobbles by a few metres
    /// from one report to the next (up to 10 under Union's roof).
    static let stirring = 15.0
    /// A train's speed is measured over at least this long, in seconds. GO reports
    /// most trains every 15 seconds and some every 5; between two reports 5 seconds
    /// apart, a train coming in at 10 km/h has moved less than a standing one's GPS
    /// wobbles.
    static let apart = 12.0
    /// ...and over no longer than this: reports further apart than that (some were
    /// missed) don't say how fast it's going now.
    static let within = 45.0
    /// In a train's first seconds in view (just after the app opens), before it
    /// has two reports `apart` seconds apart: its speed is taken from two at least
    /// this far apart, once it has plainly moved between them (by `stirring` or
    /// more), so it glides from its second report on rather than its third.
    static let soonest = 4.0

    /// How far behind now a train is drawn, in seconds: about how old a report is
    /// when the app gets it, so about half the time there's a report either side
    /// of the moment drawn (the rest of the time it's carried on, for up to 15
    /// seconds or so, until the next report is in). (At 5 it was closer to the
    /// train but ran ahead of it downtown and had to be put back more often; at 20
    /// it never had to be, and was further from the train than stepping.)
    static let delay: TimeInterval = 10
    /// How hard a train slows for a station, and speeds up leaving one, in m/s²
    /// (GO's trains, by their reports: braking from about 600 m out at 70 km/h),
    /// and the speed it then runs at, in m/s.
    static let braking = 0.3
    static let departing = 0.4
    static let cruising = 33.0
    /// How long past its latest report a train is carried on before it's held.
    static let ahead: TimeInterval = 40
    /// The hardest a train brakes, in m/s² (about a full service brake). Whatever
    /// it does next, from the speed it has it gets at least as far as it would
    /// braking like that: it's carried on that far even into the last stretch
    /// before a station (one still doing 70 km/h there has 190 m to go at the
    /// very least; one creeping in at 10 km/h, 4 m).
    static let hard = 1.0

    /// A train's reports (oldest first) as places along `run`, with what the latest
    /// says. Nil when none can be placed.
    ///
    /// Its speed is only ever measured: the ground between where its latest report
    /// has it and where the newest report at least `apart` seconds before had it.
    /// GO's word that a train is standing isn't taken for it (its feed says "stopped
    /// at" a station for most of a minute while the train is still pulling in, and
    /// "not in motion" on and off while it stands).
    static func track(of reports: [LiveTrain], on run: TrainRun) -> Track? {
        var placed: [(sample: Sample, report: LiveTrain)] = []
        for report in reports {
            guard let sample = run.place(report, from: placed.last?.sample.stop ?? 0) else { continue }
            if let last = placed.last, sample.time <= last.sample.time { continue }
            placed.append((sample: sample, report: report))
        }
        guard let last = placed.last else { return nil }
        let sample = last.sample
        var speed: Double?
        if let before = placed.dropLast().last(where: { sample.time - $0.sample.time >= apart })?.sample {
            if sample.time - before.time <= within, sample.off <= TrainRun.onTrack, before.off <= TrainRun.onTrack {
                let moved = abs(sample.distance - before.distance)
                speed = moved < stirring ? 0 : moved / (sample.time - before.time)
            }
        } else if placed.count >= 2, let before = placed.first?.sample, sample.time - before.time >= soonest,
                  sample.off <= TrainRun.onTrack, before.off <= TrainRun.onTrack {
            // Its first seconds in view, with no report yet that long before its
            // latest: by the first it has, once it has plainly moved since (less
            // than that could be it standing, or crawling: nothing says yet).
            let moved = abs(sample.distance - before.distance)
            if moved >= stirring { speed = moved / (sample.time - before.time) }
        }
        var position = Position(distance: sample.distance, speed: speed, stop: sample.stop, isAt: sample.isAt)
        if sample.off > TrainRun.onTrack {
            position.away = TrackGeometry.point(last.report.coordinate)
            position.course = last.report.course
        }
        // The path it glides along: its reports on the run's track, never going back.
        var path: [Sample] = []
        for entry in placed where entry.sample.off <= TrainRun.onTrack {
            var next = entry.sample
            if let before = path.last { next.distance = max(next.distance, before.distance) }
            path.append(next)
        }
        return Track(samples: path, slopes: slopes(path), latest: position)
    }

    /// Where the train's latest report has it along `run`, with how fast it has
    /// been going. Nil without one.
    static func position(of reports: [LiveTrain], on run: TrainRun) -> Position? {
        track(of: reports, on: run)?.latest
    }

    /// Where the train is drawn at `date`: `delay` seconds behind, gliding through
    /// its reports (see above). What it's at or heading for, and how fast it's
    /// going, are as its latest report has them. Away from its track, it's just
    /// where that report has it.
    static func position(on track: Track, of run: TrainRun, at date: Date) -> Position {
        var position = track.latest
        guard position.away == nil,
              let metres = along(track.samples, track.slopes, moving: track.isMoving, on: run,
                                 at: date.timeIntervalSinceReferenceDate - delay)
        else { return position }
        position.distance = metres
        return position
    }

    /// How far along `run` the train was at `time` (seconds since 2001), in metres,
    /// by its reports as placed along it and its speed at each. `moving`: its latest
    /// reports have it measurably on the move (it's carried on past them only then).
    static func along(_ samples: [Sample], _ slopes: [Double], moving: Bool, on run: TrainRun,
                      at time: Double) -> Double? {
        guard let first = samples.first, let last = samples.last, slopes.count == samples.count else { return nil }
        // Before its first report: where that has it.
        if time <= first.time { return first.distance }
        let count = samples.count
        if time < last.time {
            var index = 0
            while index + 2 < count, samples[index + 1].time <= time { index += 1 }
            let a = samples[index], b = samples[index + 1]
            let h = b.time - a.time
            guard h > 0 else { return b.distance }
            let u = (time - a.time) / h
            let u2 = u * u, u3 = u2 * u
            let distance = (2 * u3 - 3 * u2 + 1) * a.distance + (u3 - 2 * u2 + u) * h * slopes[index]
                + (-2 * u3 + 3 * u2) * b.distance + (u3 - u2) * h * slopes[index + 1]
            return min(max(distance, a.distance), b.distance)
        }
        // Past its latest report: carried on from there, at the pace it has there.
        var speed = max(slopes[count - 1], 0)
        if count >= 2 {
            // No faster than it covered the last stretch: a position that strayed
            // ahead (GPS does, between tall buildings), or a train speeding up,
            // doesn't fling it on.
            let before = samples[count - 2]
            if last.time > before.time {
                speed = min(speed, (last.distance - before.distance) / (last.time - before.time))
            }
        }
        // Not at all while it stands.
        guard moving, speed > 0 else { return last.distance }
        let horizon = min(time - last.time, ahead)
        // However hard it brakes from here, it gets this far (see `hard`): it's
        // carried on at least there.
        let braked = min(horizon, speed / hard)
        let sure = last.distance + speed * braked - hard * braked * braked / 2
        // Otherwise no nearer the station it's heading for than well short of its
        // own spot (`TrainRun.clear`): the train may come to a stand anywhere from
        // there on, so from there only its reports say where it is.
        let spot = run.starts.indices.contains(last.stop) ? run.starts[last.stop] : run.length
        let goal = spot - TrainRun.clear
        guard goal - last.distance > 0.5 else { return sure }
        var speedingUp = 0.0
        if count >= 2, slopes[count - 2] == 0 {
            // Just set off: from a standstill, speeding up as trains do (its average
            // since the report it stood at takes in time it stood).
            let gone = max(last.distance - samples[count - 2].distance, 0)
            speed = min(max(slopes[count - 1], 0), (2 * departing * gone).squareRoot())
            speedingUp = departing
        }
        let top = max(cruising, speed)
        var distance = last.distance
        var elapsed = 0.0
        while elapsed < horizon {
            let step = min(0.5, horizon - elapsed)
            let room = goal - distance
            if room <= 0.5 {
                distance = goal
                break
            }
            // Slowing to stop there once it must, otherwise speeding up to its
            // running speed (just after setting off), or holding its pace.
            let needed = speed * speed / (2 * room)
            let rate = needed >= braking ? -needed : (speed < top ? speedingUp : 0)
            let next = max(speed + rate * step, 0)
            distance = min(distance + (speed + next) / 2 * step, goal)
            speed = next
            elapsed += step
        }
        return max(distance, sure)
    }

    /// The train's speed at each report, for a smooth curve through them that never
    /// goes back or overshoots (Fritsch–Carlson, as in PCHIP): none where it didn't
    /// move.
    static func slopes(_ samples: [Sample]) -> [Double] {
        let count = samples.count
        guard count >= 2 else { return Array(repeating: 0, count: count) }
        var h: [Double] = [], d: [Double] = []
        for index in 0..<(count - 1) {
            let span = samples[index + 1].time - samples[index].time
            h.append(span)
            d.append(span > 0 ? (samples[index + 1].distance - samples[index].distance) / span : 0)
        }
        if count == 2 { return [d[0], d[0]] }
        var m = [Double](repeating: 0, count: count)
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
        return m
    }
}

/// How fast each train is going, by its latest live reports (see
/// `TrainReplay.position`): the map notes it as it draws each train (see
/// NetworkMapView), and works it out too for a train whose stops are open but which
/// it doesn't draw; the trip's stops show it. Never a guess, and never your phone's
/// speed: none is shown for a train with nothing to measure it by.
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
