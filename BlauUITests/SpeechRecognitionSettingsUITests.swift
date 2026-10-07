import XCTest

/// Settings → Transcription → Speech Recognition (#31): the toggle that forces Apple's
/// speech engine. Runs with the DEBUG xAI stub, so the choice lives in the
/// `blau.uitests` defaults suite, never the developer's own.
@MainActor
final class SpeechRecognitionSettingsUITests: XCTestCase {
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
        openSettingsPane(SettingsPaneID.transcription, in: app)
        return app
    }

    private func appleToggle(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["settings.speechRecognition.useApple"]
        var swipes = 0
        while (!toggle.exists || !toggle.isHittable) && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Speech Recognition section missing")
        return toggle
    }

    /// Taps the switch itself (tapping a Form row's label doesn't toggle it).
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func testTheAppleEngineToggleIsShownAndPersists() {
        var app = launchIntoSettings()
        var toggle = appleToggle(in: app)
        XCTAssertTrue(toggle.isEnabled)
        if toggle.value as? String == "1" {
            // Left on by an earlier run on this simulator.
            flip(toggle)
        }
        XCTAssertEqual(appleToggle(in: app).value as? String, "0")

        flip(appleToggle(in: app))
        XCTAssertEqual(appleToggle(in: app).value as? String, "1")

        // Saved: a relaunch shows the same choice.
        app.terminate()
        app = launchIntoSettings()
        toggle = appleToggle(in: app)
        XCTAssertEqual(toggle.value as? String, "1")

        // Back to automatic.
        flip(toggle)
        XCTAssertEqual(appleToggle(in: app).value as? String, "0")
    }
}
