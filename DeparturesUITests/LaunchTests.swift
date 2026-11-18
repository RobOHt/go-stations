import XCTest

/// The app as a rider meets it, driven like one: launched, and still standing.
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-homeStation", "OA", "-workStation", "UN"]
        app.launchEnvironment["GO_FIXTURES"] = Feeds.quiet().environment
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // A few seconds in (the board and the map loading): still running.
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "launched"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
