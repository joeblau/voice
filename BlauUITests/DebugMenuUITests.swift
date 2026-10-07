import XCTest

/// The DEBUG menu: opening it from the main screen and toggling feature
/// flags. Launches the app on fake services (`BLAU_APP_ENVIRONMENT=ui-test`),
/// whose flags live in memory, so every launch starts at the defaults.
@MainActor
final class DebugMenuUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func openDebugMenu(_ app: XCUIApplication) {
        let button = app.buttons["blau.debugMenu.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The DEBUG build has no debug menu button")
        button.tap()
    }

    private func flagSwitch(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let toggle = app.switches["blau.flag.\(name)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No toggle for \(name)")
        return toggle
    }

    /// Taps the switch itself rather than the middle of the row, which holds
    /// the label.
    private func flip(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func value(_ toggle: XCUIElement) -> String? {
        toggle.value as? String
    }

    func testEveryFlagIsListedAtItsDefault() {
        let app = launch()
        openDebugMenu(app)
        let defaults = [
            "voiceIDEnabled": "1", "secondPassASR": "1", "topicLLMConfirm": "1", "memoryTools": "1", "perfHUD": "0",
        ]
        for (name, expected) in defaults {
            let toggle = flagSwitch(app, name)
            if !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(value(toggle), expected, "\(name) should start at its default")
        }
    }

    func testTogglingAFlagOverridesItUntilReset() {
        let app = launch()
        openDebugMenu(app)

        let perfHUD = flagSwitch(app, "perfHUD")
        XCTAssertEqual(value(perfHUD), "0")
        flip(perfHUD)
        XCTAssertEqual(value(perfHUD), "1")

        let memoryTools = flagSwitch(app, "memoryTools")
        flip(memoryTools)
        XCTAssertEqual(value(memoryTools), "0")

        // Overrides outlive the sheet.
        app.buttons["blau.debugMenu.done"].tap()
        openDebugMenu(app)
        XCTAssertEqual(value(flagSwitch(app, "perfHUD")), "1")
        XCTAssertEqual(value(flagSwitch(app, "memoryTools")), "0")

        let reset = app.buttons["blau.debugMenu.resetFlags"]
        if !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertEqual(value(flagSwitch(app, "perfHUD")), "0")
        XCTAssertEqual(value(flagSwitch(app, "memoryTools")), "1")
    }

    func testLaunchArgumentOverridesAFlag() {
        let app = launch(arguments: ["-blau.featureFlag.perfHUD", "YES"])
        openDebugMenu(app)
        XCTAssertEqual(value(flagSwitch(app, "perfHUD")), "1")
    }
}
