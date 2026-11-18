import Foundation

/// GO's feeds made up for one UI test, which the app itself serves in place of the
/// worker's (GOFixtures, debug builds), given as `GO_FIXTURES` at launch. A made-up
/// Lakeshore West: Aldershot, Burlington, Oakville, Clarkson, Port Credit, Union.
struct Feeds {
    private var routes: [String: [String: Any]] = [:]

    /// Nothing cancelled, no alerts, no trains on the map, and a timetable with a
    /// train every 20 minutes each way, all day.
    static func quiet() -> Feeds {
        var feeds = Feeds()
        feeds.json("/ServiceUpdate/Exceptions/Train", ["Metadata": ok, "Trip": [Any]()])
        feeds.json("/ServiceUpdate/ServiceAlert/All", ["Metadata": ok, "Messages": ["Message": [Any]()]])
        feeds.json("/ServiceUpdate/UnionDepartures/All", ["Metadata": ok, "AllDepartures": ["Trip": [Any]()]])
        feeds.json("/live/cancelled", ["trips": [Any](), "from": ["exceptions", "updates"]])
        feeds.json("/live/trains", ["at": Int(Date().timeIntervalSince1970), "trains": [Any]()])
        feeds.json("timetable", timetable())
        return feeds
    }

    mutating func json(_ path: String, _ object: Any, status: Int = 200) {
        routes[path] = ["status": status, "type": "application/json", "body": Self.text(object)]
    }

    mutating func page(_ path: String, _ text: String, status: Int = 200, type: String = "text/html") {
        routes[path] = ["status": status, "type": type, "body": text]
    }

    /// For `launchEnvironment["GO_FIXTURES"]`.
    var environment: String { Self.text(routes) }

    static func text(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: What GO's feeds say

    static var ok: [String: Any] { ["TimeStamp": wall(Date()), "ErrorCode": "200", "ErrorMessage": "OK"] }

    static func nextService(_ lines: [[String: Any]]) -> [String: Any] {
        ["Metadata": ok, "NextService": ["Lines": lines]]
    }

    /// A departure `minutes` from now, `late` minutes late, at `stop`.
    static func line(_ trip: String, in minutes: Double, late: Double? = nil, platform: String = "", stop: String,
                     direction: String = "LW - Union Station") -> [String: Any] {
        let time = soon(minutes)
        return [
            "StopCode": stop, "LineCode": "LW", "LineName": "Lakeshore West", "ServiceType": "T",
            "DirectionCode": "E", "DirectionName": direction, "ScheduledDepartureTime": wall(time),
            "ComputedDepartureTime": late.map { wall(time.addingTimeInterval($0 * 60)) } ?? "",
            "DepartureStatus": "I", "ScheduledPlatform": platform, "ActualPlatform": "", "TripOrder": 1,
            "TripNumber": trip, "UpdateTime": wall(Date()), "Status": "S",
        ]
    }

    static func union(_ trips: [[String: Any]]) -> [String: Any] {
        ["Metadata": ok, "AllDepartures": ["Trip": trips]]
    }

    static func unionTrip(_ trip: String, in minutes: Double, platform: String = "") -> [String: Any] {
        [
            "Info": "", "TripNumber": trip, "Platform": platform, "Service": "Lakeshore West", "ServiceType": "T",
            "Time": wall(soon(minutes)),
            "Stops": [["Name": "Port Credit GO", "Code": "PO"], ["Name": "Oakville GO", "Code": "OA"],
                      ["Name": "Aldershot GO", "Code": "AL"]],
        ]
    }

    static func exceptions(_ trips: [[String: Any]]) -> [String: Any] {
        ["Metadata": ok, "Trip": trips]
    }

    /// /Schedule/Trip/{day}/{number}: `stops` as [code, minutes from now, minutes late (nil: blank)].
    static func trip(_ number: String, stops: [(String, Double, Double?)]) -> [String: Any] {
        ["Metadata": ok, "Trips": [[
            "Number": number, "Destination": "Aldershot GO", "Status": "S",
            "Stops": stops.map { code, minutes, late in
                let time = soon(minutes)
                let block: [String: Any] = ["Scheduled": clock(time),
                                            "Computed": late.map { clock(time.addingTimeInterval($0 * 60)) } ?? ""]
                return ["Code": code, "Status": "S", "Track": ["Scheduled": "", "Actual": ""],
                        "ArrivalTime": block, "DepartureTime": block] as [String: Any]
            },
        ]]]
    }

    /// The service days a train leaving `minutes` from now may be on (yesterday's, after midnight).
    static func serviceDays(_ minutes: Double) -> [String] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = zone
        day.dateFormat = "yyyyMMdd"
        let time = soon(minutes)
        return [day.string(from: time), day.string(from: time.addingTimeInterval(-86400))]
    }

    static func alerts(_ messages: [[String: Any]]) -> [String: Any] {
        ["Metadata": ok, "Messages": ["Message": messages]]
    }

    static func delayAlert(_ subject: String, line: String = "LW") -> [String: Any] {
        ["Code": subject, "SubjectEnglish": subject, "SubjectFrench": subject, "BodyEnglish": "Delays of up to 10 minutes.",
         "BodyFrench": "Retards", "Category": "Service Disruption", "SubCategory": "Train Delay",
         "Lines": [["Code": line]], "Stops": [Any](), "Trips": [Any]()]
    }

    // MARK: Times

    static let zone = TimeZone(identifier: "America/Toronto")!

    static func wall(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// "17:05", as the board shows a time.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `minutes` from now, on the minute.
    static func soon(_ minutes: Double) -> Date {
        let now = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (now / 60).rounded(.down) * 60 + minutes * 60)
    }

    private static func timetable() -> [String: Any] {
        let east = ["AL", "BU", "OA", "CL", "PO", "UN"]
        let offsets = [0, 12, 30, 35, 41, 50]
        var trips: [[Any]] = []
        for (i, start) in stride(from: 0, to: 1440, by: 20).enumerated() {
            trips.append([String(format: "8%03d", i), "LW", 0, offsets.map { start + $0 }])
            trips.append([String(format: "9%03d", i), "LW", 1, offsets.reversed().map { start + 50 - $0 }])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = zone
        day.dateFormat = "yyyyMMdd"
        let days = [-1, 0, 1].map { day.string(from: calendar.date(byAdding: .day, value: $0, to: Date())!) }
        return [
            "version": 1, "generated": ISO8601DateFormatter().string(from: Date()), "feedVersion": "ui-tests",
            "startDate": days[0], "patterns": [east, Array(east.reversed())], "trips": trips,
            "days": Dictionary(uniqueKeysWithValues: days.map { ($0, Array(0..<trips.count)) }),
        ]
    }
}
