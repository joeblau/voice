import XCTest

/// Settings → Voice (#35, a pane of Settings since #43). Runs with the DEBUG xAI stub, so voice settings
/// live in the `blau.uitests` defaults suite, never the developer's own.
@MainActor
final class VoiceSettingsUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchIntoSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "accept"
        // Fixture speech models, so the launch never starts a real download.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        openSettingsPane(SettingsPaneID.voice, in: app)
        return app
    }

    private func thinkingToggle(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["settings.voice.thinking"]
        if !toggle.waitForExistence(timeout: 5) || !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Voice section missing")
        return toggle
    }

    /// Taps the switch itself (tapping a Form row's label doesn't toggle it).
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func resetIfNeeded(in app: XCUIApplication) {
        let reset = app.buttons["settings.voice.reset"]
        if reset.waitForExistence(timeout: 2) {
            reset.tap()
            XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        }
    }

    func testVoiceSettingsAreShownAndPersist() {
        var app = launchIntoSettings()
        _ = thinkingToggle(in: app)
        resetIfNeeded(in: app)

        XCTAssertTrue(app.buttons["settings.voice.picker"].exists || app.otherElements["settings.voice.picker"].exists)
        XCTAssertTrue(app.sliders["settings.voice.speed"].exists)

        let toggle = thinkingToggle(in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        flip(toggle)
        XCTAssertEqual(thinkingToggle(in: app).value as? String, "0")
        XCTAssertTrue(app.buttons["settings.voice.reset"].waitForExistence(timeout: 5))

        // Saved: a relaunch shows the same setting.
        app.terminate()
        app = launchIntoSettings()
        XCTAssertEqual(thinkingToggle(in: app).value as? String, "0")

        // Reset puts the defaults back.
        app.buttons["settings.voice.reset"].tap()
        XCTAssertEqual(thinkingToggle(in: app).value as? String, "1")
        XCTAssertTrue(app.buttons["settings.voice.reset"].waitForNonExistence(timeout: 5))
    }
}
