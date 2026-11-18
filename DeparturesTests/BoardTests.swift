import Foundation
import Testing
@testable import Departures

/// Everything that reads GO's feeds through `FakeNetwork`, one test at a time.
@Suite(.serialized)
struct GOFeeds {}

/// A station's board, with GO's feeds failing, frozen, or saying the same thing in
/// other shapes. Written from what a rider should see, before looking at how the
/// board reads them. Trip numbers are made up (and differ per test: the board keeps
/// what it has looked up).
extension GOFeeds {
    @Suite("A station's board")
    struct Board {
        let oakville = RailNetwork.shared.station("OA")!
        let union = RailNetwork.shared.station("UN")!

        init() async {
            FakeNetwork.start()
            await ScheduleStore.shared.refreshIfNeeded()
            _ = await CancelledTrains.shared.list(maxAge: 0)
        }

        func load(_ station: Station? = nil) async throws -> BoardSnapshot {
            try await BoardService.shared.board(for: station ?? oakville)
        }

        func row(_ trip: String, in board: BoardSnapshot, sourceLocation: SourceLocation = #_sourceLocation) throws -> BoardRow {
            try #require(board.rows.first { $0.tripNumber == trip }, "no \(trip) in \(board.rows.map(\.tripNumber))",
                         sourceLocation: sourceLocation)
        }

        // MARK: GO failing

        static let failures: [FakeNetwork.Reply] = [
            .failure(.timedOut),
            .failure(.notConnectedToInternet),
            .json(GO.error("502", "Metrolinx answered 500"), status: 502),
            .json(GO.error("503", "Live data isn't set up yet"), status: 503),
            .json(GO.error("429", "Too many requests"), status: 429),
            .page("<html><body>Down for maintenance</body></html>"),
            .page(#"{"Metadata":{"ErrorCode":"200"},"NextService":{"Li"#, type: "application/json"),
            .page("", type: "application/json"),
            .json(GO.error("500", "Internal error")),
            .json(["Metadata": GO.ok(), "NextService": "No data"]),
        ]

        @Test("GO failing: the timetable's trains, saying why", arguments: Board.failures)
        func failing(_ reply: FakeNetwork.Reply) async throws {
            FakeNetwork.set("/Stop/NextService/OA", reply)
            let board = try await load()
            #expect(board.source == .schedule)
            #expect(board.note?.isEmpty == false)
            #expect(!board.rows.isEmpty, "no trains from the timetable")
            #expect(board.rows.allSatisfy { $0.scheduled > Date().addingTimeInterval(-120) }, "trains already gone")
        }

        @Test("a frozen feed, every train in it gone a day ago: the timetable's trains, not those")
        func frozen() async throws {
            let gone = Date().addingTimeInterval(-86400)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2001", at: gone), GO.line("2002", at: gone.addingTimeInterval(1200)),
            ], metadata: GO.ok(gone))))
            let board = try await load()
            #expect(!board.rows.contains { ["2001", "2002"].contains($0.tripNumber) })
            #expect(board.source == .schedule)
            #expect(!board.rows.isEmpty)
        }

        @Test("the cancellations or alerts feed failing: the board is still live")
        func sideFeedsFailing() async throws {
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([GO.line("2011", at: Toronto.inMinutes(12))])))
            FakeNetwork.set("/ServiceUpdate/Exceptions/Train", .failure(.timedOut))
            FakeNetwork.set("/ServiceUpdate/ServiceAlert/All", .page("<html>busy</html>", status: 500))
            FakeNetwork.set("/live/cancelled", .failure(.timedOut))
            _ = await CancelledTrains.shared.list(maxAge: 0)
            let board = try await load()
            #expect(board.source == .live)
            #expect(board.rows.first?.tripNumber == "2011")
        }

        @Test("Union's own board failing: GO's departures for Union, still live")
        func unionBoardFailing() async throws {
            FakeNetwork.set("/ServiceUpdate/UnionDepartures/All", .page("busy", status: 503))
            FakeNetwork.set("/Stop/NextService/UN", .json(GO.nextService([
                GO.line("2021", at: Toronto.inMinutes(9), stop: "UN", direction: "LW - Aldershot GO"),
            ])))
            let board = try await load(union)
            #expect(board.source == .live)
            #expect(board.rows.contains { $0.tripNumber == "2021" })
        }

        // MARK: Times

        @Test("no live time, or an early one: on time; a later one: that late")
        func times() async throws {
            let soon = Toronto.inMinutes(15)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2031", at: soon),
                GO.line("2032", at: soon.addingTimeInterval(300), expected: soon.addingTimeInterval(120)),
                GO.line("2033", at: soon.addingTimeInterval(600), expected: soon.addingTimeInterval(900)),
            ])))
            let board = try await load()
            let blank = try row("2031", in: board)
            #expect(!blank.isDelayed)
            #expect(blank.expected == blank.scheduled)
            #expect(try !row("2032", in: board).isDelayed)
            #expect(try row("2032", in: board).delayMinutes == 0)
            #expect(try row("2033", in: board).delayMinutes == 5)
        }

        @Test("a live time a day off isn't a day late")
        func dayOff() async throws {
            let soon = Toronto.inMinutes(15)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2041", at: soon, expected: soon.addingTimeInterval(86400)),
            ])))
            let train = try row("2041", in: try await load())
            #expect(train.delayMinutes < 12 * 60, "\(train.delayMinutes) min late")
        }

        @Test("trains out of order in the feed: in time order")
        func order() async throws {
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2053", at: Toronto.inMinutes(40)),
                GO.line("2051", at: Toronto.inMinutes(10)),
                GO.line("2052", at: Toronto.inMinutes(25)),
            ])))
            let board = try await load()
            let live = board.rows.map(\.tripNumber).filter { $0.hasPrefix("205") }
            #expect(live == ["2051", "2052", "2053"])
            #expect(board.rows.map(\.scheduled) == board.rows.map(\.scheduled).sorted())
        }

        @Test("a train with no time, or one that isn't a time: left out, and the rest shown")
        func noTime() async throws {
            var junk = GO.line("2063", at: nil)
            junk["ScheduledDepartureTime"] = "soon"
            var blank = GO.line("2064", at: nil)
            blank["ScheduledDepartureTime"] = ""
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2061", at: nil), GO.line("2062", at: Toronto.inMinutes(10)), junk, blank,
            ])))
            let board = try await load()
            #expect(board.source == .live)
            #expect(board.rows.contains { $0.tripNumber == "2062" })
            #expect(!board.rows.contains { ["2061", "2063", "2064"].contains($0.tripNumber) })
        }

        // MARK: Platforms

        @Test("platforms however GO writes them; the one it's actually at over the planned one")
        func platforms() async throws {
            let soon = Toronto.inMinutes(20)
            let cases: [(trip: String, planned: Any, actual: Any, shown: String?)] = [
                ("2071", "7 & 8", "", "7, 8"),
                ("2072", "7&8", "", "7, 8"),
                ("2073", " 3 ", "", "3"),
                ("2074", "-", "", nil),
                ("2075", "", "", nil),
                ("2076", "--", " ", nil),
                ("2077", "2", "4", "4"),
                ("2078", "2", "-", "2"),
                ("2079", "2", " ", "2"),
                ("2080", NSNull(), NSNull(), nil),
            ]
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService(cases.enumerated().map { i, each in
                GO.line(each.trip, at: soon.addingTimeInterval(Double(i) * 60), platform: each.planned, actual: each.actual)
            })))
            let board = try await load()
            for each in cases {
                #expect(try row(each.trip, in: board).platform == each.shown, "\(each.trip): \(each.planned), \(each.actual)")
            }
        }

        // MARK: Cancellations

        @Test("cancelled by GO's exceptions feed, whatever its flags look like; only where it won't stop")
        func exceptions() async throws {
            let soon = Toronto.inMinutes(20)
            let trips = (2101...2110).map(String.init)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService(trips.enumerated().map { i, trip in
                GO.line(trip, at: soon.addingTimeInterval(Double(i) * 60))
            })))
            FakeNetwork.set("/live/cancelled", .page("busy", status: 503))
            FakeNetwork.set("/ServiceUpdate/Exceptions/Train", .json(GO.exceptions([
                ["TripNumber": "2101", "IsCancelled": "1", "Stop": [Any]()],
                ["TripNumber": "2102", "IsCancelled": true, "Stop": [Any]()],
                ["TripNumber": "2103", "IsCancelled": 1],
                ["TripNumber": "2104", "IsCancelled": "0", "Stop": [["Code": "OA", "IsCancelled": "0"]]],
                ["TripNumber": "2105", "IsCancelled": false, "Stop": [["Code": "OA", "IsCancelled": false]]],
                ["TripNumber": "2106", "IsCancelled": "false", "Stop": [["Code": "OA", "IsCancelled": "false"]]],
                // Not stopping at Oakville; then one not stopping at Clarkson (still stops here).
                ["TripNumber": "2107", "IsCancelled": "0", "Stop": [["Code": "OA", "IsCancelled": "1"]]],
                ["TripNumber": "2108", "IsCancelled": "0", "Stop": [["Code": "CL", "IsCancelled": "1"]]],
                ["TripNumber": "2109", "IsCancelled": NSNull(), "Stop": NSNull()],
                // One stop, not in a list.
                ["TripNumber": "2110", "IsCancelled": "0", "Stop": ["Code": "OA", "IsCancelled": "1"]],
            ])))
            _ = await CancelledTrains.shared.list(maxAge: 0)
            let board = try await load()
            let cancelled = Set(board.rows.filter(\.isCancelled).map(\.tripNumber))
            #expect(cancelled.intersection(trips) == ["2101", "2102", "2103", "2107", "2110"])
        }

        @Test("cancelled by the worker's list: on this train's day only, and only where it won't stop")
        func workerList() async throws {
            let soon = Toronto.inMinutes(20)
            let today = TorontoTime.dateWire(soon)
            let tomorrow = TorontoTime.dateWire(soon.addingTimeInterval(86400))
            let trips = (2121...2125).map(String.init)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService(trips.enumerated().map { i, trip in
                GO.line(trip, at: soon.addingTimeInterval(Double(i) * 60))
            })))
            FakeNetwork.set("/live/cancelled", .json(["from": ["exceptions", "updates"], "trips": [
                ["trip": "2121", "day": today, "all": true],
                ["trip": "2122", "day": tomorrow, "all": true],
                ["trip": "2123", "day": today, "skips": ["OA"]],
                ["trip": "2124", "day": today, "skips": ["CL", "PO"]],
                ["trip": "2125", "skips": ["OA"]],
            ]]))
            _ = await CancelledTrains.shared.list(maxAge: 0)
            let board = try await load()
            let cancelled = Set(board.rows.filter(\.isCancelled).map(\.tripNumber))
            #expect(cancelled.intersection(trips) == ["2121", "2123", "2125"])
        }

        @Test("one entry in the worker's list the app can't read: the rest still count")
        func workerListOdd() async throws {
            let soon = Toronto.inMinutes(20)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2131", at: soon), GO.line("2132", at: soon.addingTimeInterval(60)),
            ])))
            FakeNetwork.set("/live/cancelled", .json(["from": ["exceptions", "updates"], "trips": [
                ["trip": 2131, "all": true],
                ["trip": "2132", "all": "yes"],
                ["trip": "2132", "day": TorontoTime.dateWire(soon), "all": true],
            ]]))
            _ = await CancelledTrains.shared.list(maxAge: 0)
            let board = try await load()
            #expect(try row("2132", in: board).isCancelled)
        }

        // MARK: Shapes

        @Test("a trip number or platform as a number, not text")
        func numbers() async throws {
            let soon = Toronto.inMinutes(20)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line(2141, at: soon, platform: 3), GO.line("2142", at: soon.addingTimeInterval(60)),
            ])))
            let board = try await load()
            #expect(board.source == .live)
            #expect(try row("2141", in: board).platform == "3")
            #expect(board.rows.contains { $0.tripNumber == "2142" })
        }

        @Test("one train where there's usually a list")
        func oneAlone() async throws {
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService(GO.line("2151", at: Toronto.inMinutes(20)))))
            let board = try await load()
            #expect(board.source == .live)
            #expect(board.rows.first?.tripNumber == "2151")
        }

        @Test("nothing, or junk, among the trains: the trains shown")
        func holes() async throws {
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                NSNull(), 42, "train", GO.line("2161", at: Toronto.inMinutes(20)), [String: Any](),
            ])))
            let board = try await load()
            #expect(board.source == .live)
            #expect(board.rows.first?.tripNumber == "2161")
        }

        @Test("GO's error code as a number, and its metadata missing")
        func metadata() async throws {
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([GO.line("2171", at: Toronto.inMinutes(20))],
                                                                         metadata: ["ErrorCode": 200, "ErrorMessage": "OK"])))
            #expect(try await load().rows.first?.tripNumber == "2171")
            FakeNetwork.set("/Stop/NextService/OA", .json(["NextService": ["Lines": [GO.line("2172", at: Toronto.inMinutes(20))]]]))
            #expect(try await load().rows.first?.tripNumber == "2172")
        }

        @Test("a train listed twice: shown once")
        func twice() async throws {
            let soon = Toronto.inMinutes(20)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2181", at: soon), GO.line("2181", at: soon, expected: soon.addingTimeInterval(120)),
            ])))
            let board = try await load()
            #expect(board.rows.filter { $0.tripNumber == "2181" }.count == 1)
        }

        @Test("buses at the station aren't on the train board")
        func buses() async throws {
            let soon = Toronto.inMinutes(20)
            FakeNetwork.set("/Stop/NextService/OA", .json(GO.nextService([
                GO.line("2191", at: soon), GO.line("21912", at: soon, line: "21", type: "B"),
            ])))
            let board = try await load()
            #expect(board.rows.map(\.tripNumber).contains("2191"))
            #expect(!board.rows.map(\.tripNumber).contains("21912"))
        }

        // MARK: Union

        @Test("Union's board out of order, a train listed twice, one alone: in order, once each")
        func unionShapes() async throws {
            FakeNetwork.set("/Stop/NextService/UN", .json(GO.nextService([Any]())))
            FakeNetwork.set("/ServiceUpdate/UnionDepartures/All", .json(GO.union([
                GO.unionTrip("2203", at: Toronto.inMinutes(30)),
                GO.unionTrip("2201", at: Toronto.inMinutes(10)),
                GO.unionTrip("2202", at: Toronto.inMinutes(20), platform: "-"),
                GO.unionTrip("2201", at: Toronto.inMinutes(10)),
            ])))
            let board = try await load(union)
            #expect(board.source == .live)
            #expect(board.rows.map(\.tripNumber).filter { $0.hasPrefix("220") } == ["2201", "2202", "2203"])
            #expect(try row("2201", in: board).platform == "5, 6")
            #expect(try row("2202", in: board).platform == nil)

            FakeNetwork.set("/ServiceUpdate/UnionDepartures/All", .json(GO.union(
                GO.unionTrip("2211", at: Toronto.inMinutes(10), stops: ["Name": "Oakville GO", "Code": "OA"])
            )))
            #expect(try await load(union).rows.first?.tripNumber == "2211")
        }
    }
}
