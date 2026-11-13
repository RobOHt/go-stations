#if DEBUG
import CoreLocation
import Foundation
import UIKit

/// Debug builds only (`-debugScene selfCheck`): checks of the tracking logic, run
/// on the simulator by the Screenshots workflow, which fails if any of them does.
/// Each writes a line to Documents/self-check.txt, "ok  name" or "FAIL name: why",
/// and the last line is "done". The trips are made up.
@MainActor
enum SelfCheck {
    private static var lines: [String] = []

    static func run() {
        lines = []
        NSLog("SelfCheck: starting")
        write()
        leaveReminder()
        reportGap()
        changingTrains()
        earlyArrival()
        missedTrain()
        progressiveBlur()
        getHere()
        cancelledTrain()
        plannedRoundCancelled()
        lines.append("done")
        write()
        NSLog("SelfCheck: done")
    }

    // MARK: The checks

    /// #15: the reminder to set off says which way the train goes.
    private static func leaveReminder() {
        let time = date("12:06")
        check("leave reminder: direction and terminus",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Port Credit", direction: "eastbound",
                                   terminus: "Union Station")
                  == "The 12:06 Lakeshore West line train from Port Credit, eastbound to Union Station.")
        check("leave reminder: no direction",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Port Credit", direction: nil,
                                   terminus: "Union Station")
                  == "The 12:06 Lakeshore West line train from Port Credit to Union Station.")
        check("leave reminder: nothing known about where it goes",
              TripAlerts.leaveBody(time: time, line: "Lakeshore West", from: "Port Credit", direction: nil, terminus: nil)
                  == "The 12:06 Lakeshore West line train from Port Credit.")
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

    /// #17: on its way to the end of its run ahead of time, a train gets there
    /// early; early for a station along the way, it still leaves that on time.
    private static func earlyArrival() {
        // Mimico 11:52, then 11:56, Union 12:00.
        let trip = lakeshore(boarding: 8, destination: 10)
        let intoUnion = trip.following(train(at: "UN", status: "to", time: date("11:57"), delay: -150),
                                       now: date("11:57:05"))
        check("early: in at the end of its run early", intoUnion.stops[10].expected == date("11:57:30"),
              "expected \(intoUnion.stops[10].expected.map(TorontoTime.clock) ?? "nil")")
        check("early: so the trip gets in early", intoUnion.arrival == date("11:57:30"))
        let alongTheWay = trip.following(train(at: "EX", status: "to", time: date("11:54"), delay: -90),
                                         now: date("11:54:05"))
        check("early: still leaves a station along the way on time", alongTheWay.stops[9].expected == date("11:56"),
              "expected \(alongTheWay.stops[9].expected.map(TorontoTime.clock) ?? "nil")")
        check("early: and isn't early at the end of its run yet", alongTheWay.stops[10].expected == date("12:00"))
        let late = trip.following(train(at: "UN", status: "to", time: date("11:59"), delay: 120), now: date("11:59:05"))
        check("early: a late train is still late", late.stops[10].expected == date("12:02"))
        // The app opened a few minutes after it got in: the last report is old,
        // but it still says the train got there.
        let opened = trip.following(train(at: "UN", status: "at", time: date("11:57:10")), now: date("12:01:30"))
        check("in: an old report of it at your stop still counts", opened.isSeenIn && opened.phase(at: date("12:01:30")) == .arrived,
              "seen in \(opened.isSeenIn)")
        check("in: when it got there", opened.stops[10].arrived == date("11:57:10"))
        let away = trip.following(train(at: "EX", status: "to", time: date("11:50")), now: date("11:55"))
        check("in: an old report short of your stop doesn't", away == trip)
    }

    /// #16: the first train of a trip from search left without you when you're
    /// nowhere near the line where it is, a couple of minutes after it left.
    private static func missedTrain() {
        let geometry = StartupStation.geometry
        // Oakville 11:36, Clarkson 11:40, … Union 12:00; planned from search.
        var trip = lakeshore(boarding: 4, destination: 10)
        trip.journeyKey = "journey"
        func verdict(_ trip: TrackedTrip, _ clock: String, at code: String?, accuracy: Double = 20) -> String {
            let now = date(clock)
            let location = code.flatMap { RailNetwork.shared.station($0) }.map {
                CLLocation(coordinate: $0.coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                           timestamp: now)
            }
            return "\(trip.boarding(at: now, location: location, on: geometry))"
        }
        let coming = trip.following(train(at: "OA", status: "to", time: date("11:35")), now: date("11:35:05"))
        check("missed: not before it leaves", verdict(coming, "11:35:10", at: "UN") == "notYet")
        // Seen at Oakville, then on its way to Clarkson: left at 11:36:30.
        let left = trip.following(train(at: "OA", status: "at", time: date("11:36")), now: date("11:36:05"))
            .following(train(at: "CL", status: "to", time: date("11:36:30")), now: date("11:36:35"))
        check("missed: seen leaving", left.leftBoarding(at: date("11:37")) == date("11:36:30"))
        check("missed: not straight away", verdict(left, "11:37", at: "UN") == "unsure")
        check("missed: far away when it's gone", verdict(left, "11:39", at: "UN") == "missed",
              verdict(left, "11:39", at: "UN"))
        check("missed: not when by the line where it is", verdict(left, "11:39", at: "CL") == "caught",
              verdict(left, "11:39", at: "CL"))
        check("missed: not on the platform just after", verdict(left, "11:39", at: "OA") == "caught")
        check("missed: not without a fix", verdict(left, "11:39", at: nil) == "unsure")
        check("missed: not on a rough fix", verdict(left, "11:39", at: "UN", accuracy: 2_000) == "unsure")
        // Well on its way (to Mimico): back on that platform is nowhere near it.
        let farOn = left.following(train(at: "MI", status: "to", time: date("11:52")), now: date("11:52:05"))
        check("missed: still on the platform once it's well on", verdict(farOn, "11:52:30", at: "OA") == "missed",
              verdict(farOn, "11:52:30", at: "OA"))
        check("missed: on it, well on", verdict(farOn, "11:52:30", at: "LO") == "caught")
        // Its reports stopped after Clarkson, and it was held up there: its times
        // have it near Mimico, but you're still on it at Clarkson.
        check("missed: not when held up after its reports stopped", verdict(left, "11:52", at: "CL") == "caught",
              verdict(left, "11:52", at: "CL"))
        // Nothing live: taken to have left 10 minutes after its time.
        check("missed: nothing live, not yet", verdict(trip, "11:44", at: "UN") == "notYet")
        check("missed: nothing live, long after its time", verdict(trip, "11:47", at: "UN") == "missed",
              verdict(trip, "11:47", at: "UN"))
        // Never reported (so maybe late, not gone): on the platform isn't missed.
        check("missed: nothing live, still on the platform", verdict(trip, "11:47", at: "OA") == "caught",
              verdict(trip, "11:47", at: "OA"))
        // Not a trip from search (tracked from a board: maybe someone else's train).
        var fromBoard = left
        fromBoard.journeyKey = nil
        check("missed: only trips from search", verdict(fromBoard, "11:39", at: "UN") == "notYet")
        // A later train of the trip.
        var later = left
        later.legIndex = 1
        check("missed: only the first train", verdict(later, "11:39", at: "UN") == "notYet")
        check("missed: what it says", TripAlerts.missedTitle(time: date("12:06"), terminus: "Union Station")
              == "You missed the 12:06 to Union Station")

        // Where GO's feed put the train itself, about when the fix was taken.
        func near(_ code: String, north metres: Double = 0) -> (Double, Double) {
            let coordinate = RailNetwork.shared.station(code)?.coordinate
            return ((coordinate?.latitude ?? 0) + metres / 111_000, coordinate?.longitude ?? 0)
        }
        func judged(_ trip: TrackedTrip, _ clock: String, you: (Double, Double), train: (Double, Double),
                    reportedAgo: TimeInterval) -> String {
            let now = date(clock)
            let fix = CLLocation(coordinate: .init(latitude: you.0, longitude: you.1), altitude: 0, horizontalAccuracy: 20,
                                 verticalAccuracy: -1, timestamp: now)
            let report = TrackedTrip.TrainReport(latitude: train.0, longitude: train.1,
                                                 time: now.addingTimeInterval(-reportedAgo))
            return "\(trip.boarding(at: now, location: fix, train: report, on: geometry))"
        }
        check("missed: beside the train", judged(left, "11:39", you: near("CL"), train: near("CL", north: 150),
                                                 reportedAgo: 10) == "caught")
        // At the office, 600 m from where you get on, the train two stops on.
        check("missed: near where you get on, the train well on",
              judged(left, "11:39", you: near("OA", north: 600), train: near("CL"), reportedAgo: 10) == "missed",
              judged(left, "11:39", you: near("OA", north: 600), train: near("CL"), reportedAgo: 10))
        // An older report: it could have gone that much further since.
        check("missed: an older report allows for the train moving on",
              judged(left, "11:39", you: near("CL", north: 1_500), train: near("CL"), reportedAgo: 60) == "caught")
        // Too far apart in time: back to the line around where it should be.
        check("missed: a report long before the fix says nothing",
              judged(left, "11:39", you: near("CL"), train: near("UN"), reportedAgo: 300) == "caught")
        // Known to have left from the worker, though the app hasn't seen it.
        let worker = trip.boarding(at: date("11:39"), location: CLLocation(
            coordinate: .init(latitude: near("UN").0, longitude: near("UN").1), altitude: 0, horizontalAccuracy: 20,
            verticalAccuracy: -1, timestamp: date("11:39")), left: date("11:36:30"), on: geometry)
        check("missed: on the worker's word that it left", "\(worker)" == "missed", "\(worker)")
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

    /// #19: the blur behind the search bar is Core Animation's variable blur alone,
    /// with none of UIKit's tint over it, in light and dark: the iOS it runs on
    /// still has what it's made with.
    private static func progressiveBlur() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .dark ? "dark" : "light"
            let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
            view.overrideUserInterfaceStyle = style
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
            view.updateTraitsIfNeeded()
            let filter = ProgressiveBlurView.install(on: view, radius: 10, fullAt: 0.75)
            check("blur (\(name)): the variable blur is there", filter != nil)
            let backdrop = ProgressiveBlurView.backdrop(of: view)
            let filters = backdrop?.layer.filters ?? []
            check("blur (\(name)): it alone on the backdrop",
                  filters.count == 1 && (filters.first as AnyObject?) === filter,
                  "\(filters.count) filters: \(filters.map { String(describing: $0) })")
            let shown = view.subviews.filter { $0 !== backdrop && $0 !== view.contentView && !$0.isHidden }
            check("blur (\(name)): no tint over it", shown.isEmpty,
                  shown.map { NSStringFromClass(type(of: $0)) }.joined(separator: ", "))
        }
        // How much of the radius, top to bottom: none at the top, all from three
        // quarters down.
        guard let mask = ProgressiveBlurView.mask(fullAt: 0.75), let data = mask.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            check("blur: its mask", false, "no mask")
            return
        }
        func alpha(at fraction: Double) -> Int {
            Int(bytes[Int(fraction * Double(mask.height - 1)) * mask.bytesPerRow + 3])
        }
        let shape = [0, 0.375, 0.75, 1].map(alpha)
        check("blur: its mask", shape[0] == 0 && (100...155).contains(shape[1]) && shape[2] == 255 && shape[3] == 255,
              "\(shape)")
    }

    /// A board's Get here: what it says, and when it's left out.
    private static func getHere() {
        check("get here: how long, from where",
              GetHereButton.detail(duration: "36 min", from: "Port Credit") == "36 min from Port Credit")
        check("get here: no train soon to take",
              GetHereButton.detail(duration: nil, from: "Port Credit") == "From Port Credit")
        check("get here: nowhere to start from", GetHereButton.detail(duration: "36 min", from: nil) == nil)
        check("get here: shown away from the station",
              GetHereButton.shows(isThere: false, isNearest: false, noTimetable: false))
        check("get here: not at the station", !GetHereButton.shows(isThere: true, isNearest: false, noTimetable: false))
        check("get here: not at the station nearest you",
              !GetHereButton.shows(isThere: false, isNearest: true, noTimetable: false))
        check("get here: not without a timetable",
              !GetHereButton.shows(isThere: false, isNearest: false, noTimetable: true))
    }

    /// A tracked train GO says won't stop where you get on (or off), or isn't
    /// running at all: what tracking makes of it, what you're told, and what its
    /// Live Activity shows (from the app, and from the worker's push).
    private static func cancelledTrain() {
        // Oakville (11:36) to Union (12:00).
        let trip = lakeshore(boarding: 4, destination: 10)
        let day = TorontoTime.dateWire(date("11:00"))
        let now = date("11:30")
        func feeds(_ entries: CancelledTrains.Entry...) -> CancelledTrains.List {
            CancelledTrains.List(entries: entries, fetchedAt: now)
        }
        let skipsHere = trip.cancellation(in: feeds(.init(trip: "LW42", day: day, skips: ["AL", "BU", "OA"])), now: now)
        check("cancelled: not stopping where you get on", skipsHere?.code == "OA", "\(String(describing: skipsHere))")
        check("cancelled: not stopping somewhere in between still takes you",
              trip.cancellation(in: feeds(.init(trip: "LW42", day: day, skips: ["CL", "PO"])), now: now) == nil)
        check("cancelled: another day's train with the same number",
              trip.cancellation(in: feeds(.init(trip: "LW42", day: "20261109", all: true)), now: now) == nil)
        let whole = trip.cancellation(in: feeds(.init(trip: "LW42", all: true)), now: now)
        check("cancelled: the whole trip, from the exceptions feed", whole != nil && whole?.code == nil)
        var riding = trip
        riding.stops[4].departed = date("11:37")
        check("cancelled: on it, where you got on doesn't matter",
              riding.cancellation(in: feeds(.init(trip: "LW42", day: day, skips: ["OA"])), now: now) == nil)
        check("cancelled: on it, not stopping where you get off",
              riding.cancellation(in: feeds(.init(trip: "LW42", day: day, skips: ["UN"])), now: now)?.code == "UN")

        // Tracked (and its Live Activity up) until 10 minutes after it was due,
        // and at least 10 minutes after it was found out.
        var cancelled = trip
        cancelled.cancelled = TripCancellation(code: "OA", since: date("11:20"))
        check("cancelled: tracked until a while after it was due", cancelled.endsAt == date("11:46"),
              "\(String(describing: cancelled.endsAt))")
        cancelled.cancelled?.since = date("11:40")
        check("cancelled: and a while after it was found out", cancelled.endsAt == date("11:50"))

        // What you're told.
        let network = RailNetwork.shared
        let noNext = TripAlerts.cancelledText(cancelled, back: false, network: network)
        check("cancelled: the alert", noNext.title == "Your 11:36 train is cancelled"
              && noNext.body == "It won't stop at Oakville. Open GO Stations to find another train.", "\(noNext)")
        let later = date("12:06")
        cancelled.cancelled?.next = BoardRow(tripNumber: "LW44", lineCode: "LW", lineName: "Lakeshore West",
                                             destination: "Union Station", stops: [], scheduled: later,
                                             expected: later, platform: nil, isExpress: false, isCancelled: false)
        let withNext = TripAlerts.cancelledText(cancelled, back: false, network: network)
        check("cancelled: the alert, with the next train",
              withNext.body == "It won't stop at Oakville. The next train to Union Station leaves at 12:06.",
              withNext.body)
        var notThere = riding
        notThere.cancelled = TripCancellation(code: "UN", since: now)
        check("cancelled: the alert, not stopping where you get off",
              TripAlerts.cancelledText(notThere, back: false, network: network).title
                  == "Your 11:36 train won't stop at Union Station")
        check("cancelled: running after all",
              TripAlerts.cancelledText(cancelled, back: true, network: network).title
                  == "Your 11:36 train is running after all")

        // Its Live Activity: where it won't stop, and the next train.
        let content = TripActivityController.content(for: cancelled, now: now)
        check("cancelled: the activity says where, and the next train",
              content?.state.cancelled?.index == 4 && content?.state.cancelled?.station == "Oakville"
                  && content?.state.cancelled?.next == later,
              "\(String(describing: content?.state.cancelled))")

        // The worker's push, as the widget reads it.
        let push = #"{"departure": 1794573600, "arrival": 1794574800, "hasDeparted": false, "#
            + #""stops": [{"name": "Oakville", "time": 1794573600}, {"name": "Union", "time": 1794574800}], "#
            + #""boardingIndex": 0, "destinationIndex": 1, "revision": 3, "#
        let skipped = try? JSONDecoder().decode(TripActivityAttributes.ContentState.self, from: Data(
            (push + #""cancelled": {"index": 0, "station": "Oakville", "next": 1794575400}}"#).utf8))
        check("cancelled: the worker's push reads",
              skipped?.cancelled?.index == 0 && skipped?.cancelled?.station == "Oakville"
                  && skipped?.cancelled?.next == Date(timeIntervalSince1970: 1794575400))
        let all = try? JSONDecoder().decode(TripActivityAttributes.ContentState.self,
                                            from: Data((push + #""cancelled": {}}"#).utf8))
        check("cancelled: the whole trip, from the worker", all?.cancelled != nil && all?.cancelled?.index == nil)
        let running = try? JSONDecoder().decode(TripActivityAttributes.ContentState.self,
                                                from: Data((push + #""platform": "2"}"#).utf8))
        check("cancelled: a running train's push has none", running != nil && running?.cancelled == nil)
    }

    /// Trips planned today go round trains GO says won't stop where you'd get on
    /// or off, and still ride through where they won't stop.
    private static func plannedRoundCancelled() {
        // Two made-up Lakeshore West trains, Aldershot to Union, half an hour apart
        // (minutes from the start of the service day).
        let times = [430, 442, 460, 465, 471, 480]
        let timetable = CommutePlanner.Timetable(
            generated: "self-check", patterns: [["AL", "BU", "OA", "CL", "PO", "UN"]],
            trips: [CommutePlanner.Timetable.Trip(number: "1925", line: "LW", pattern: 0, times: times),
                    CommutePlanner.Timetable.Trip(number: "1927", line: "LW", pattern: 0, times: times.map { $0 + 30 })],
            days: ["20261110": [0, 1]])
        let planner = CommutePlanner(network: StartupStation.network, timetable: timetable)
        func taken(skipping skips: [String], to dest: String) -> String? {
            var view = planner.view(day: "20261110", shifts: [-1440, 0, 1440])
            let feeds = CancelledTrains.List(entries: [.init(trip: "1925", day: "20261110", skips: skips)],
                                             fetchedAt: Date())
            view.close(feeds)
            return planner.journey(from: "OA", at: 450, to: dest, in: view)?.legs.first.map { view.trips[$0.trip].number }
        }
        check("planned: the first train, running", taken(skipping: [], to: "UN") == "1925")
        check("planned: not the one that won't stop where you get on", taken(skipping: ["AL", "BU", "OA"], to: "UN") == "1927")
        check("planned: through where it won't stop", taken(skipping: ["PO"], to: "UN") == "1925")
        check("planned: not the one that won't stop where you get off", taken(skipping: ["PO"], to: "PO") == "1927")
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
        let line = passed ? "ok   \(name)" : "FAIL \(name)" + (detail().isEmpty ? "" : ": \(detail())")
        lines.append(line)
        NSLog("SelfCheck: %@", line)
        // As it goes, so a crash part way shows how far it got.
        write()
    }

    private static func write() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = lines.joined(separator: "\n") + "\n"
            try text.write(to: directory.appendingPathComponent("self-check.txt"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("SelfCheck: couldn't write the results: %@", "\(error)")
        }
    }
}
#endif
