import XCTest

/// A fresh install shows speech-model download progress, then the models
/// become ready and Settings lists them with their size on disk.
///
/// Runs on fixture models (`BLAU_MODEL_FIXTURES=1`): tiny synthetic files
/// served from memory at a visible pace, through the real download, verify,
/// install and warm-up code. No network, no Core ML.
@MainActor
final class SpeechModelSetupUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Main screen gear → Settings → Speech Models.
    private func openSpeechModelSettings(in app: XCUIApplication) {
        let gear = app.buttons["blau.settings.open"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Settings gear missing")
        gear.tap()
        let link = app.buttons["blau.models.settingsLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Settings has no Speech Models link")
        link.tap()
    }

    func testFreshInstallShowsProgressThenReady() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()

        let setup = app.descendants(matching: .any)["blau.models.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15), "The setup card should appear on a fresh install")
        let progress = app.descendants(matching: .any)["blau.models.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 15), "Download progress should be visible")

        // The card sits below the Settings gear, never on top of it.
        let gear = app.buttons["blau.settings.open"]
        XCTAssertTrue(gear.exists)
        XCTAssertTrue(gear.isHittable)
        XCTAssertFalse(
            gear.frame.intersects(setup.frame), "The setup card covers the Settings gear: \(gear.frame) \(setup.frame)")

        XCTAssertTrue(setup.waitForNonExistence(timeout: 120), "The setup card should go away once models are ready")

        openSpeechModelSettings(in: app)
        for id in ["sileroVAD", "speakerEmbedding", "parakeetRealtimeEOU"] {
            let status = app.staticTexts["blau.models.row.\(id).status"]
            XCTAssertTrue(status.waitForExistence(timeout: 10), "\(id) row is missing")
            XCTAssertTrue(status.label.hasPrefix("Ready"), "\(id): \(status.label)")
        }
        XCTAssertTrue(app.staticTexts["blau.models.settings.total"].exists)
    }

    func testDeletingAModelFromSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()
        let setup = app.descendants(matching: .any)["blau.models.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15))
        XCTAssertTrue(setup.waitForNonExistence(timeout: 120), "Models should become ready")

        openSpeechModelSettings(in: app)
        let delete = app.buttons["blau.models.row.sileroVAD.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        // The dialog's button, not one of the rows' Delete buttons.
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'Delete' AND NOT (identifier BEGINSWITH 'blau.models.row')")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let status = app.staticTexts["blau.models.row.sileroVAD.status"]
        let notDownloaded = NSPredicate(format: "label BEGINSWITH 'Not downloaded'")
        expectation(for: notDownloaded, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["blau.models.row.sileroVAD.download"].exists)
    }
}
