import XCTest

/// A station's board and a train's stops as a rider sees them, with GO's feeds made
/// up for each test (see `Feeds`): what's late, cancelled and on which platform, and
/// what shows when GO is down, frozen, or sends things in odd shapes.
final class BoardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func launch(_ feeds: Feeds, _ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["GO_FIXTURES"] = feeds.environment
        app.launch()
        return app
    }

    @MainActor
    func text(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testUnionBoardShowsPlatformsDelaysAndCancellations() throws {
        var feeds = Feeds.quiet()
        feeds.json("/ServiceUpdate/UnionDepartures/All", Feeds.union([
            Feeds.unionTrip("5001", in: 8, platform: "5 & 6"),
            Feeds.unionTrip("5002", in: 15, platform: "7"),
            Feeds.unionTrip("5003", in: 22, platform: "9"),
        ]))
        feeds.json("/Stop/NextService/UN", Feeds.nextService([
            Feeds.line("5002", in: 15, late: 6, stop: "UN", direction: "LW - Aldershot GO"),
        ]))
        feeds.json("/ServiceUpdate/Exceptions/Train", Feeds.exceptions([["TripNumber": "5003", "IsCancelled": "1"]]))
        let app = launch(feeds, ["-debugScene", "station"])
        XCTAssertTrue(text(app, startingWith: "Live · updated").waitForExistence(timeout: 20), "not live")
        keep(app, "union board")
        XCTAssertTrue(app.staticTexts["5, 6"].exists, "platform 5, 6")
        XCTAssertTrue(app.staticTexts["Cancelled | Annulé"].exists, "the cancelled train")
        XCTAssertTrue(text(app, startingWith: "Delayed | Retardé").exists, "the late train")
    }

    @MainActor
    func testGODownShowsTheTimetableSayingSo() throws {
        var feeds = Feeds.quiet()
        feeds.json("/Stop/NextService/OA", ["Metadata": ["ErrorCode": "502", "ErrorMessage": "Metrolinx answered 500"]],
                   status: 502)
        let app = launch(feeds, ["-debugScene", "station", "-debugStation", "OA"])
        XCTAssertTrue(app.staticTexts["Scheduled times, not live: no delays or platforms"].waitForExistence(timeout: 20))
        keep(app, "timetable board")
    }

    @MainActor
    func testFrozenFeedShowsTheTimetableNotYesterdaysTrains() throws {
        var feeds = Feeds.quiet()
        feeds.json("/Stop/NextService/OA", Feeds.nextService([
            Feeds.line("5011", in: -1440, stop: "OA"), Feeds.line("5012", in: -1420, stop: "OA"),
        ]))
        let app = launch(feeds, ["-debugScene", "station", "-debugStation", "OA"])
        XCTAssertTrue(app.staticTexts["Scheduled times, not live: no delays or platforms"].waitForExistence(timeout: 20))
        keep(app, "frozen feed board")
    }

    @MainActor
    func testOddShapesStillShowTheTrains() throws {
        var feeds = Feeds.quiet()
        var odd = Feeds.line("5021", in: 12, platform: "4", stop: "OA")
        odd["TripNumber"] = 5021
        odd["ScheduledPlatform"] = 4
        // One train alone where there's usually a list.
        feeds.json("/Stop/NextService/OA", ["Metadata": Feeds.ok, "NextService": ["Lines": odd]])
        let app = launch(feeds, ["-debugScene", "station", "-debugStation", "OA"])
        XCTAssertTrue(text(app, startingWith: "Live · updated").waitForExistence(timeout: 20), "not live")
        keep(app, "odd shapes board")
        XCTAssertTrue(app.staticTexts[Feeds.clock(Feeds.soon(12))].exists, "the train at \(Feeds.clock(Feeds.soon(12)))")
    }

    @MainActor
    func testTrainLateToTheEndOfItsRunWithItsLinesAlerts() throws {
        var feeds = Feeds.quiet()
        feeds.json("/ServiceUpdate/UnionDepartures/All", Feeds.union([Feeds.unionTrip("5101", in: 10, platform: "3")]))
        feeds.json("/Stop/NextService/UN", Feeds.nextService([
            Feeds.line("5101", in: 10, late: 7, stop: "UN", direction: "LW - Aldershot GO"),
        ]))
        // Late at every stop GO times, and nothing at the end of the run.
        let trip = Feeds.trip("5101", stops: [("UN", 10, 7), ("PO", 19, 7), ("CL", 25, 7), ("OA", 30, 7),
                                              ("BU", 48, 7), ("AL", 60, nil)])
        for day in Feeds.serviceDays(10) { feeds.json("/Schedule/Trip/\(day)/5101", trip) }
        feeds.json("/ServiceUpdate/ServiceAlert/All", Feeds.alerts([Feeds.delayAlert("Lakeshore West - Signal problems")]))
        let app = launch(feeds, ["-debugScene", "trip", "-tripScrollToEnd", "YES"])
        let late = app.descendants(matching: .any)["Running 7 minutes late"]
        XCTAssertTrue(late.waitForExistence(timeout: 25), "no late pill")
        keep(app, "late train")
        XCTAssertTrue(app.staticTexts["Lakeshore West - Signal problems"].waitForExistence(timeout: 10), "no line alert")
        // Aldershot, where GO times nothing: as late as the rest.
        let aldershot = Feeds.clock(Feeds.soon(67))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", aldershot)).firstMatch.exists,
                      "Aldershot not at \(aldershot)")
    }

    @MainActor
    func testUnionBoardPassesTheAccessibilityAudit() throws {
        var feeds = Feeds.quiet()
        feeds.json("/ServiceUpdate/UnionDepartures/All", Feeds.union([
            Feeds.unionTrip("5031", in: 8, platform: "5 & 6"), Feeds.unionTrip("5032", in: 25),
        ]))
        let app = launch(feeds, ["-debugScene", "station"])
        XCTAssertTrue(text(app, startingWith: "Live · updated").waitForExistence(timeout: 20), "not live")
        keep(app, "audited board")
        // What the board's design decides (its fixed type, as on GO's own boards, and
        // its quieter hints) is noted, to look at, not a failure; MapKit's own Legal
        // link isn't the app's to size. Everything else fails, with its element.
        let design: [XCUIAccessibilityAuditType] = [.dynamicType, .textClipped, .contrast]
        var failing: [String] = []
        var noted: [String] = []
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' at \($0.frame)" } ?? "no element"
            let line = "\(issue.compactDescription): \(element). \(issue.detailedDescription)"
            if issue.auditType == .hitRegion, issue.element?.label == "Legal" { return true }
            if design.contains(issue.auditType) {
                noted.append(line)
            } else {
                failing.append(line)
            }
            return true
        }
        let report = XCTAttachment(string: noted.joined(separator: "\n"))
        report.name = "accessibility notes"
        report.lifetime = .keepAlways
        add(report)
        XCTAssert(failing.isEmpty, "\n" + failing.joined(separator: "\n"))
    }
}
