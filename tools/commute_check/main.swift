import Foundation

// Checks the app's start-up planner (Departures/Planner/CommutePlanner.swift)
// against the Python reference (tools/commute_reference.py): same routes, same
// station and reason in every situation the reference wrote, same calendar and
// clock arithmetic. Built and run by the Commute check workflow:
//
//   swiftc -O Departures/Planner/CommutePlanner.swift tools/commute_check/main.swift -o commute-check
//   ./commute-check network.json schedule.json expected.json

struct NetworkFile: Decodable {
    struct Line: Decodable {
        let code: String
        let patterns: [[String]]
        let paths: [[[Double]]]
    }

    struct Station: Decodable {
        let code: String
        let lat: Double
        let lon: Double
    }

    let lines: [Line]
    let stations: [Station]
}

struct ScheduleFile: Decodable {
    struct Trip: Decodable {
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

    let generated: String
    let patterns: [[String]]
    let trips: [Trip]
    let days: [String: [Int]]
}

struct Expected: Decodable {
    struct Routes: Decodable {
        let toWork: [[String]]?
        let toHome: [[String]]?
    }

    struct Situation: Decodable {
        let home: String?
        let work: String?
        let lat: Double
        let lon: Double
        let accuracy: Double
        let day: String
        let minute: Int
        let minuteOfDay: Int
        let station: String?
        let reason: String
    }

    struct CalendarCase: Decodable {
        let day: String
        let weekday: Int
        let next: String
        let previous: String
        let later: String
    }

    struct ClockCase: Decodable {
        let utc: Double
        let day: String
        let now: Int
        let minuteOfDay: Int
        let shifts: [Int]
    }

    let generated: String
    let typicalDay: String?
    let routes: [String: Routes]
    let situations: [Situation]
    let calendar: [CalendarCase]
    let clocks: [ClockCase]
}

func load<T: Decodable>(_ type: T.Type, _ path: String) -> T {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        print("Couldn't read \(path): \(error)")
        exit(2)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: commute-check network.json schedule.json expected.json")
    exit(2)
}
let networkFile = load(NetworkFile.self, arguments[1])
let scheduleFile = load(ScheduleFile.self, arguments[2])
let expected = load(Expected.self, arguments[3])

let network = CommutePlanner.Network(
    stations: networkFile.stations.map { .init(code: $0.code, latitude: $0.lat, longitude: $0.lon) },
    lines: networkFile.lines.map { .init(code: $0.code, patterns: $0.patterns, paths: $0.paths) }
)
let timetable = CommutePlanner.Timetable(
    generated: scheduleFile.generated,
    patterns: scheduleFile.patterns,
    trips: scheduleFile.trips.map { .init(number: $0.number, line: $0.line, pattern: $0.pattern, times: $0.times) },
    days: scheduleFile.days
)
let planner = CommutePlanner(network: network, timetable: timetable)

var failures: [String] = []
func fail(_ message: String) {
    failures.append(message)
}

// Timetable and calendar.
if expected.generated != timetable.generated {
    fail("timetable: reference used \(expected.generated), this run \(timetable.generated)")
}
if planner.typicalWeekday() != expected.typicalDay {
    fail("typical weekday: \(planner.typicalWeekday() ?? "none"), reference \(expected.typicalDay ?? "none")")
}
for c in expected.calendar {
    let got = (CommutePlanner.weekday(c.day) ?? -1, CommutePlanner.shift(c.day, by: 1),
               CommutePlanner.shift(c.day, by: -1), CommutePlanner.shift(c.day, by: 45))
    if got != (c.weekday, c.next, c.previous, c.later) {
        fail("calendar \(c.day): \(got), reference \((c.weekday, c.next, c.previous, c.later))")
    }
}
for c in expected.clocks {
    let clock = CommutePlanner.Clock.at(Date(timeIntervalSince1970: c.utc))
    let want = CommutePlanner.Clock(day: c.day, now: c.now, minuteOfDay: c.minuteOfDay, shifts: c.shifts)
    if clock != want {
        fail("clock at \(c.utc): \(String(describing: clock)), reference \(want)")
    }
}

// Home <-> work journeys.
func legs(_ list: [[String]]?) -> [CommutePlanner.Leg]? {
    list?.map { CommutePlanner.Leg(line: $0[0], board: $0[1], alight: $0[2]) }
}
var routes: [String: CommutePlanner.Routes] = [:]
for (key, want) in expected.routes.sorted(by: { $0.key < $1.key }) {
    let parts = key.split(separator: "|").map(String.init)
    let got = planner.routes(home: parts[0], work: parts[1])
    routes[key] = got
    let reference = CommutePlanner.Routes(toWork: legs(want.toWork), toHome: legs(want.toHome))
    if got != reference {
        fail("routes \(key): \(got), reference \(reference)")
    }
}

// Every situation.
var reasons: [String: Int] = [:]
var slowest = 0.0
let started = Date()
for (index, s) in expected.situations.enumerated() {
    guard let clock = CommutePlanner.Clock.on(day: s.day, minute: s.minute) else {
        fail("situation \(index): no clock for \(s.day) +\(s.minute)")
        continue
    }
    if clock.minuteOfDay != s.minuteOfDay {
        fail("situation \(index): clock time \(clock.minuteOfDay), reference \(s.minuteOfDay)")
    }
    let pair = (s.home != nil && s.work != nil) ? routes["\(s.home!)|\(s.work!)"] : nil
    let one = Date()
    let choice = planner.decide(user: CommutePlanner.Point(latitude: s.lat, longitude: s.lon),
                                accuracy: s.accuracy, clock: clock, home: s.home, work: s.work, routes: pair)
    slowest = max(slowest, Date().timeIntervalSince(one))
    reasons[choice.reason.rawValue, default: 0] += 1
    if choice.station != s.station || choice.reason.rawValue != s.reason {
        fail("situation \(index) (home \(s.home ?? "-"), work \(s.work ?? "-"), \(s.lat),\(s.lon) ±\(s.accuracy) m, "
             + "\(s.day) +\(s.minute)): \(choice.station ?? "none") \(choice.reason.rawValue), "
             + "reference \(s.station ?? "none") \(s.reason)")
    }
}
let elapsed = Date().timeIntervalSince(started)

print("Timetable \(timetable.generated), typical weekday \(planner.typicalWeekday() ?? "none")")
print("\(expected.calendar.count) calendar days, \(expected.clocks.count) clocks, \(expected.routes.count) home/work pairs")
print("\(expected.situations.count) situations: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
print(String(format: "Deciding took %.2f ms on average, %.1f ms at most",
             elapsed / Double(max(expected.situations.count, 1)) * 1000, slowest * 1000))
if failures.isEmpty {
    print("All match the reference.")
} else {
    print("\(failures.count) differences from the reference:")
    for line in failures.prefix(40) { print("  " + line) }
    exit(1)
}
