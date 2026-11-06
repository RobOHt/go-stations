import Foundation

/// Where a train is along its line, and the track still ahead of it, from the
/// network's track shapes. Uses the start-up planner's flat projection, so it's
/// Foundation only.
struct TrackGeometry: Sendable {
    typealias Point = CommutePlanner.Point
    typealias Path = CommutePlanner.Path

    struct Coordinate: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// A station closer than this to a track shape is on it.
    private static let snap = CommutePlanner.snap

    private let position: [String: Point]
    private let paths: [String: [Path]]

    init(network: CommutePlanner.Network) {
        var position: [String: Point] = [:]
        for station in network.stations where position[station.code] == nil {
            position[station.code] = Point(latitude: station.latitude, longitude: station.longitude)
        }
        self.position = position
        var paths: [String: [Path]] = [:]
        for line in network.lines {
            paths[line.code] = line.paths.compactMap { coordinates -> Path? in
                let points = coordinates.compactMap { pair -> Point? in
                    pair.count == 2 ? Point(latitude: pair[0], longitude: pair[1]) : nil
                }
                return points.count >= 2 ? Path(points) : nil
            }
        }
        self.paths = paths
    }

    static func point(_ coordinate: Coordinate) -> Point {
        Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func coordinate(_ point: Point) -> Coordinate {
        Coordinate(latitude: point.y / CommutePlanner.metresPerDegree,
                   longitude: point.x / (CommutePlanner.cosRef * CommutePlanner.metresPerDegree))
    }

    func station(_ code: String) -> Point? { position[code] }

    // MARK: Between two stops

    /// The track shape both stops sit on, and how far along it each one is.
    private func locate(_ line: String, _ a: String, _ b: String) -> (path: Path, sa: Double, sb: Double)? {
        guard let pa = position[a], let pb = position[b] else { return nil }
        var best: (score: Double, path: Path, sa: Double, sb: Double)?
        for path in paths[line] ?? [] {
            let ra = path.project(pa), rb = path.project(pb)
            guard ra.distance <= Self.snap, rb.distance <= Self.snap else { continue }
            let score = ra.distance + rb.distance
            if best == nil || score < best!.score {
                best = (score, path, ra.arc, rb.arc)
            }
        }
        return best.map { ($0.path, $0.sa, $0.sb) }
    }

    /// The track from `fraction` of the way between stops a and b on to b, in
    /// travel order (a straight line where no track shape joins them).
    private func track(_ line: String, from a: String, to b: String, startingAt fraction: Double = 0) -> [Point] {
        guard let pa = position[a], let pb = position[b] else { return [] }
        let f = min(max(fraction, 0), 1)
        if let hit = locate(line, a, b) {
            let start = hit.sa + (hit.sb - hit.sa) * f
            var points = hit.path.piece(start, hit.sb)
            if start > hit.sb { points.reverse() }
            return points
        }
        return [Point(x: pa.x + (pb.x - pa.x) * f, y: pa.y + (pb.y - pa.y) * f), pb]
    }

    /// Where a train `fraction` of the way between stops a and b is, along the track.
    func point(line: String, from a: String, to b: String, fraction: Double) -> Point? {
        guard let pa = position[a], let pb = position[b] else { return nil }
        let f = min(max(fraction, 0), 1)
        if let hit = locate(line, a, b) {
            return hit.path.point(at: hit.sa + (hit.sb - hit.sa) * f)
        }
        return Point(x: pa.x + (pb.x - pa.x) * f, y: pa.y + (pb.y - pa.y) * f)
    }

    /// The track between two neighbouring stops, in travel order (a straight line
    /// where no track shape joins them).
    func segment(line: String, from a: String, to b: String) -> [Point] {
        track(line, from: a, to: b)
    }

    /// The direction of travel `fraction` of the way between stops a and b, in
    /// degrees clockwise from north.
    func heading(line: String, from a: String, to b: String, fraction: Double) -> Double? {
        let points = track(line, from: a, to: b)
        guard points.count >= 2 else { return nil }
        let f = min(max(fraction, 0), 1)
        return Self.bearing(on: points, at: Self.length(of: points) * f)
    }

    // MARK: Along a trip

    /// The track a trip covers from `fraction` of the way between stops `from` and
    /// `from + 1`, on to stop `to`.
    func route(line: String, stops: [String], from: Int, fraction: Double = 0, to: Int) -> [Point] {
        guard from >= 0, from < to, to < stops.count else { return [] }
        var points: [Point] = []
        for k in from..<to {
            let piece = track(line, from: stops[k], to: stops[k + 1], startingAt: k == from ? fraction : 0)
            points += points.isEmpty ? piece : Array(piece.dropFirst())
        }
        return points
    }

    /// How far a point is from a stretch of track, and how far along it (in metres)
    /// its closest point is.
    static func locate(_ point: Point, on track: [Point]) -> (distance: Double, along: Double)? {
        guard track.count >= 2 else { return nil }
        let result = Path(track).project(point)
        return (result.distance, result.arc)
    }

    /// The direction of travel at `along` metres into a stretch of track, in degrees
    /// clockwise from north.
    static func bearing(on track: [Point], at along: Double) -> Double? {
        guard track.count >= 2 else { return nil }
        let path = Path(track)
        let total = path.cumulative[path.cumulative.count - 1]
        let a = path.point(at: max(0, min(along, total - 25)))
        let b = path.point(at: min(total, max(along, 25) + 25))
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return nil }
        let degrees = atan2(dx, dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Length of a stretch of track in metres.
    static func length(of track: [Point]) -> Double {
        guard track.count >= 2 else { return 0 }
        return Path(track).cumulative.last ?? 0
    }
}
