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

        @Test("a train's reports place it only while they still say where it is: not minutes old, not once out of touch")
        func reportsToDrawBy() async {
            await load([GO.train("4041", seconds: 10), GO.train("4042", seconds: 300)])
            #expect(LiveTrains.shared.reports(of: "4041")?.last?.trip == "4041")
            #expect(LiveTrains.shared.reports(of: "4042") == nil)
            #expect(LiveTrains.shared.reports(of: "4049") == nil)
            // (No new list for most of a minute: what it has is old news.)
            #expect(LiveTrains.shared.reports(of: "4041", at: Date().addingTimeInterval(45)) == nil)
        }

        @Test("GO's other GPS fix of a train goes with it, in its place by time: two positions to go by at once")
        func otherFixes() async {
            let now = Date().timeIntervalSince1970
            // Service at a Glance's fix 15 s older than the vehicle positions'.
            var older = GO.train("4061", seconds: 10)
            older["fixes"] = [["lat": 43.45, "lon": -79.69, "time": now - 25]]
            // ...and one 15 s newer.
            var newer = GO.train("4062", seconds: 25)
            newer["fixes"] = [["lat": 43.46, "lon": -79.67, "time": now - 10]]
            // ...and junk where it should be: the train is still read.
            var junk = GO.train("4063", seconds: 10)
            junk["fixes"] = "not a list"
            await load([older, newer, junk])
            let first = LiveTrains.shared.reports(of: "4061") ?? []
            #expect(first.map(\.lat) == [43.45, 43.4561], "\(first.map(\.lat))")
            // (An older fix leaves which stop it's at or heading for to its position.)
            #expect(first.first?.status == nil && first.first?.stop == nil)
            let second = LiveTrains.shared.reports(of: "4062") ?? []
            #expect(second.map(\.lat) == [43.4561, 43.46], "\(second.map(\.lat))")
            // (A newer one goes with what the vehicle positions last said of that.)
            #expect(second.last?.status == "at" && second.last?.stop == "OA")
            // The train's latest report is still the vehicle positions' own.
            #expect(LiveTrains.shared.train("4062")?.lat == 43.4561)
            #expect(LiveTrains.shared.train("4063") != nil && LiveTrains.shared.reports(of: "4063")?.count == 1)

            // A fix that comes in after a newer report goes in before it; the same fix twice, once.
            var again = GO.train("4061", seconds: 10)
            again["time"] = older["time"]
            again["fixes"] = [["lat": 43.44, "lon": -79.70, "time": now - 40], ["lat": 43.45, "lon": -79.69, "time": now - 25]]
            await load([again])
            #expect((LiveTrains.shared.reports(of: "4061") ?? []).map(\.lat) == [43.44, 43.45, 43.4561],
                    "\((LiveTrains.shared.reports(of: "4061") ?? []).map(\.lat))")
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
            ["Code": code, "SubjectEnglish": code, "SubjectFrench": "Retards", "BodyEnglish": body,
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
            #expect(shown.map(\.subjectEnglish) == ["A3"])
        }

        @Test("the same alert twice: shown once; one for planned work: not with the train")
        func duplicates() throws {
            let alerts = try decode(GO.alerts([message("B1"), message("B1"), message("B2", sub: "Information")]))
            #expect(BoardService.lineAlerts(alerts, row: row("4202"), network: network).map(\.subjectEnglish) == ["B1"])
        }

        @Test("an alert naming the train (its number as text or a number), or with its line one alone")
        func shapes() throws {
            let alerts = try decode(GO.alerts([
                message("C1", lines: [Any](), trips: [["TripNumber": "4203"]]),
                message("C2", lines: ["Code": "LW"]),
                message("C3", lines: [Any](), trips: [["TripNumber": 4203]]),
            ]))
            #expect(Set(BoardService.lineAlerts(alerts, row: row("4203"), network: network).map(\.subjectEnglish)) == ["C1", "C2", "C3"])
        }
    }
}
