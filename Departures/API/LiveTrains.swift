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

    /// A position a train could be at: on the globe, and not 0 for "not given".
    var isOnEarth: Bool {
        lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180 && lat != 0 && lon != 0
    }

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

extension Notification.Name {
    /// A new list of live trains is in (see `LiveTrains`).
    static let liveTrainsUpdated = Notification.Name("LiveTrainsUpdated")
}

/// Whether the list of live trains is still awaited. Right after the app opens or
/// comes back (or trains are first asked for), it's a moment away: until it's in, or
/// a few seconds have gone by without it, nothing is drawn by the timetable for want
/// of a live position (it would be drawn, then moved the moment after).
struct LiveContact: Sendable {
    /// When a fetch of the list last finished, whether or not it got one.
    var attemptedAt: Date?
    /// When the list last began to be wanted after a lull in fetching it.
    var wantedSince: Date?

    /// How long after the list last came in its reports still say where trains
    /// are: past this (the app just opened or came back, or it's offline) what it
    /// has is old news.
    static let inTouchFor: TimeInterval = 30
    /// While the list is kept up, fetches finish at most this far apart (every 5
    /// seconds; offline, a 12-second time-out and 5 more): a longer gap is a lull
    /// (the app was away, or nothing showed trains).
    static let lull: TimeInterval = 20
    /// How long what's drawn waits for the list after a lull before going by the
    /// timetable for want of it.
    static let patience: TimeInterval = 3

    /// The list is wanted at `now`: something draws trains, or fetches it.
    mutating func want(at now: Date) {
        let last = attemptedAt ?? .distantPast
        guard now.timeIntervalSince(last) > Self.lull else { return }
        if wantedSince.map({ $0 <= last }) ?? true { wantedSince = now }
    }

    /// Whether the list is still awaited at `now`: it isn't recent (`listedAt`: when
    /// one last came in) and has only just been wanted.
    func isPending(at now: Date, listedAt: Date?) -> Bool {
        if let listedAt, now.timeIntervalSince(listedAt) < Self.inTouchFor { return false }
        guard let wantedSince else { return false }
        return now.timeIntervalSince(wantedSince) < Self.patience
    }
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
    @ObservationIgnored private var contact = LiveContact()

    private init() {}

    /// A train's latest report, while it still says where the train is.
    func train(_ number: String, at now: Date = Date()) -> LiveTrain? {
        guard let train = trains[number], train.isFresh(at: now) else { return nil }
        return train
    }

    /// A train's latest report, however old (an old one can still say it got to
    /// the end of its run: see `TrackedTrip.following`).
    func latest(_ number: String) -> LiveTrain? { trains[number] }

    /// A train's reports over the last few minutes, oldest first, while they still
    /// say where it is: GO reported it in the last two minutes, in a list that came
    /// in within the last half minute. That's a live position: while a train has
    /// one, nothing else places it (the map, or the marker among its stops). Nil
    /// otherwise: then its times are the backup (see `isPending`, `isReporting`).
    func reports(of number: String, at now: Date = Date()) -> [LiveTrain]? {
        guard isInTouch(at: now), let reports = history[number], let newest = reports.last,
              newest.isFresh(at: now)
        else { return nil }
        return reports
    }

    /// Whether the list is one to go by: it came in within the last half minute.
    func isInTouch(at now: Date = Date()) -> Bool {
        updatedAt.map { now.timeIntervalSince($0) < LiveContact.inTouchFor } ?? false
    }

    /// Whether GO's live positions are coming in: the list is recent, with a train
    /// on it reported lately. While they are, a train they leave out isn't running
    /// as far as GO says. (When they aren't, GO's feed is down or frozen, the app is
    /// offline, or no trains are running.)
    func isReporting(at now: Date = Date()) -> Bool {
        isInTouch(at: now) && trains.values.contains { $0.isFresh(at: now) }
    }

    /// Whether the list is still awaited (see `LiveContact`): the app has just
    /// opened or come back, and nothing is drawn by the timetable yet.
    func isPending(at now: Date = Date()) -> Bool {
        contact.want(at: now)
        return contact.isPending(at: now, listedAt: updatedAt)
    }

    /// Fetches the list, unless it came in less than `maxAge` seconds ago.
    func refresh(maxAge: TimeInterval = 8) async {
        if let updatedAt, Date().timeIntervalSince(updatedAt) < maxAge { return }
        contact.want(at: Date())
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
        /// (One train the app can't read costs that train, not the list.)
        @FeedList var trains: [LiveTrain]?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func load() async {
        defer { contact.attemptedAt = Date() }
        guard let url = URL(string: ProxyConfig.baseURL + "/live/trains") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request) else { return }
        let (data, response) = result
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? Self.decoder.decode(Response.self, from: data),
              let reported = list.trains
        else { return }
        let now = Date()
        var next: [String: LiveTrain] = [:]
        // A position no train could be at isn't one to draw (MapKit won't).
        for var train in reported where train.isOnEarth {
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
        // The map draws each train where its new report has it straight away.
        NotificationCenter.default.post(name: .liveTrainsUpdated, object: nil)
    }
}
