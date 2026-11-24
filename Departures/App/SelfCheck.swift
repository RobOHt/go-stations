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
    /// What the last run found, a line per check (read by the unit tests too).
    private(set) static var lines: [String] = []

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
        cancelledConnection()
        boardWays()
        runningLate()
        stationWithTheTrain()
        gpsOnly()
        realArrival()
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

    /// #21: on a trip with changes, the train you change to is looked up too:
    /// cancelled where you change to it or get off it, the Live Activity's change
    /// line says so, you're told, and once you're there it's the train followed,
    /// cancelled from the start.
    private static func cancelledConnection() {
        // Oakville (11:36) to Union (12:00), then the 12:08 Lakeshore East to Danforth.
        var trip = lakeshore(boarding: 4, destination: 10)
        let stops = ["UN", "DA", "SC", "EG", "GU", "RO", "PIN"].enumerated().map { index, code in
            TripDetail.Stop(index: index, code: code, time: date("12:08").addingTimeInterval(TimeInterval(index * 4 * 60)),
                            expected: nil, platform: nil)
        }
        let row = BoardRow(tripNumber: "LE7", lineCode: "LE", lineName: "Lakeshore East", destination: "Pickering",
                           stops: [], scheduled: date("12:08"), expected: date("12:08"), platform: nil,
                           isExpress: false, isCancelled: false)
        trip.onward = [OnwardLeg(row: row, boardingCode: "UN", destinationCode: "DA", stops: stops, source: .schedule)]
        trip.journeyKey = "journey"
        trip.legIndex = 0
        trip.legCount = 2
        let day = TorontoTime.dateWire(date("11:00"))
        let now = date("11:30")
        func feeds(_ entries: CancelledTrains.Entry...) -> CancelledTrains.List {
            CancelledTrains.List(entries: entries, fetchedAt: now)
        }
        let next = trip.onward?[0]
        check("connection: not stopping where you get off it",
              next?.cancellation(in: feeds(.init(trip: "LE7", day: day, skips: ["DA"])), now: now)?.code == "DA")
        check("connection: not stopping where you change to it",
              next?.cancellation(in: feeds(.init(trip: "LE7", day: day, skips: ["UN"])), now: now)?.code == "UN")
        let whole = next?.cancellation(in: feeds(.init(trip: "LE7", all: true)), now: now)
        check("connection: the whole trip", whole != nil && whole?.code == nil)
        check("connection: not stopping further on still takes you",
              next?.cancellation(in: feeds(.init(trip: "LE7", day: day, skips: ["SC", "EG"])), now: now) == nil)
        check("connection: not the train you're on",
              trip.cancellation(in: feeds(.init(trip: "LE7", day: day, all: true)), now: now) == nil)

        // The change line, and what you're told.
        var cancelled = trip
        cancelled.onward?[0].cancelled = TripCancellation(code: "DA", since: now)
        check("connection: the change line says so",
              TripActivityController.change(after: cancelled)?.cancelled == true
                  && TripActivityController.change(after: trip)?.cancelled == nil)
        check("connection: the trip says so", cancelled.cancelledConnection?.row.tripNumber == "LE7"
                  && trip.cancelledConnection == nil)
        let network = RailNetwork.shared
        let text = TripAlerts.connectionText(cancelled, back: false, network: network)
        check("connection: the alert", text.title == "Your 12:08 connection at Union is cancelled"
                  && text.body == "It won't stop at Danforth. Open GO Stations to plan another way there.", "\(text)")
        var elsewhere = cancelled
        elsewhere.onward?[0].cancelled = TripCancellation(code: nil, since: now)
        check("connection: the alert, the whole trip",
              TripAlerts.connectionText(elsewhere, back: false, network: network).body
                  == "Open GO Stations to plan another way to Danforth.")
        check("connection: running after all",
              TripAlerts.connectionText(cancelled, back: true, network: network).title
                  == "Your 12:08 connection at Union is running after all")

        // Kept across launches, and once in at Union, the train followed: cancelled.
        let kept = (try? JSONEncoder().encode(cancelled)).flatMap { try? JSONDecoder().decode(TrackedTrip.self, from: $0) }
        check("connection: kept across launches", kept?.onward?[0].cancelled?.code == "DA")
        let changed = cancelled.changingTrains(at: date("12:00"))
        check("connection: changed to, it's cancelled from the start",
              changed?.tripNumber == "LE7" && changed?.cancelled?.code == "DA" && changed?.cancelledIndex == 1,
              "\(String(describing: changed?.cancelled))")

        // The worker's push, as the widget reads it.
        let push = #"{"departure": 1794573600, "arrival": 1794574800, "hasDeparted": false, "#
            + #""change": {"station": "Union", "lineCode": "LE", "lineColorHex": "EE3124", "departure": 1794575280, "#
            + #""terminusName": "Pickering", "destinationName": "Danforth""#
        let said = try? JSONDecoder().decode(TripActivityAttributes.ContentState.self,
                                             from: Data((push + #", "cancelled": true}}"#).utf8))
        check("connection: the worker's push reads", said?.change?.cancelled == true && said?.cancelled == nil)
        let running = try? JSONDecoder().decode(TripActivityAttributes.ContentState.self,
                                                from: Data((push + "}}").utf8))
        check("connection: running, the push has none", running?.change != nil && running?.change?.cancelled == nil)
        let again = (try? JSONEncoder().encode(said)).flatMap {
            try? JSONDecoder().decode(TripActivityAttributes.ContentState.self, from: $0)
        }
        check("connection: kept by the activity", again?.change?.cancelled == true)
    }

    /// Which way each board shows its trains, for a made-up commuter from Oakville
    /// to Union: on the two boards, toward the other; between them, toward work on a
    /// weekday morning and home otherwise; elsewhere, all of them.
    private static func boardWays() {
        let home = "OA", work = "UN"
        let tuesdayMorning = date("07:30"), tuesdayEvening = date("17:30")
        let saturdayMorning = date("09:00").addingTimeInterval(4 * 86_400)
        let oakville = BoardWays(station: home, home: home, work: work)
        check("ways: home board, toward work", oakville.ways == [.work] && oakville.defaultWay(at: tuesdayEvening) == .work)
        let union = BoardWays(station: work, home: home, work: work)
        check("ways: work board, toward home", union.ways == [.home] && union.defaultWay(at: tuesdayMorning) == .home)
        let portCredit = BoardWays(station: "PO", home: home, work: work)
        check("ways: between them, both ways", portCredit.ways == [.work, .home] && portCredit.isOnCommute)
        check("ways: between them, toward work on a weekday morning",
              portCredit.defaultWay(at: tuesdayMorning) == .work)
        check("ways: between them, toward home in the evening", portCredit.defaultWay(at: tuesdayEvening) == .home)
        check("ways: between them, toward home on a weekend", portCredit.defaultWay(at: saturdayMorning) == .home)
        let bramalea = BoardWays(station: "BE", home: home, work: work)
        check("ways: off the way, all directions", !bramalea.isOnCommute && bramalea.defaultWay(at: tuesdayMorning) == nil
              && bramalea.ways == [.work, .home])
        let aldershot = BoardWays(station: "AL", home: home, work: work)
        check("ways: past home, all directions", !aldershot.isOnCommute && aldershot.defaultWay(at: tuesdayMorning) == nil)

        // Which trains each way takes from Port Credit: on to Long Branch is toward
        // Union (work); back to Clarkson, toward Oakville (home).
        let east = BoardRow(tripNumber: "LW1", lineCode: "LW", lineName: "Lakeshore West", destination: "Union Station",
                            stops: [], scheduled: tuesdayMorning, expected: tuesdayMorning, platform: nil,
                            isExpress: false, isCancelled: false, stopCodes: ["LO", "MI", "EX", "UN"])
        let west = BoardRow(tripNumber: "LW2", lineCode: "LW", lineName: "Lakeshore West", destination: "Aldershot",
                            stops: [], scheduled: tuesdayMorning, expected: tuesdayMorning, platform: nil,
                            isExpress: false, isCancelled: false, stopCodes: ["CL", "OA", "BO", "AL"])
        let toWork = portCredit.direction(toward: .work), toHome = portCredit.direction(toward: .home)
        check("ways: toward work, the trains to Union",
              toWork?.includes(east) == true && toWork?.includes(west) == false)
        check("ways: toward home, the trains to Oakville",
              toHome?.includes(west) == true && toHome?.includes(east) == false)
        check("ways: from Bramalea, toward work is toward Union",
              bramalea.direction(toward: .work)?.includes(stopCodes: ["MA", "ET", "WE", "BL", "UN"]) == true)
        check("ways: without home or work, nothing to pick",
              BoardWays.of(station: "PO", home: nil, work: nil) == nil)
        let homeOnly = BoardWays(station: "PO", home: home, work: nil)
        check("ways: home only, toward home or all", homeOnly.ways == [.home] && homeOnly.defaultWay(at: tuesdayMorning) == nil)
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

    /// Opening the app while tracking a train: the station the map shows with it.
    /// Once it has left where you get on, the next one it stops at; still on its way
    /// to you, the one you get on at.
    private static func stationWithTheTrain() {
        // Aldershot to Union, getting on at Oakville (4).
        let trip = lakeshore(boarding: 4, destination: 10)
        check("station with the train: on its way to you, where you get on", trip.stationToShow(reached: 2) == "OA")
        check("station with the train: standing at your station, your station", trip.stationToShow(reached: 4) == "OA")
        // Seen leaving Oakville.
        var left = trip
        left.stops[4].departed = date("11:36")
        check("station with the train: just left where you get on, Clarkson", left.stationToShow(reached: 4) == "CL")
        check("station with the train: between Clarkson and Port Credit, Port Credit",
              left.stationToShow(reached: 5) == "PO")
        check("station with the train: standing at Long Branch, Mimico", left.stationToShow(reached: 7) == "MI")
        check("station with the train: at the end of its run, none ahead", left.stationToShow(reached: 10) == nil)
        // Back in the app after a while: the map already draws it past Oakville by
        // its live reports, before its times catch up.
        check("station with the train: drawn past where you get on, the next one ahead",
              trip.stationToShow(reached: 6) == "LO")
    }

    /// A real train's reports coming into a station (how far short of the station's
    /// own spot each had it, 15 seconds apart), and where the replay has the train
    /// at a few moments, as worked out beforehand by the script the replay was
    /// tried with: what the app draws is what was tried. (On a made-up line.)
    private static func realArrival() {
        let codes = ["AA", "BB", "CC"]
        let west = -79.60, apart = 0.05, latitude = 43.60
        let run = TrainRun(codes: codes) { a, b in
            guard let from = codes.firstIndex(of: a), let to = codes.firstIndex(of: b) else { return nil }
            return CommutePlanner.Path([
                TrackGeometry.Point(latitude: latitude, longitude: west + apart * Double(from)),
                TrackGeometry.Point(latitude: latitude, longitude: west + apart * Double(to)),
            ])
        }
        let hop = run.starts[1]
        let short: [Double] = [5198, 5024, 4848, 4639, 4387, 4108, 3817, 3516, 3206, 2895, 2570, 2239, 1897, 1553,
                               1221, 903, 599, 348, 249, 180, 111, 69, 66, 65, 65, 64]
        let start = date("12:00:00")
        // Its first `count` reports, heading for CC.
        func reports(_ count: Int) -> [LiveTrain] {
            (0..<min(count, short.count)).map { index in
                LiveTrain(trip: "LW42", line: "LW", lat: latitude, lon: west + apart * (run.length - short[index]) / hop,
                          time: start.addingTimeInterval(Double(index) * 15), status: "to", stop: "CC", delay: 0,
                          moving: nil, course: nil)
            }
        }
        // (How many reports are in, seconds after the first report, metres short of CC.)
        let moments: [(count: Int, after: Double, short: Double, what: String)] = [
            (2, 20, 4966.0, "two reports in: carried on 5 s past the second"),
            (5, 52, 4527.0, "between its fourth and fifth reports"),
            (5, 68, 4252.6, "running: carried on 8 s past its latest"),
            (12, 200, 1466.7, "its reports stopped: carried on 35 s"),
            (12, 260, 1356.3, "its reports stopped: held where 40 s took it"),
            (16, 240, 629.0, "coming up to the station: carried on 15 s, slowing"),
            (17, 255, 365.2, "braking: carried on 15 s"),
            (18, 275, 250.0, "nearly there: carried on, but stopping well short of the station"),
            (19, 282, 249.0, "from there on: where its report has it, no further"),
            (22, 308, 85.6, "coming in: between two reports"),
            (26, 400, 64.0, "standing: where it stands"),
        ]
        for moment in moments {
            var drawn: Double?
            if let track = TrainReplay.track(of: reports(moment.count), on: run) {
                drawn = TrainReplay.along(track.samples, track.slopes, moving: track.isMoving, on: run,
                                          at: start.timeIntervalSinceReferenceDate + moment.after)
            }
            check("a real arrival: \(moment.what)", drawn.map { abs((run.length - $0) - moment.short) < 1.5 } ?? false,
                  "\(drawn.map { run.length - $0 } ?? -1) m short, of \(moment.short)")
        }
    }

    /// The one rule for where a train is drawn: where its latest live report (the GPS
    /// position GO gives for it) has it. Not at a station's own spot when it stands
    /// short of it, not further on than its latest report, and still by its position
    /// when GO names no stop of its run. Its speed: what it covered between two
    /// reports, or none. (A made-up line.)
    private static func gpsOnly() {
        // Due east from AA through BB to CC, 0.05 degrees of longitude apart.
        let codes = ["AA", "BB", "CC"]
        let west = -79.60, apart = 0.05, latitude = 43.60
        let run = TrainRun(codes: codes) { a, b in
            guard let from = codes.firstIndex(of: a), let to = codes.firstIndex(of: b) else { return nil }
            return CommutePlanner.Path([
                TrackGeometry.Point(latitude: latitude, longitude: west + apart * Double(from)),
                TrackGeometry.Point(latitude: latitude, longitude: west + apart * Double(to)),
            ])
        }
        // From one station to the next, in metres.
        let hop = run.starts[1]
        // A report `along` the line (0 at AA, 1 at BB, 2 at CC), `north` degrees off it.
        func report(_ along: Double, north: Double = 0, status: String? = "to", stop: String? = "BB",
                    at clock: String) -> LiveTrain {
            LiveTrain(trip: "LW42", line: "LW", lat: latitude + north, lon: west + apart * along, time: date(clock),
                      status: status, stop: stop, delay: 0, moving: nil, course: nil)
        }

        let between = run.place(report(0.4, at: "12:00"))
        check("gps only: between two stations, where its position is",
              between.map { abs($0.distance - 0.4 * hop) < 1 && $0.stop == 1 && !$0.isAt } ?? false,
              "\(between?.distance ?? -1) m of \(hop)")
        let short = run.place(report(0.96, status: "at", at: "12:00"))
        check("gps only: standing short of the station's own spot, where it stands",
              short.map { abs($0.distance - 0.96 * hop) < 1 && $0.stop == 1 && $0.isAt } ?? false,
              "\(short?.distance ?? -1) m of \(hop)")
        let signal = run.place(report(1.5, stop: "SIG9", at: "12:00"))
        check("gps only: GO names a signal, still where its position is, heading for the next stop along",
              signal.map { abs($0.distance - 1.5 * hop) < 1 && $0.stop == 2 && !$0.isAt } ?? false,
              "\(signal?.distance ?? -1) m, stop \(signal?.stop ?? -1)")
        let unnamed = run.place(report(0.3, status: nil, stop: nil, at: "12:00"))
        check("gps only: GO names no stop, still where its position is",
              unnamed.map { abs($0.distance - 0.3 * hop) < 1 && $0.stop == 1 } ?? false,
              "\(unnamed?.distance ?? -1) m, stop \(unnamed?.stop ?? -1)")

        // A run starts and ends at its first and last stations' own spots on the
        // line, and a train stands with its GPS a little way from those: short of
        // the start before it sets off, past the end once it's in. It's placed and
        // drawn there (straight on along the track), not held at the spot.
        let waiting = run.place(report(-0.03, status: "at", stop: "AA", at: "12:00"))
        check("gps only: short of where its run starts, where its position is",
              waiting.map { abs($0.distance + 0.03 * hop) < 1 && $0.off < 1 && $0.stop == 0 && $0.isAt } ?? false,
              "\(waiting?.distance ?? 1) m, \(waiting?.off ?? -1) m off")
        let overrun = run.place(report(2.04, status: "at", stop: "CC", at: "12:00"))
        check("gps only: past where its run ends, where its position is",
              overrun.map { abs($0.distance - 2.04 * hop) < 1 && $0.off < 1 && $0.stop == 2 && $0.isAt } ?? false,
              "\(overrun?.distance ?? -1) m of \(run.length), \(overrun?.off ?? -1) m off")
        let ahead = run.point(at: -0.03 * hop).map { TrackGeometry.coordinate($0.point) }
        check("gps only: drawn short of where its run starts, straight on along its track",
              ahead.map { abs($0.longitude - (west - 0.03 * apart)) < 0.00002 && abs($0.latitude - latitude) < 0.00002 }
                  ?? false, "\(String(describing: ahead))")
        let past = run.point(at: 2.04 * hop)
        check("gps only: drawn past where its run ends, still heading the way its track runs",
              past.map { abs(TrackGeometry.coordinate($0.point).longitude - (west + 2.04 * apart)) < 0.00002
                  && abs(($0.heading ?? -1) - 90) < 1 } ?? false, "\(String(describing: past))")
        let leaving = [report(-0.03, status: "at", stop: "AA", at: "12:00:00"),
                       report(-0.03, status: "at", stop: "AA", at: "12:00:15"),
                       report(-0.02, status: "at", stop: "AA", at: "12:00:30")]
        let left = TrainReplay.position(of: leaving, on: run)
        check("gps only: setting off from short of where its run starts, moving from the first metres",
              left.map { ($0.speed ?? 0) > 1 && abs($0.distance + 0.02 * hop) < 1 } ?? false,
              "\(left?.speed ?? -1) m/s at \(left?.distance ?? 1) m")
        let yardBound = TrainReplay.position(of: [report(2.2, status: "at", stop: "CC", at: "12:00")], on: run)
        check("gps only: far past the end of its run (off to a yard), drawn where it is, off its line",
              yardBound?.away != nil, "\(yardBound?.distance ?? -1) m of \(run.length)")

        // Two reports 15 seconds apart: it's where the later one has it, no further.
        let latest = TrainReplay.position(of: [report(0.2, at: "12:00:00"), report(0.3, at: "12:00:15")], on: run)
        check("gps only: where its latest report has it, not past it",
              latest.map { abs($0.distance - 0.3 * hop) < 1 } ?? false, "\(latest?.distance ?? -1) m of \(hop)")
        var measured = false
        if let speed = latest?.speed { measured = abs(speed - 0.1 * hop / 15) < 0.1 }
        check("gps only: its speed is what it covered between two reports", measured,
              "\(latest?.speed ?? -1) m/s")
        let one = TrainReplay.position(of: [report(0.2, at: "12:00")], on: run)
        check("gps only: one report on the move, no speed made up", one != nil && one?.speed == nil)
        let standing = TrainReplay.position(of: [report(1, status: "at", at: "12:00")], on: run)
        check("gps only: one report standing at a station, no speed made up either",
              standing != nil && standing?.speed == nil)
        // (GO says a train is standing at a station while it's still pulling in.)
        let pullingIn = TrainReplay.position(of: [report(0.97, status: "at", at: "12:00:00"),
                                                  report(0.99, status: "at", at: "12:00:15")], on: run)
        check("gps only: pulling in while GO has it standing there, as fast as it covers the ground",
              (pullingIn?.speed ?? 0) > 1, "\(pullingIn?.speed ?? -1) m/s")
        let still = TrainReplay.position(of: [report(0.5, at: "12:00:00"), report(0.5, at: "12:00:15")], on: run)
        check("gps only: two reports in the same place, not moving", still?.speed == 0)
        // GO reports some trains every 5 seconds. Coming in at 7 km/h, one moves about
        // 10 m between two of them, less than a standing train's GPS wobbles: its speed
        // is measured over three of those, not read as standing.
        let crawl = 0.0025
        let often = (0...3).map { report(0.5 + crawl * Double($0), at: "12:00:\(String(format: "%02d", $0 * 5))") }
        let crawling = TrainReplay.position(of: often, on: run)
        var paced = false
        if let speed = crawling?.speed { paced = abs(speed - 3 * crawl * hop / 15) < 0.1 }
        check("gps only: reported every 5 seconds and crawling, its speed over the last 15", paced,
              "\(crawling?.speed ?? -1) m/s")
        check("gps only: two reports 5 seconds apart, no speed yet",
              TrainReplay.position(of: Array(often.prefix(2)), on: run).map { $0.speed == nil } ?? false)
        // Reports missed for a minute: where it is by the new one, but not how fast it's going now.
        let gap = TrainReplay.position(of: [report(0.2, at: "12:00:00"), report(0.4, at: "12:01:00")], on: run)
        check("gps only: a minute between two reports, no speed from them",
              gap.map { $0.speed == nil && abs($0.distance - 0.4 * hop) < 1 } ?? false)

        // Among its stops (its marker in the list of them): as far along the track
        // between two of them as its position is.
        check("gps only: among its stops, as far between two of them as its position is",
              abs(run.progress(at: 0.4 * hop) - 0.4) < 0.001 && abs(run.progress(at: 1.25 * hop) - 1.25) < 0.001,
              "\(run.progress(at: 0.4 * hop)), \(run.progress(at: 1.25 * hop))")
        check("gps only: among its stops, at a stop when it's there",
              abs(run.progress(at: hop) - 1) < 0.001 && run.progress(at: 0) == 0, "\(run.progress(at: hop))")
        check("gps only: among its stops, at the end of its run and no further",
              abs(run.progress(at: run.length) - 2) < 0.001 && abs(run.progress(at: run.length + 500) - 2) < 0.001,
              "\(run.progress(at: run.length)), \(run.progress(at: run.length + 500))")

        // Well off its line (a yard, a detour): where the report has it, not on the line.
        let yard = TrainReplay.position(of: [report(0.5, north: 0.01, at: "12:00")], on: run)
        check("gps only: well off its line, drawn where it is", yard?.away != nil)
        let beside = TrainReplay.position(of: [report(0.5, north: 0.0005, at: "12:00")], on: run)
        check("gps only: a few metres off its line, drawn on it", beside != nil && beside?.away == nil)
        check("gps only: no reports, nowhere", TrainReplay.position(of: [], on: run) == nil)

        // Drawn gliding through its reports, a few seconds behind them (TrainReplay.delay).
        func drawn(_ reports: [LiveTrain], at clock: String) -> Double {
            guard let track = TrainReplay.track(of: reports, on: run) else { return -1 }
            return TrainReplay.position(on: track, of: run, at: date(clock)).distance
        }
        let behind = TrainReplay.delay
        // 0.05 of the way to BB every 15 seconds.
        let pace = 0.05 * hop / 15
        let steady = [report(0.20, at: "12:00:00"), report(0.25, at: "12:00:15"), report(0.30, at: "12:00:30")]
        let midway = drawn(steady, at: "12:00:\(String(format: "%02d", Int(22 + behind)))")
        check("gliding: between two reports, as far between them",
              abs(midway - (0.25 * hop + 7 * pace)) < 3, "\(midway) m, of \(0.25 * hop + 7 * pace)")
        let carried = drawn(steady, at: "12:00:\(String(format: "%02d", Int(40 + behind)))")
        check("gliding: past its latest report, carried on at the pace it had",
              abs(carried - (0.30 * hop + 10 * pace)) < 5, "\(carried) m, of \(0.30 * hop + 10 * pace)")
        let held = drawn(steady, at: "12:03:00")
        check("gliding: its reports stopped, carried on no longer than a while past the last",
              abs(held - (0.30 * hop + TrainReplay.ahead * pace)) < 5, "\(held) m")
        // Heading for BB, 0.15 of the way short of it: slowing for it before long.
        let coming = [report(0.80, at: "12:00:00"), report(0.85, at: "12:00:15")]
        let slowing = drawn(coming, at: "12:00:\(String(format: "%02d", Int(45 + behind)))") - 0.85 * hop
        check("gliding: slowing for the station it's heading for", slowing > 270 && slowing < 330,
              "\(slowing) m on, of \(30 * pace) at its pace")
        // It may come to a stand anywhere in the last stretch before the station's
        // own spot (TrainRun.clear): carried on to there, and no nearer.
        let there = drawn([report(0.85, at: "12:00:00"), report(0.90, at: "12:00:15")], at: "12:02:00")
        check("gliding: carried on until it's well short of the station, no nearer",
              abs(there - (hop - TrainRun.clear)) < 1, "\(hop - there) m short of it")
        // Already nearer than that (0.05 of the way short of BB, about 200 m): only
        // its reports place it.
        let near = drawn([report(0.90, at: "12:00:00"), report(0.95, at: "12:00:15")], at: "12:02:00")
        check("gliding: nearer the station than that, where its report has it and no further",
              0.05 * hop < TrainRun.clear && abs(near - 0.95 * hop) < 0.05, "\(hop - near) m short of it")
        // Standing, its GPS a metre further on after a while: not taken for setting off.
        let stirred = [report(0.5, at: "12:00:00"), report(0.5, at: "12:00:15"), report(0.50025, at: "12:00:30")]
        check("gliding: a standing train's GPS wobbling a metre on, it still stands",
              abs(drawn(stirred, at: "12:01:10") - 0.50025 * hop) < 0.05,
              "\(drawn(stirred, at: "12:01:10") - 0.50025 * hop) m on")
        let parked = [report(0.5, at: "12:00:00"), report(0.5, at: "12:00:15")]
        check("gliding: standing, it stands where it stood", abs(drawn(parked, at: "12:01:00") - 0.5 * hop) < 0.01)
        // Setting off from short of where its run starts: on its way from there, not
        // held at its first station's spot until its GPS is past it.
        let setOff = drawn(leaving, at: "12:00:\(String(format: "%02d", Int(22 + behind)))")
        check("gliding: setting off from short of where its run starts, on its way from there",
              setOff > -0.03 * hop && setOff < -0.02 * hop, "\(setOff) m")
        check("gliding: one report, where that has it and no further",
              abs(drawn([report(0.2, at: "12:00:00")], at: "12:00:40") - 0.2 * hop) < 0.01)
        let wobble = [report(0.5, at: "12:00:00"), report(0.4995, at: "12:00:15")]
        check("gliding: GPS wobble never takes it back", abs(drawn(wobble, at: "12:00:40") - 0.5 * hop) < 0.01,
              "\(drawn(wobble, at: "12:00:40") - 0.5 * hop) m")
        // One position 0.01 of the way further on than its pace would have it.
        let strayed = [report(0.20, at: "12:00:00"), report(0.25, at: "12:00:15"), report(0.31, at: "12:00:30")]
        let flung = drawn(strayed, at: "12:00:\(String(format: "%02d", Int(40 + behind)))") - 0.31 * hop
        check("gliding: a position that strayed ahead doesn't fling it on", flung > 0 && flung <= 0.06 * hop / 15 * 10 + 1,
              "\(flung) m on")

        // The backup, for a train with no live position: where its times put it.
        let timed = run.position(of: .moving(from: 0, fraction: 0.5))
        check("backup: by its times, the fraction of the way between two stops they make it",
              timed.map { abs($0.distance - 0.5 * hop) < 1 && !$0.isLive && $0.speed == nil && $0.stop == 1 && !$0.isAt }
                  ?? false)
        check("backup: by its times, standing at a stop",
              run.position(of: .stopped(at: 1)).map { abs($0.distance - hop) < 1 && $0.isAt && !$0.isLive } ?? false)
        check("backup: by its times, waiting at its first stop",
              run.position(of: .waiting(departs: date("12:00"))).map { $0.distance == 0 && $0.isAt } ?? false)
        check("backup: by its times, in at its last stop",
              run.position(of: .arrived(at: date("12:00"))).map { abs($0.distance - run.length) < 1 && $0.stop == 2 }
                  ?? false)
        check("backup: no times to go by, nowhere", run.position(of: .unknown) == nil)

        // Whether the list of live trains is still awaited: nothing goes by the
        // timetable yet (it would be drawn in one place, then moved).
        let opened = date("12:00:00")
        var contact = LiveContact()
        contact.want(at: opened)
        check("awaiting live: just opened, nothing in yet",
              contact.isPending(at: opened.addingTimeInterval(1), listedAt: nil))
        check("awaiting live: a few seconds on with nothing in, no longer",
              !contact.isPending(at: opened.addingTimeInterval(LiveContact.patience + 1), listedAt: nil))
        check("awaiting live: not once the list is in",
              !contact.isPending(at: opened.addingTimeInterval(1), listedAt: opened.addingTimeInterval(0.5)))
        // Offline: fetches fail every few seconds.
        contact.attemptedAt = opened.addingTimeInterval(12)
        contact.want(at: opened.addingTimeInterval(17))
        check("awaiting live: offline, a failed fetch doesn't start the wait again",
              !contact.isPending(at: opened.addingTimeInterval(18), listedAt: nil))
        contact.want(at: opened.addingTimeInterval(600))
        check("awaiting live: back after a while away, awaited again",
              contact.isPending(at: opened.addingTimeInterval(601), listedAt: opened.addingTimeInterval(-10)))
    }

    /// A live report of the train: standing at a station ("at"), or on its way to it ("to").
    private static func train(at stop: String, status: String, time: Date, delay: Double = 0,
                              number: String = "LW42") -> LiveTrain {
        LiveTrain(trip: number, line: "LW", lat: 0, lon: 0, time: time, status: status, stop: stop, delay: delay,
                  moving: nil, course: nil)
    }

    // MARK: Results

    /// A train running 24 minutes late: as late at the end of its run, where
    /// Metrolinx leaves the time blank, as at the stop before; and the alerts its
    /// stops show. (Made up.)
    private static func runningLate() {
        func stop(_ index: Int, _ code: String, _ time: String, _ expected: String?) -> TripDetail.Stop {
            TripDetail.Stop(index: index, code: code, time: date(time), expected: expected.map { date($0) }, platform: nil)
        }
        let stops = BoardService.carryingDelays([
            stop(0, "UN", "17:13", nil), stop(1, "PO", "17:38", "18:02"), stop(2, "OA", "17:46", "18:10"),
            stop(3, "BU", "17:56", "18:20"), stop(4, "AL", "18:03", nil),
        ])
        check("late: as late at the end of its run", stops[4].expected == date("18:27"),
              "\(String(describing: stops[4].expected))")
        check("late: nothing made up before its first live time", stops[0].expected == nil)
        check("late: live times kept", stops[1].expected == date("18:02") && stops[3].expected == date("18:20"))
        let onTime = BoardService.carryingDelays([stop(0, "BU", "17:56", "17:56"), stop(1, "AL", "18:03", nil)])
        check("late: on time, nothing carried", onTime[1].expected == nil)

        // Past the last stop Metrolinx times, no live time ahead at all: as late as
        // its live report says, from the stop it's on its way to.
        let blanks = TripDetail.fillingDelay([stop(0, "UN", "17:13", nil), stop(1, "PO", "17:38", nil),
                                              stop(2, "AL", "18:03", nil)], late: 1800, from: 1)
        check("late: blank times ahead as late as its live report",
              blanks[0].expected == nil && blanks[1].expected == date("18:08") && blanks[2].expected == date("18:33"))
        // Tracking it: a refresh bringing blank times ahead keeps them that late, so
        // tracking doesn't end when its timetable has it in.
        let tracked = lakeshore(boarding: 0, destination: 10)
            .following(train(at: "MI", status: "to", time: date("12:20"), delay: 1800), now: date("12:20:05"))
        let refreshed = TrackedTrip(row: tracked.row, boardingCode: "AL", boardingIndex: 0, destinationIndex: 10,
                                    stops: lakeshore(boarding: 0, destination: 10).stops, source: .live,
                                    startedAt: tracked.startedAt).carrying(tracked)
        check("late: tracking keeps it late through a refresh with blank times",
              refreshed.stops[10].expected == date("12:30") && (refreshed.endsAt ?? .distantPast) > date("12:25"),
              "\(String(describing: refreshed.stops[10].expected)), ends \(String(describing: refreshed.endsAt))")

        func message(_ category: String, sub: String? = nil, lines: [String] = [], trips: [String] = [],
                     _ subject: String) -> AlertsResponse.Message {
            AlertsResponse.Message(code: subject, subjectEnglish: subject, subjectFrench: nil, bodyEnglish: nil,
                                   bodyFrench: nil, category: category, subCategory: sub,
                                   lines: lines.map { AlertsResponse.LineRef(code: $0) }, stops: nil,
                                   trips: trips.map { AlertsResponse.TripRef(tripNumber: $0) })
        }
        let response = AlertsResponse(metadata: nil, messages: .init(message: [
            message("Service Disruption", sub: "Train Delay", lines: ["LW"], "Lakeshore West - Signal issue near Port Credit GO"),
            message("Service Disruption", sub: "Information", lines: ["LW"], "Nov. 21: Service adjustments"),
            message("Amenity", lines: ["LW"], "Elevators out of service"),
            message("Service Disruption", lines: ["GT"], "Kitchener - Delays"),
            message("Information", trips: ["1234"], "About this train"),
        ]))
        let row = BoardRow(tripNumber: "1234", lineCode: "LW", lineName: "Lakeshore West", destination: "Aldershot",
                           stops: [], scheduled: date("17:13"), expected: date("17:13"), platform: nil,
                           isExpress: false, isCancelled: false)
        let shown = BoardService.lineAlerts(response, row: row, network: RailNetwork.shared).map(\.subjectEnglish)
        check("late: its line's disruptions now and its own alerts, not planned changes, lifts or other lines",
              shown == ["Lakeshore West - Signal issue near Port Credit GO", "About this train"], "\(shown)")
        // Kitchener's trains are GT in GO's alerts.
        let kitchener = BoardRow(tripNumber: "999", lineCode: "KI", lineName: "Kitchener", destination: "Kitchener",
                                 stops: [], scheduled: date("17:13"), expected: date("17:13"), platform: nil,
                                 isExpress: false, isCancelled: false)
        check("late: a line by GO's other code",
              BoardService.lineAlerts(response, row: kitchener, network: RailNetwork.shared).map(\.subjectEnglish)
                == ["Kitchener - Delays"])
    }

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
