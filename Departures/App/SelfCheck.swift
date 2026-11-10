#if DEBUG
import CoreLocation
import Foundation

/// Debug builds only (`-debugScene selfCheck`): checks of the tracking logic, run
/// on the simulator by the Screenshots workflow, which fails if any of them does.
/// Each writes a line to Documents/self-check.txt, "ok  name" or "FAIL name: why",
/// and the last line is "done". The trips are made up.
@MainActor
enum SelfCheck {
    private static var lines: [String] = []

    static func run() {
        lines = []
        leaveReminder()
        reportGap()
        changingTrains()
        lines.append("done")
        write()
    }

    // MARK: The checks

    /// #15: the reminder to set off says which way the train goes.
    private static func leaveReminder() {
        let time = date("12:06")
        check("leave reminder: direction and terminus",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Exhibition", direction: "eastbound",
                                   terminus: "Union Station")
                  == "The 12:06 Lakeshore West line train from Exhibition, eastbound to Union Station.")
        check("leave reminder: no direction",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Exhibition", direction: nil,
                                   terminus: "Union Station")
                  == "The 12:06 Lakeshore West line train from Exhibition to Union Station.")
        check("leave reminder: nothing known about where it goes",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Exhibition", direction: nil, terminus: nil)
                  == "The 12:06 Lakeshore West line train from Exhibition.")
        // The real thing, from a tracked train: its Live Activity's direction.
        let trip = lakeshore(boarding: 4, destination: 10)
        let shown = TripActivityController.attributes(for: trip)
        check("leave reminder: a tracked train has a direction", shown?.direction == "eastbound",
              "direction \(shown?.direction ?? "nil")")
    }

    /// A station seen across a gap in the live reports isn't left when the later
    /// report came (build 101's fix).
    private static func reportGap() {
        let trip = lakeshore(boarding: 4, destination: 10)
        let atMimico = train(at: "MI", status: "at", time: date("12:00"))
        let seen = trip.following(atMimico, now: date("12:00:05"))
        // Ten minutes without reports, then on its way to Union.
        let later = seen.following(train(at: "UN", status: "to", time: date("12:10")), now: date("12:10:05"))
        check("report gap: Mimico not left when the later report came", later.stops[8].departed == nil,
              "departed \(later.stops[8].departed.map(TorontoTime.clock) ?? "nil")")
        // Reports as they should come: left when seen leaving.
        let next = seen.following(train(at: "EX", status: "to", time: date("12:00:20")), now: date("12:00:25"))
        check("report gap: left Mimico when seen leaving", next.stops[8].departed == date("12:00:20"))
    }

    /// A trip with a change goes on with the next train in the same Live Activity.
    private static func changingTrains() {
        var first = lakeshore(boarding: 4, destination: 10)
        let next = lakeshore(boarding: 0, destination: 3, line: "LE",
                             codes: ["UN", "DA", "SC", "EG", "GU", "RO", "PIN"])
        first.onward = [OnwardLeg(row: next.row, boardingCode: "UN", destinationCode: "EG", stops: next.stops,
                                  source: .schedule)]
        first.route = [RouteStretch(lineCode: "LW", stops: ["OA", "CL", "UN"]),
                       RouteStretch(lineCode: "LE", stops: ["UN", "DA", "SC", "EG"])]
        first.journeyKey = "journey"
        guard let second = first.changingTrains(at: date("12:30")) else {
            check("changing trains: the next train takes over", false, "no next train")
            return
        }
        check("changing trains: the next train takes over",
              second.tripNumber == next.tripNumber && second.boardingCode == "UN" && second.destinationCode == "EG")
        check("changing trains: same Live Activity", second.activityID == first.activityID)
        check("changing trains: waits for the next train", second.hasStartingStop)
        check("changing trains: the whole trip stays on the map", second.route == first.route)
        check("changing trains: none after the last", second.changingTrains(at: date("12:40")) == nil)
    }

    // MARK: Made-up trips

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TorontoTime.zone
        return calendar
    }()

    /// "12:06" (or "12:06:30") on a fixed weekday, Toronto time.
    private static func date(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 10
        components.hour = parts[0]
        components.minute = parts.count > 1 ? parts[1] : 0
        components.second = parts.count > 2 ? parts[2] : 0
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// A Lakeshore West train eastbound from Aldershot to Union (or another run),
    /// leaving each stop 4 minutes after the one before, from 11:20.
    private static func lakeshore(boarding: Int, destination: Int, line: String = "LW",
                                  codes: [String] = ["AL", "BU", "AP", "BO", "OA", "CL", "PO", "LO", "MI", "EX", "UN"],
                                  number: String? = nil) -> TrackedTrip {
        let start = date("11:20")
        let stops = codes.enumerated().map { index, code in
            TripDetail.Stop(index: index, code: code, time: start.addingTimeInterval(TimeInterval(index * 4 * 60)),
                            expected: nil, platform: nil)
        }
        let time = stops[boarding].time ?? start
        let row = BoardRow(tripNumber: number ?? "\(line)42", lineCode: line, lineName: line, destination: "",
                           stops: [], scheduled: time, expected: time, platform: nil, isExpress: false,
                           isCancelled: false)
        return TrackedTrip(row: row, boardingCode: codes[boarding], boardingIndex: boarding,
                           destinationIndex: destination, stops: stops, source: .schedule, startedAt: start)
    }

    /// A live report of the train: standing at a station ("at"), or on its way to it ("to").
    private static func train(at stop: String, status: String, time: Date, delay: Double = 0,
                              number: String = "LW42") -> LiveTrain {
        LiveTrain(trip: number, line: "LW", lat: 0, lon: 0, time: time, status: status, stop: stop, delay: delay,
                  moving: nil, course: nil)
    }

    // MARK: Results

    private static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        lines.append(passed ? "ok   \(name)" : "FAIL \(name)" + (detail().isEmpty ? "" : ": \(detail())"))
    }

    private static func write() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("self-check.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
