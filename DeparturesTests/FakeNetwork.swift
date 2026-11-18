import Foundation
@testable import Departures

/// Stands in for the worker (and through it GO's feeds) while the tests run: every
/// request the app makes is answered from `FakeNetwork`'s routes, by path ("/Stop/
/// NextService/OA"), and anything not set gets a 404. Tests that use it run one at a
/// time (they're all inside `GOFeeds`, which is serialized).
final class FakeNetwork: URLProtocol, @unchecked Sendable {
    /// One answer: what came back, or no answer at all.
    enum Reply: Sendable, CustomStringConvertible {
        case answer(status: Int, type: String, body: String)
        case failure(URLError.Code)

        static func json(_ object: Any, status: Int = 200) -> Reply {
            .answer(status: status, type: "application/json", body: FakeNetwork.json(object))
        }

        static func page(_ html: String, status: Int = 200, type: String = "text/html") -> Reply {
            .answer(status: status, type: type, body: html)
        }

        var description: String {
            switch self {
            case .answer(let status, let type, let body): "\(status) \(type) \(body.prefix(40))"
            case .failure(let code): "no answer (\(code.rawValue))"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var installed = false

    /// Answers the app's requests from here on, with the usual quiet feeds.
    static func start() {
        lock.withLock {
            if !installed {
                URLProtocol.registerClass(FakeNetwork.self)
                installed = true
            }
            routes = quiet()
            log = []
        }
    }

    static func set(_ path: String, _ reply: Reply) {
        lock.withLock { routes[path] = reply }
    }

    /// The paths asked for since `start()`.
    static var asked: [String] { lock.withLock { log } }

    /// Feeds with nothing in them: no cancellations, no alerts, no trains, and a
    /// timetable with a train every 20 minutes (see `Timetable`).
    private static func quiet() -> [String: Reply] {
        [
            "/ServiceUpdate/Exceptions/Train": .json(["Metadata": GO.ok(), "Trip": [Any]()]),
            "/ServiceUpdate/ServiceAlert/All": .json(["Metadata": GO.ok(), "Messages": ["Message": [Any]()]]),
            "/ServiceUpdate/UnionDepartures/All": .json(["Metadata": GO.ok(), "AllDepartures": ["Trip": [Any]()]]),
            "/live/cancelled": .json(["trips": [Any](), "from": ["exceptions", "updates"]]),
            "/live/trains": .json(["at": Int(Date().timeIntervalSince1970), "trains": [Any]()]),
            "timetable": .answer(status: 200, type: "application/json", body: Timetable.json()),
        ]
    }

    static func key(for url: URL) -> String {
        let text = url.absoluteString
        if text.hasPrefix(ProxyConfig.baseURL) {
            return String(text.dropFirst(ProxyConfig.baseURL.count)).components(separatedBy: "?")[0]
        }
        if url == ScheduleStore.remoteURL { return "timetable" }
        return (url.host ?? "") + url.path
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { fatalError("Not JSON: \(object)") }
        return text
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = Self.key(for: url)
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(key)
            return Self.routes[key]
                ?? .json(["Metadata": ["ErrorCode": "404", "ErrorMessage": "Not found"]], status: 404)
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .answer(let status, let type, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - What GO's feeds say, made up

/// Toronto wall-clock times as GO's feeds write them.
enum Toronto {
    static let zone = TimeZone(identifier: "America/Toronto")!

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    private static let full = formatter("yyyy-MM-dd HH:mm:ss")
    private static let clock = formatter("HH:mm")

    /// "2026-11-13 07:40:00"
    static func wall(_ date: Date) -> String { full.string(from: date) }
    /// "07:40"
    static func hm(_ date: Date) -> String { clock.string(from: date) }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Today (in Toronto) at a time, `days` from now.
    static func today(_ hour: Int, _ minute: Int, days: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: Date())!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// `minutes` from now, on the minute (as GO's times are).
    static func inMinutes(_ minutes: Double) -> Date {
        let now = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (now / 60).rounded(.down) * 60 + minutes * 60)
    }
}

/// GO's feeds' JSON, for a made-up Lakeshore West: Aldershot, Burlington, Oakville,
/// Clarkson, Port Credit, Union.
enum GO {
    static func ok(_ at: Date = Date()) -> [String: Any] {
        ["TimeStamp": Toronto.wall(at), "ErrorCode": "200", "ErrorMessage": "OK"]
    }

    static func error(_ code: String, _ message: String = "Error") -> [String: Any] {
        ["Metadata": ["TimeStamp": Toronto.wall(Date()), "ErrorCode": code, "ErrorMessage": message]]
    }

    /// /Stop/NextService/{code}: `lines` as given (a list, one alone, null...).
    static func nextService(_ lines: Any, metadata: Any = ok()) -> [String: Any] {
        ["Metadata": metadata, "NextService": ["Lines": lines]]
    }

    /// One departure on /Stop/NextService.
    static func line(_ trip: Any, at time: Date?, expected: Date? = nil, platform: Any = "2", actual: Any = "",
                     stop: String = "OA", line: String = "LW", type: String = "T",
                     direction: String = "LW - Union Station") -> [String: Any] {
        [
            "StopCode": stop, "LineCode": line, "LineName": "Lakeshore West", "ServiceType": type,
            "DirectionCode": "E", "DirectionName": direction,
            "ScheduledDepartureTime": time.map(Toronto.wall) ?? NSNull(),
            "ComputedDepartureTime": expected.map(Toronto.wall) ?? "",
            "DepartureStatus": "I", "ScheduledPlatform": platform, "ActualPlatform": actual,
            "TripOrder": 1, "TripNumber": trip, "UpdateTime": Toronto.wall(Date()), "Status": "S",
        ]
    }

    /// /ServiceUpdate/UnionDepartures/All
    static func union(_ trips: Any) -> [String: Any] {
        ["Metadata": ok(), "AllDepartures": ["Trip": trips]]
    }

    /// One train on the Union board.
    static func unionTrip(_ trip: String, at time: Date, platform: Any = "5 & 6", stops: Any? = nil) -> [String: Any] {
        [
            "Info": "Wait / Attendez", "TripNumber": trip, "Platform": platform, "Service": "Lakeshore West",
            "ServiceType": "T", "Time": Toronto.wall(time),
            "Stops": stops ?? [["Name": "Port Credit GO", "Code": "PO"], ["Name": "Oakville GO", "Code": "OA"],
                               ["Name": "Aldershot GO", "Code": "AL"]],
        ]
    }

    /// /ServiceUpdate/Exceptions/Train
    static func exceptions(_ trips: Any) -> [String: Any] {
        ["Metadata": ok(), "Trip": trips]
    }

    /// /Schedule/Trip/{day}/{number}
    static func trip(_ number: String, stops: Any) -> [String: Any] {
        ["Metadata": ok(), "Trips": [["Number": number, "Destination": "Union Station", "Status": "S", "Stops": stops]]]
    }

    /// One stop on /Schedule/Trip: bare "HH:mm" times.
    static func stop(_ code: String, _ scheduled: String?, computed: String? = nil,
                     track: Any = ["Scheduled": "2", "Actual": ""]) -> [String: Any] {
        [
            "Code": code, "Status": "S", "Track": track,
            "ArrivalTime": ["Scheduled": scheduled ?? "", "Computed": computed ?? ""],
            "DepartureTime": ["Scheduled": scheduled ?? "", "Computed": computed ?? ""],
        ]
    }

    /// /ServiceUpdate/ServiceAlert/All
    static func alerts(_ messages: Any) -> [String: Any] {
        ["Metadata": ok(), "Messages": ["Message": messages]]
    }

    /// The worker's /live/trains.
    static func trains(_ trains: [[String: Any]]) -> [String: Any] {
        ["at": Int(Date().timeIntervalSince1970), "trains": trains]
    }

    static func train(_ trip: String, seconds ago: Double = 10, status: String = "at", stop: String = "OA",
                      lat: Any = 43.4561, lon: Any = -79.6812, delay: Any = 60) -> [String: Any] {
        [
            "trip": trip, "line": "LW", "lat": lat, "lon": lon, "time": Date().timeIntervalSince1970 - ago,
            "status": status, "stop": stop, "delay": delay, "moving": false, "course": 90,
        ]
    }
}

/// The timetable the app downloads, made up: Lakeshore West both ways every 20
/// minutes all day (trips 8000 on, eastbound; 9000 on, westbound), yesterday, today
/// and tomorrow.
enum Timetable {
    static let east = ["AL", "BU", "OA", "CL", "PO", "UN"]
    static let minutes = [0, 12, 30, 35, 41, 50]

    static func json() -> String {
        var trips: [[Any]] = []
        for (i, start) in stride(from: 0, to: 1440, by: 20).enumerated() {
            trips.append([String(format: "8%03d", i), "LW", 0, minutes.map { start + $0 }])
            trips.append([String(format: "9%03d", i), "LW", 1, minutes.reversed().map { start + 50 - $0 }])
        }
        let days = [-1, 0, 1].map { TorontoTime.dateWire(Toronto.today(12, 0, days: $0)) }
        let file: [String: Any] = [
            "version": 1,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "feedVersion": "tests",
            "startDate": days[0],
            "patterns": [east, Array(east.reversed())],
            "trips": trips,
            "days": Dictionary(uniqueKeysWithValues: days.map { ($0, Array(0..<trips.count)) }),
        ]
        return FakeNetwork.json(file)
    }
}
