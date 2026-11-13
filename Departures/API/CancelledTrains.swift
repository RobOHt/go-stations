import Foundation

/// Which trains aren't running, or won't stop somewhere they were due to: the
/// worker's /live/cancelled, which reads GO's GTFS trip updates and its train
/// exceptions together (each has had a cancellation the other hadn't: a train
/// not stopping at the first three stations of its run was in the trip updates,
/// with only the third in the exceptions, and the stations' own boards had it
/// running). Without the worker, the exceptions feed alone. Shared by the boards,
/// the trip view and the tracked trip; looked up at most every 20 seconds.
actor CancelledTrains {
    static let shared = CancelledTrains()

    /// One train in one feed.
    struct Entry: Decodable, Equatable, Sendable {
        let trip: String
        /// Its service day ("20261113"), when known (the exceptions are today's).
        var day: String? = nil
        /// The whole trip.
        var all: Bool? = nil
        /// The stations it won't stop at.
        var skips: [String]? = nil
    }

    /// What the feeds say about one train.
    struct Status: Equatable, Sendable {
        /// The whole trip is cancelled.
        var all = false
        /// The stations it won't stop at.
        var skips: Set<String> = []

        /// It won't stop at this station (or anywhere).
        func isCancelled(at code: String) -> Bool { all || skips.contains(code) }
    }

    /// The feeds as of one look.
    struct List: Sendable {
        let entries: [Entry]
        let fetchedAt: Date

        /// What they say about a train on one of its possible service days (nil:
        /// nothing; it runs as planned).
        func status(of trip: String, serviceDays: [String]) -> Status? {
            #if DEBUG
            if let skips = DebugScene.skips { return Status(skips: skips) }
            #endif
            var status = Status()
            var found = false
            for entry in entries where entry.trip == trip {
                if let day = entry.day, !serviceDays.isEmpty, !serviceDays.contains(day) { continue }
                found = true
                if entry.all == true { status.all = true }
                status.skips.formUnion(entry.skips ?? [])
            }
            return found && (status.all || !status.skips.isEmpty) ? status : nil
        }

        /// What they say about the train behind a board row.
        func status(of row: BoardRow) -> Status? {
            status(of: row.tripNumber, serviceDays: BoardService.serviceDays(for: row))
        }

        /// The exceptions feed's cancellations, as entries (no day: they're today's).
        static func entries(from exceptions: ExceptionsResponse?) -> [Entry] {
            (exceptions?.trip ?? []).compactMap { trip in
                guard let number = trip.tripNumber?.nonEmpty else { return nil }
                let all = trip.isCancelled?.isTrue == true
                let skips = (trip.stop ?? []).compactMap { $0.isCancelled?.isTrue == true ? $0.code?.nonEmpty : nil }
                guard all || !skips.isEmpty else { return nil }
                return Entry(trip: number, all: all ? true : nil, skips: skips.isEmpty ? nil : skips)
            }
        }
    }

    private var latest: List?
    private var loading: Task<List?, Never>?

    /// The latest look, unless it's older than `maxAge` seconds; nil when neither
    /// the worker nor the exceptions feed answered.
    func list(maxAge: TimeInterval = 20) async -> List? {
        if let latest, Date().timeIntervalSince(latest.fetchedAt) < maxAge { return latest }
        if let loading { return await loading.value }
        let task = Task { await Self.load() }
        loading = task
        let list = await task.value
        loading = nil
        if let list { latest = list }
        // No answer: the last one, while it's still worth going by.
        if list == nil, let latest, Date().timeIntervalSince(latest.fetchedAt) < 600 { return latest }
        return list
    }

    private struct Response: Decodable {
        let trips: [Entry]
    }

    private static func load() async -> List? {
        if let url = URL(string: ProxyConfig.baseURL + "/live/cancelled") {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let result = try? await URLSession.shared.data(for: request),
               (result.1 as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(Response.self, from: result.0) {
                return List(entries: decoded.trips, fetchedAt: Date())
            }
        }
        // Without the worker's: the exceptions feed alone.
        let exceptions: ExceptionsResponse? = try? await MetrolinxClient().fetch("/ServiceUpdate/Exceptions/Train")
        guard let exceptions else { return nil }
        return List(entries: List.entries(from: exceptions), fetchedAt: Date())
    }
}
