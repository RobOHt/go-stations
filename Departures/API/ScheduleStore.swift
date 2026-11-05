import Foundation

/// Scheduled GO train departures from GTFS (built by tools/build_schedule.py), used
/// when live data isn't available: no API key yet, Metrolinx or the proxy down, or
/// no connection. Uses the newest of the copy downloaded earlier and the copy bundled
/// in the app, and refreshes from GitHub every few hours.
actor ScheduleStore {
    static let shared = ScheduleStore()

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/RobOHt/go-stations/schedule-data/schedule.json")!
    private static let refreshAfter: TimeInterval = 6 * 3600

    struct Departure: Sendable {
        let tripNumber: String
        let lineCode: String
        /// Every stop the trip makes, in order.
        let pattern: [String]
        /// Where the requested station sits in `pattern`.
        let stopIndex: Int
        let time: Date
        let serviceDay: String
    }

    private struct File: Decodable {
        let version: Int
        let generated: String
        let patterns: [[String]]
        let trips: [Trip]
        let days: [String: [Int]]
    }

    /// `[tripNumber, lineCode, patternIndex, [minutes per stop]]`
    private struct Trip: Decodable {
        let number: String
        let line: String
        let pattern: Int
        let times: [Int]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            number = try container.decode(String.self)
            line = try container.decode(String.self)
            pattern = try container.decode(Int.self)
            times = try container.decode([Int].self)
        }
    }

    private var file: File?
    private var didLoad = false
    private var lastRefresh: Date?
    private var commuteCache: CommutePlanner.Timetable?

    private var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("schedule.json")
    }

    private static func decode(_ data: Data) -> File? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return nil }
        return file
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let bundled = Bundle.main.url(forResource: "schedule", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let downloaded = try? Data(contentsOf: cacheURL)
        for data in [bundled, downloaded].compactMap({ $0 }) {
            guard let candidate = Self.decode(data) else { continue }
            if let current = file, current.generated >= candidate.generated { continue }
            file = candidate
        }
    }

    /// Downloads a newer timetable if the last attempt was a while ago.
    func refreshIfNeeded() async {
        loadIfNeeded()
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshAfter { return }
        lastRefresh = Date()

        var request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request) else { return }
        let (data, response) = result
        guard (response as? HTTPURLResponse)?.statusCode == 200, let fresh = Self.decode(data) else { return }
        if let current = file, current.generated >= fresh.generated { return }

        file = fresh
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Scheduled departures from a station over the next few hours, soonest first.
    /// Trips that end at the station are left out. Returns nil when the timetable
    /// doesn't cover today.
    func departures(from stationCode: String, after now: Date, limit: Int) -> [Departure]? {
        departures(from: stationCode, around: now,
                   start: now.addingTimeInterval(-45), end: now.addingTimeInterval(8 * 3600))
            .map { Array($0.prefix(limit)) }
    }

    /// The trains that most recently left a station (up to three hours back), oldest
    /// first. Nil when the timetable doesn't cover today.
    func earlierDepartures(from stationCode: String, before now: Date, limit: Int) -> [Departure]? {
        departures(from: stationCode, around: now,
                   start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-45))
            .map { Array($0.filter { $0.time < now.addingTimeInterval(-45) }.suffix(limit)) }
    }

    /// Scheduled departures from a station between two times, soonest first.
    private func departures(from stationCode: String, around now: Date, start: Date, end: Date) -> [Departure]? {
        loadIfNeeded()
        guard let file else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TorontoTime.zone
        let today = calendar.startOfDay(for: now)

        var result: [Departure] = []
        var coversToday = false
        // Yesterday's service day still runs after midnight; tomorrow's starts before
        // the end of the look-ahead window.
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
            else { continue }
            let dayKey = TorontoTime.dateWire(day)
            guard let indices = file.days[dayKey] else { continue }
            if offset == 0 { coversToday = true }
            // GTFS times count from "noon minus 12 hours", which stays right across DST changes.
            let base = noon.addingTimeInterval(-12 * 3600)

            for index in indices where index < file.trips.count {
                let trip = file.trips[index]
                guard trip.pattern < file.patterns.count else { continue }
                let pattern = file.patterns[trip.pattern]
                guard let stop = pattern.firstIndex(of: stationCode),
                      stop < pattern.count - 1,
                      stop < trip.times.count
                else { continue }
                let time = base.addingTimeInterval(TimeInterval(trip.times[stop] * 60))
                guard time >= start, time <= end else { continue }
                result.append(Departure(tripNumber: trip.number, lineCode: trip.line, pattern: pattern,
                                        stopIndex: stop, time: time, serviceDay: dayKey))
            }
        }
        guard coversToday else { return nil }
        result.sort { $0.time < $1.time }
        return result
    }

    /// The whole timetable, for the start-up planner. Nil when there's none.
    func commuteTimetable() -> CommutePlanner.Timetable? {
        loadIfNeeded()
        guard let file else { return nil }
        if let commuteCache, commuteCache.generated == file.generated { return commuteCache }
        let timetable = CommutePlanner.Timetable(
            generated: file.generated,
            patterns: file.patterns,
            trips: file.trips.map { .init(number: $0.number, line: $0.line, pattern: $0.pattern, times: $0.times) },
            days: file.days
        )
        commuteCache = timetable
        return timetable
    }

    /// One trip's stops and scheduled times on a service day.
    func trip(number: String, serviceDay: String) -> (pattern: [String], times: [Date])? {
        loadIfNeeded()
        guard let file, let indices = file.days[serviceDay] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TorontoTime.zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = TorontoTime.zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        guard let day = formatter.date(from: serviceDay),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        else { return nil }
        let base = noon.addingTimeInterval(-12 * 3600)

        for index in indices where index < file.trips.count {
            let trip = file.trips[index]
            guard trip.number == number, trip.pattern < file.patterns.count else { continue }
            let times = trip.times.map { base.addingTimeInterval(TimeInterval($0 * 60)) }
            return (file.patterns[trip.pattern], times)
        }
        return nil
    }
}
