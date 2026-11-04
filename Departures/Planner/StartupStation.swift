import CoreLocation
import Foundation

/// Which board to open on start-up. Feeds `CommutePlanner` (which has the rules)
/// the bundled network, the timetable, where you are and your stations, and
/// keeps the home↔work journeys it works out, so they're planned once per
/// timetable rather than on every launch.
@MainActor
enum StartupStation {
    /// The planner's view of the bundled network.
    private static let network: CommutePlanner.Network = {
        let rail = RailNetwork.shared
        return CommutePlanner.Network(
            stations: rail.stations.map { .init(code: $0.code, latitude: $0.latitude, longitude: $0.longitude) },
            lines: rail.lines.map { line in
                CommutePlanner.Network.Line(
                    code: line.code,
                    patterns: line.patterns,
                    paths: rail.trackPaths
                        .filter { $0.lineCode == line.code }
                        .map { path in path.coordinates.map { [$0.latitude, $0.longitude] } }
                )
            }
        )
    }()

    /// The station to open for someone at `location`, and why; nil if the planner
    /// couldn't run (the caller falls back to the nearest saved station).
    static func choose(at location: CLLocation, home: String?, work: String?,
                       now: Date) async -> CommutePlanner.Choice? {
        let timetable = await ScheduleStore.shared.commuteTimetable() ?? .empty
        let network = Self.network
        // Planned again when home, work, the timetable or the planner's rules change.
        let key = [Self.rulesVersion, home ?? "", work ?? "", timetable.generated].joined(separator: "|")
        let saved = savedRoutes(for: key)
        let point = CommutePlanner.Point(latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude)
        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : CommutePlanner.accuracyCap

        let (choice, routes) = await Task.detached(priority: .userInitiated) {
            () -> (CommutePlanner.Choice?, CommutePlanner.Routes?) in
            guard let clock = CommutePlanner.Clock.at(now) else { return (nil, nil) }
            let planner = CommutePlanner(network: network, timetable: timetable)
            var routes = saved
            if routes == nil, let home, let work {
                routes = planner.routes(home: home, work: work)
            }
            let choice = planner.decide(user: point, accuracy: accuracy, clock: clock,
                                        home: home, work: work, routes: routes)
            return (choice, routes)
        }.value

        if saved == nil, let routes { save(routes, for: key) }
        return choice
    }

    // MARK: Saved home↔work journeys

    private static let routesKey = "commuteRoutes"
    /// Bump when the planner's rules change, so saved journeys are planned again.
    private static let rulesVersion = "2"

    private struct Saved: Codable {
        /// Home, work and the timetable they were planned on.
        let key: String
        let routes: CommutePlanner.Routes
    }

    private static func savedRoutes(for key: String) -> CommutePlanner.Routes? {
        guard let data = UserDefaults.standard.data(forKey: routesKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.key == key
        else { return nil }
        return saved.routes
    }

    private static func save(_ routes: CommutePlanner.Routes, for key: String) {
        guard let data = try? JSONEncoder().encode(Saved(key: key, routes: routes)) else { return }
        UserDefaults.standard.set(data, forKey: routesKey)
    }
}

/// The time the app goes by. Debug builds can fix it for simulator checks with
/// `-debugNow 2026-11-10T07:30:00-05:00`.
enum AppClock {
    static var now: Date {
        #if DEBUG
        if let fixed = DebugScene.fixedNow { return fixed }
        #endif
        return Date()
    }
}
