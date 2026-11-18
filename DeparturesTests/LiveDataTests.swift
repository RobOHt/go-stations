import Foundation
import Testing
@testable import Departures

/// Where the trains are (the worker's /live/trains), what's cancelled (its
/// /live/cancelled, or GO's exceptions feed without it), and GO's service alerts.
extension GOFeeds {
    @Suite("Where the trains are")
    @MainActor
    struct Positions {
        init() {
            FakeNetwork.start()
        }

        func load(_ trains: [[String: Any]]) async {
            FakeNetwork.set("/live/trains", .json(GO.trains(trains)))
            await LiveTrains.shared.refresh(maxAge: 0)
        }

        @Test("a report from just now says where the train is; one minutes old, or from the future, doesn't")
        func freshness() async {
            await load([GO.train("4001", seconds: 10), GO.train("4002", seconds: 300), GO.train("4003", seconds: -600)])
            #expect(LiveTrains.shared.train("4001") != nil)
            #expect(LiveTrains.shared.train("4002") == nil)
            #expect(LiveTrains.shared.train("4003") == nil)
        }

        @Test("one train the app can't read doesn't lose it the others")
        func oneOdd() async {
            var odd = GO.train("4011")
            odd["lat"] = NSNull()
            var noTrip = GO.train("4012")
            noTrip["trip"] = 4012
            await load([odd, noTrip, GO.train("4013")])
            #expect(LiveTrains.shared.train("4013") != nil)
        }

        @Test("a position no train could be at isn't one to draw")
        func impossible() async {
            await load([GO.train("4021", lat: 400), GO.train("4022", lat: 43.45, lon: 0), GO.train("4023")])
            #expect(LiveTrains.shared.train("4023") != nil)
            for trip in ["4021", "4022"] {
                if let train = LiveTrains.shared.latest(trip) {
                    #expect(abs(train.lat) <= 90 && abs(train.lon) <= 180 && train.lat != 0 && train.lon != 0,
                            "\(trip) at \(train.lat), \(train.lon)")
                }
            }
        }

        @Test("the worker failing, or sending junk: the trains it last had, while they're fresh")
        func failing() async {
            await load([GO.train("4031", seconds: 5)])
            for reply: FakeNetwork.Reply in [.failure(.timedOut), .page("busy", status: 503), .page("<html>", status: 200)] {
                FakeNetwork.set("/live/trains", reply)
                await LiveTrains.shared.refresh(maxAge: 0)
                #expect(LiveTrains.shared.train("4031") != nil, "lost it on \(reply)")
            }
        }
    }

    @Suite("What's cancelled")
    struct Cancelled {
        init() {
            FakeNetwork.start()
        }

        @Test("without the worker, GO's exceptions feed: its trips one alone, its flags however written")
        func exceptionsAlone() async throws {
            FakeNetwork.set("/live/cancelled", .page("busy", status: 502))
            FakeNetwork.set("/ServiceUpdate/Exceptions/Train", .json(GO.exceptions(
                ["TripNumber": 4101, "IsCancelled": "True", "Stop": ["Code": "OA", "IsCancelled": "1"]]
            )))
            let list = try #require(await CancelledTrains.shared.list(maxAge: 0))
            #expect(list.status(of: "4101", serviceDays: [])?.all == true)
        }

        @Test("another day's cancellation isn't this train's")
        func otherDay() {
            let list = CancelledTrains.List(entries: [
                .init(trip: "4111", day: "20261113", all: true),
                .init(trip: "4112", day: "20261113", skips: ["OA"]),
            ], fetchedAt: Date())
            #expect(list.status(of: "4111", serviceDays: ["20261114"]) == nil)
            #expect(list.status(of: "4111", serviceDays: ["20261113"])?.all == true)
            #expect(list.status(of: "4112", serviceDays: ["20261113"])?.isCancelled(at: "OA") == true)
            #expect(list.status(of: "4112", serviceDays: ["20261113"])?.isCancelled(at: "CL") == false)
        }
    }

    @Suite("GO's service alerts")
    struct Alerts {
        let network = RailNetwork.shared

        func row(_ trip: String) -> BoardRow {
            let now = Date()
            return BoardRow(tripNumber: trip, lineCode: "LW", lineName: "Lakeshore West", destination: "Union Station",
                            stops: [], scheduled: now, expected: now, platform: nil, isExpress: false, isCancelled: false,
                            reasonEnglish: nil, reasonFrench: nil)
        }

        func decode(_ json: [String: Any]) throws -> AlertsResponse {
            try MetrolinxClient.decoder.decode(AlertsResponse.self, from: Data(FakeNetwork.json(json).utf8))
        }

        func message(_ code: String, lines: Any = [["Code": "LW"]], trips: Any = [Any](), sub: String = "Train Delay",
                     body: String = "Delays of up to 15 minutes.") -> [String: Any] {
            ["Code": code, "SubjectEnglish": "Lakeshore West delays", "SubjectFrench": "Retards", "BodyEnglish": body,
             "BodyFrench": "Retards", "Category": "Service Disruption", "SubCategory": sub, "Lines": lines,
             "Stops": [Any](), "Trips": trips]
        }

        @Test("an alert with no lines or trips listed, or null for them: no crash, and not on every train")
        func nothingListed() throws {
            let alerts = try decode(GO.alerts([
                message("A1", lines: NSNull(), trips: NSNull()), message("A2", lines: [Any](), trips: [Any]()),
                message("A3"),
            ]))
            let shown = BoardService.lineAlerts(alerts, row: row("4201"), network: network)
            #expect(shown.map(\.id) == ["A3"])
        }

        @Test("the same alert twice: shown once; one for planned work: not with the train")
        func duplicates() throws {
            let alerts = try decode(GO.alerts([message("B1"), message("B1"), message("B2", sub: "Information")]))
            #expect(BoardService.lineAlerts(alerts, row: row("4202"), network: network).map(\.id) == ["B1"])
        }

        @Test("an alert naming the train, or with its line one alone")
        func shapes() throws {
            let alerts = try decode(GO.alerts([
                message("C1", lines: [Any](), trips: [["TripNumber": "4203"]]),
                message("C2", lines: ["Code": "LW"]),
            ]))
            #expect(Set(BoardService.lineAlerts(alerts, row: row("4203"), network: network).map(\.id)) == ["C1", "C2"])
        }
    }
}
