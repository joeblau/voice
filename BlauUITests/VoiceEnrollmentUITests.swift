import XCTest

/// Voice enrollment (#46) from Settings → Voice ID: the guided capture
/// stores a voiceprint, and Settings can delete it again.
///
/// Runs on fake services (`BLAU_APP_ENVIRONMENT=ui-test`): the enrollment
/// records synthetic speech at 8× real time and embeds it with the
/// scripted embedder, into an in-memory store. The real microphone and
/// model are covered on device (docs/voice-id.md).
@MainActor
final class VoiceEnrollmentUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchOnFakes() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func status(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["settings.voiceID.status"]
    }

    /// Opens Settings → Voice ID and runs a full enrollment.
    private func enroll(in app: XCUIApplication) {
        openSettingsPane(SettingsPaneID.voiceID, in: app)
        XCTAssertTrue(status(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(status(in: app).label.contains("Not enrolled"), status(in: app).label)

        app.buttons["settings.voiceID.enroll"].tap()
        let start = app.buttons["enrollment.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The enrollment didn't open")
        start.tap()

        // The first prompt, with its quality meter.
        XCTAssertTrue(app.descendants(matching: .any)["enrollment.prompt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["enrollment.meter"].exists)

        let finished = app.staticTexts["enrollment.finished"]
        XCTAssertTrue(finished.waitForExistence(timeout: 60), "The enrollment didn't finish")
        XCTAssertEqual(finished.label, "You're enrolled")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Enrollment finished"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["enrollment.close"].tap()
    }

    func testEnrollingStoresTheVoiceprint() {
        let app = launchOnFakes()
        enroll(in: app)

        let status = status(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let enrolled = NSPredicate(format: "label CONTAINS %@", "Enrolled")
        expectation(for: enrolled, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["settings.voiceID.enroll"].label.contains("Re-enroll"))
        // This device recorded the set, so there's nothing to top up, and it
        // is listed under Enrolled Microphones.
        XCTAssertFalse(app.buttons["settings.voiceID.topUp"].exists)
        let thisDevice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This iPhone")).firstMatch
        scrollTo(thisDevice, in: app.collectionViews.firstMatch)
        XCTAssertTrue(thisDevice.exists, "This device isn't listed")
    }

    func testDeletingTheVoiceprintFromVoiceIDSettings() {
        let app = launchOnFakes()
        enroll(in: app)

        let delete = app.buttons["settings.voiceID.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let confirm = app.buttons.matching(identifier: "settings.voiceID.delete.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting didn't ask first")
        confirm.tap()

        let notEnrolled = NSPredicate(format: "label CONTAINS %@", "Not enrolled")
        expectation(for: notEnrolled, evaluatedWith: status(in: app))
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["settings.voiceID.delete"].exists)
    }

    func testCancellingStoresNothing() {
        let app = launchOnFakes()
        openSettingsPane(SettingsPaneID.voiceID, in: app)
        app.buttons["settings.voiceID.enroll"].tap()
        let start = app.buttons["enrollment.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["enrollment.prompt"].waitForExistence(timeout: 10))
        app.buttons["enrollment.cancel"].tap()

        XCTAssertTrue(status(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(status(in: app).label.contains("Not enrolled"), status(in: app).label)
    }
}
