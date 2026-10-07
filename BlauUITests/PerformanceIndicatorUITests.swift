import XCTest

/// The degraded-mode indicator on the main screen (#75). Launches on fake
/// services (`BLAU_APP_ENVIRONMENT=ui-test`), whose device conditions are
/// fixed at nominal; `-BlauPerformanceLevel` holds the level.
@MainActor
final class PerformanceIndicatorUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(level: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        if let level {
            app.launchArguments += ["-BlauPerformanceLevel", level]
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func indicator(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["blau.performance.indicator"]
    }

    func testHiddenAtNormal() {
        let app = launch()
        XCTAssertFalse(indicator(app).waitForExistence(timeout: 2))
    }

    func testShownWhileReducedWithAnAccessibleExplanation() {
        let app = launch(level: "reduced")
        let indicator = indicator(app)
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertTrue(indicator.label.contains("saving work"), indicator.label)
    }

    func testTheDebugMenuOverrideShowsAndHidesIt() {
        let app = launch()
        app.buttons["blau.debugMenu.open"].tap()
        let picker = app.descendants(matching: .any)["blau.debugMenu.performanceLevel"]
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let minimal = app.buttons["Minimal"]
        XCTAssertTrue(minimal.waitForExistence(timeout: 5))
        minimal.tap()
        app.buttons["blau.debugMenu.done"].tap()
        XCTAssertTrue(indicator(app).waitForExistence(timeout: 10))
    }
}
