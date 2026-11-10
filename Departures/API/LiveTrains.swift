import Foundation
import Observation

/// One GO train's latest live report, from the worker's /live/trains: GO's GTFS
/// vehicle positions (about every 20 seconds), with how late it runs from Service
/// at a Glance.
struct LiveTrain: Decodable, Equatable, Sendable {
    let trip: String
    let line: String?
    let lat: Double
    let lon: Double
    /// When GO last heard from the train.
    let time: Date
    /// "at": standing at `stop`; "to": on its way there; nil: not known.
    var status: String?
    /// A station's code (or, now and then, a signal's or junction's).
    let stop: String?
    /// Seconds late (negative: early), when known.
    let delay: Double?
    let moving: Bool?
    let course: Double?

    var isAtStop: Bool { status == "at" }

    var coordinate: TrackGeometry.Coordinate { .init(latitude: lat, longitude: lon) }

    /// Whether it still says where the train is.
    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(time) < LiveFix.freshFor && time.timeIntervalSince(now) < 60
    }

    /// Where it puts the train among a trip's stops (at or after `hint`, where it
    /// was last), or nil when its stop isn't one of them.
    func fix(in codes: [String], from hint: Int = 0) -> LiveFix? {
        guard let stop, status == "at" || status == "to" else { return nil }
        let start = min(max(hint, 0), codes.count)
        guard let index = codes[start...].firstIndex(of: stop) ?? (hint > 0 ? nil : codes.firstIndex(of: stop))
        else { return nil }
        return LiveFix(index: index, isAt: isAtStop, time: time)
    }
}

/// Where a train is among its trip's stops, by its latest live report.
struct LiveFix: Codable, Equatable, Sendable {
    /// The stop it's standing at, or on its way to.
    let index: Int
    /// Standing at it, rather than on its way.
    let isAt: Bool
    /// When GO said so.
    let time: Date

    /// A report older than this says nothing about where the train is now.
    static let freshFor: TimeInterval = 120

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(time) < Self.freshFor }
}

/// Where every GO train is right now, fetched while something shows trains (the
/// map with a tracked train or all trains, a trip's stops) and shared by them.
@MainActor
@Observable
final class LiveTrains {
    static let shared = LiveTrains()

    /// The trains running now, by trip number.
    private(set) var trains: [String: LiveTrain] = [:]
    /// When the list last came in.
    private(set) var updatedAt: Date?
    /// Each train's reports over the last few minutes, oldest first (kept a while
    /// after it leaves the list), for replaying its run on the map.
    @ObservationIgnored private(set) var history: [String: [LiveTrain]] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?

    private init() {}

    /// Whether the list is recent: a train missing from it isn't running.
    func isCurrent(at now: Date = Date()) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) < 60 && !trains.isEmpty
    }

    /// A train's latest report, while it still says where the train is.
    func train(_ number: String, at now: Date = Date()) -> LiveTrain? {
        guard let train = trains[number], train.isFresh(at: now) else { return nil }
        return train
    }

    /// A train's latest report, however old (an old one can still say it got to
    /// the end of its run: see `TrackedTrip.following`).
    func latest(_ number: String) -> LiveTrain? { trains[number] }

    /// Fetches the list, unless it came in less than `maxAge` seconds ago.
    func refresh(maxAge: TimeInterval = 8) async {
        if let updatedAt, Date().timeIntervalSince(updatedAt) < maxAge { return }
        if let loading {
            await loading.value
            return
        }
        let task = Task { await load() }
        loading = task
        await task.value
        loading = nil
    }

    private struct Response: Decodable {
        let trains: [LiveTrain]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func load() async {
        guard let url = URL(string: ProxyConfig.baseURL + "/live/trains") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request) else { return }
        let (data, response) = result
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? Self.decoder.decode(Response.self, from: data)
        else { return }
        let now = Date()
        var next: [String: LiveTrain] = [:]
        for var train in list.trains {
            // Creeping along the platform it's at, GO says it's on its way to that
            // same station: it's still there.
            if train.status == "to", let before = trains[train.trip], before.isAtStop, before.stop == train.stop {
                train.status = "at"
            }
            next[train.trip] = train
            var reports = history[train.trip] ?? []
            if reports.last.map({ train.time > $0.time }) ?? true { reports.append(train) }
            history[train.trip] = Array(reports.suffix(12))
        }
        history = history.compactMapValues { reports in
            let kept = reports.filter { now.timeIntervalSince($0.time) < 300 }
            return kept.isEmpty ? nil : kept
        }
        trains = next
        updatedAt = now
        TripTracker.shared.follow(self)
    }
}
