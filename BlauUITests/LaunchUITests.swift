import XCTest

/// Smoke test: the app launches to the foreground and shows its root view.
@MainActor
final class LaunchUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLaunchShowsRootView() throws {
        let app = XCUIApplication()
        // Fixture speech models: no real model download from a UI test.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 10),
            "Root view did not appear after launch"
        )
    }
}
