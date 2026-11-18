import Foundation
import Testing
@testable import Departures

/// A train's stops (the trip view), from GO's /Schedule/Trip: times blank at the
/// end of the run, stops out of order, past midnight, GO failing. A made-up
/// Lakeshore West train from Oakville to Union, at midday today (Toronto).
extension GOFeeds {
    @Suite("A train's stops")
    struct Stops {
        let oakville = RailNetwork.shared.station("OA")!

        init() async {
            FakeNetwork.start()
            await ScheduleStore.shared.refreshIfNeeded()
        }

        /// Its row on Oakville's board.
        func row(_ trip: String, at time: Date = Toronto.today(12, 30)) -> BoardRow {
            BoardRow(tripNumber: trip, lineCode: "LW", lineName: "Lakeshore West", destination: "Union Station",
                     stops: ["Clarkson", "Port Credit", "Union Station"], scheduled: time, expected: time, platform: "2",
                     isExpress: false, isCancelled: false, reasonEnglish: nil, reasonFrench: nil,
                     serviceDay: TorontoTime.dateWire(time), stopCodes: ["CL", "PO", "UN"])
        }

        func path(_ row: BoardRow) -> String { "/Schedule/Trip/\(row.serviceDay!)/\(row.tripNumber)" }

        func detail(_ row: BoardRow) async -> TripDetail {
            await BoardService.shared.tripDetail(for: row, from: oakville)
        }

        func stop(_ code: String, in detail: TripDetail, sourceLocation: SourceLocation = #_sourceLocation) throws -> TripDetail.Stop {
            try #require(detail.stops.first { $0.code == code }, "no \(code) in \(detail.stops.map(\.code))",
                         sourceLocation: sourceLocation)
        }

        @Test("late at the stops GO times, and as late at the end of the run, where it times nothing")
        func lateToTheEnd() async throws {
            let train = row("3001")
            FakeNetwork.set(path(train), .json(GO.trip("3001", stops: [
                GO.stop("AL", "12:00", computed: "12:05"), GO.stop("BU", "12:12", computed: "12:17"),
                GO.stop("OA", "12:30", computed: "12:35"), GO.stop("CL", "12:35", computed: "12:40"),
                GO.stop("PO", "12:41", computed: "12:46"), GO.stop("UN", "12:50", computed: ""),
            ])))
            let detail = await detail(train)
            #expect(detail.source == .live)
            let end = try stop("UN", in: detail)
            let time = try #require(end.time)
            #expect(end.expected == time.addingTimeInterval(300), "Union: \(String(describing: end.expected)) for \(time)")
        }

        @Test("stops out of order in the feed: in the order the train calls at them")
        func order() async throws {
            let train = row("3002")
            FakeNetwork.set(path(train), .json(GO.trip("3002", stops: [
                GO.stop("CL", "12:35"), GO.stop("AL", "12:00"), GO.stop("UN", "12:50"),
                GO.stop("OA", "12:30"), GO.stop("PO", "12:41"), GO.stop("BU", "12:12"),
            ])))
            let detail = await detail(train)
            #expect(detail.stops.map(\.code) == Timetable.east)
            let times = detail.stops.compactMap(\.time)
            #expect(times == times.sorted())
        }

        @Test("past midnight, written either way GO might: the stops after it are the next day", arguments: [
            ["23:20", "23:32", "23:50", "23:55", "00:01", "00:10"],
            ["23:20", "23:32", "23:50", "23:55", "24:01", "24:10"],
        ])
        func midnight(_ clocks: [String]) async throws {
            let number = clocks[4].hasPrefix("24") ? "3004" : "3003"
            let train = row(number, at: Toronto.today(23, 50))
            FakeNetwork.set(path(train), .json(GO.trip(number, stops: zip(Timetable.east, clocks).map { GO.stop($0, $1) })))
            let detail = await detail(train)
            let times = detail.stops.compactMap(\.time)
            #expect(times.count == 6)
            #expect(times == times.sorted(), "\(times.map(Toronto.wall))")
            let union = try #require(try stop("UN", in: detail).time)
            #expect(union.timeIntervalSince(train.scheduled) == 20 * 60, "Union at \(Toronto.wall(union))")
        }

        @Test("a stop with no times at all: no time there, and the others as they are")
        func noTimes() async throws {
            let train = row("3005")
            FakeNetwork.set(path(train), .json(GO.trip("3005", stops: [
                GO.stop("AL", "12:00"), GO.stop("BU", nil), GO.stop("OA", "12:30"),
                GO.stop("CL", "soon"), GO.stop("PO", "12:41"), GO.stop("UN", "12:50"),
            ])))
            let detail = await detail(train)
            #expect(detail.stops.map(\.code) == Timetable.east)
            #expect(try stop("BU", in: detail).time == nil)
            #expect(try stop("CL", in: detail).time == nil)
            #expect(try stop("OA", in: detail).time == Toronto.today(12, 30))
        }

        @Test("the platform: the one it's actually at over the planned one; none for a dash")
        func platforms() async throws {
            let train = row("3006")
            FakeNetwork.set(path(train), .json(GO.trip("3006", stops: [
                GO.stop("AL", "12:00", track: ["Scheduled": "1", "Actual": "3"]),
                GO.stop("BU", "12:12", track: ["Scheduled": "-", "Actual": ""]),
                GO.stop("OA", "12:30", track: ["Scheduled": "2", "Actual": "-"]),
                GO.stop("CL", "12:35", track: NSNull()),
                GO.stop("PO", "12:41", track: ["Scheduled": 2, "Actual": NSNull()]),
                GO.stop("UN", "12:50", track: ["Scheduled": "9 & 10", "Actual": ""]),
            ])))
            let detail = await detail(train)
            #expect(try stop("AL", in: detail).platform == "3")
            #expect(try stop("BU", in: detail).platform == nil)
            #expect(try stop("OA", in: detail).platform == "2")
            #expect(try stop("CL", in: detail).platform == nil)
            #expect(try stop("PO", in: detail).platform == "2")
            #expect(try stop("UN", in: detail).platform == "9, 10")
        }

        static let failures: [FakeNetwork.Reply] = [
            .failure(.timedOut),
            .json(GO.error("502", "Metrolinx answered 500"), status: 502),
            .page("<html>Down for maintenance</html>"),
            .json(["Metadata": GO.ok(), "Trips": [Any]()]),
            .json(["Metadata": GO.ok(), "Trips": [["Number": "8016", "Stops": [Any]()]]]),
        ]

        @Test("GO failing or sending nothing: the timetable's stops", arguments: Stops.failures)
        func failing(_ reply: FakeNetwork.Reply) async throws {
            // Trip 8016 in the made-up timetable: Aldershot 05:20, Oakville 05:50.
            let train = row("8016", at: Toronto.today(5, 50))
            FakeNetwork.set(path(train), reply)
            let detail = await detail(train)
            #expect(detail.source == .schedule)
            #expect(detail.stops.map(\.code) == Timetable.east)
            #expect(try stop("OA", in: detail).time == Toronto.today(5, 50))
        }

        @Test("GO failing for a train the timetable doesn't have: its stops by name")
        func failingUnknown() async throws {
            let train = row("3007")
            FakeNetwork.set(path(train), .failure(.timedOut))
            let detail = await detail(train)
            #expect(detail.source == nil)
            #expect(detail.stops.map(\.code) == ["OA", "CL", "PO", "UN"])
        }

        @Test("the trip, or its stops, one alone where there's usually a list")
        func oneAlone() async throws {
            let train = row("3008")
            FakeNetwork.set(path(train), .json(["Metadata": GO.ok(), "Trips": [
                "Number": "3008", "Stops": [GO.stop("OA", "12:30"), GO.stop("UN", "12:50")],
            ]]))
            #expect(await detail(train).stops.map(\.code) == ["OA", "UN"])
        }
    }
}
