import XCTest

/// The settings sheet (#43): it opens from the bottom-left button at the
/// medium detent, every pane opens, and changes take effect live.
///
/// Most tests run on fake services (`BLAU_APP_ENVIRONMENT=ui-test`): an
/// in-memory store and in-memory flags, so deleting data or flipping a flag
/// never touches the simulator's real data. Tests that check persistence
/// across launches use the xAI DEBUG stub instead, whose settings live in
/// the `blau.uitests` defaults suite.
@MainActor
final class SettingsUITests: XCTestCase {
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

    private func launchWithStub() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "accept"
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps a Form switch itself (tapping the row's label doesn't toggle it).
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Taps the back button of the pane titled `title`. (The main screen's
    /// navigation bar is still in the hierarchy behind the sheet.)
    private func goBack(from title: String, in app: XCUIApplication) {
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
    }

    // MARK: Opening

    func testOpensFromTheBottomLeftButtonAtTheMediumDetent() {
        let app = launchOnFakes()
        let window = app.windows.firstMatch.frame
        let button = app.buttons["blau.settings.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertLessThan(button.frame.midX, window.midX, "The Settings button isn't on the left")
        XCTAssertGreaterThan(button.frame.midY, window.midY, "The Settings button isn't at the bottom")

        openSettings(in: app)
        let title = app.navigationBars["Settings"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Medium detent: the sheet starts around the middle of the screen,
        // leaving the main screen visible above it.
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in title.frame.minY > window.height * 0.3 }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 5), .completed,
            "Settings didn't open at the medium detent: title bar \(title.frame), window \(window)")
        screenshot(app, "Settings, medium detent")

        app.buttons["settings.done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Done didn't close Settings")
    }

    func testEveryPaneOpens() {
        let app = launchOnFakes()
        let list = openSettings(in: app)
        let titles = [
            "xAI Account", "Voice", "Voice ID", "Transcription", "Knowledge", "iCloud", "Speech Models",
            "Privacy & Data", "Developer",
        ]
        for (identifier, title) in zip(SettingsPaneID.all, titles) {
            let row = app.buttons[identifier]
            scrollTo(row, in: list)
            row.tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 10), "\(title) didn't open from \(identifier)")
            screenshot(app, "Settings → \(title)")
            goBack(from: title, in: app)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Back from \(title) failed")
        }
    }

    // MARK: Live changes

    func testThePerformanceHUDAppearsAsSoonAsItIsSwitchedOn() {
        let app = launchOnFakes()
        let hud = app.descendants(matching: .any)["blau.hud"]
        XCTAssertFalse(hud.exists)

        openSettingsPane(SettingsPaneID.developer, in: app)
        let toggle = app.switches["settings.developer.performanceHUD"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "1")

        app.buttons["settings.done"].tap()
        XCTAssertTrue(hud.waitForExistence(timeout: 5), "The HUD didn't appear")

        // Root summary says so, and switching it off hides it again.
        openSettings(in: app)
        let developer = app.buttons[SettingsPaneID.developer]
        scrollTo(developer, in: app.collectionViews["settings.list"])
        XCTAssertTrue(developer.label.contains("HUD on"), developer.label)
        developer.tap()
        flip(app.switches["settings.developer.performanceHUD"])
        app.buttons["settings.done"].tap()
        XCTAssertTrue(hud.waitForNonExistence(timeout: 5), "The HUD didn't go away")
    }

    func testVoiceIDSensitivityIsSavedAndResets() {
        var app = launchWithStub()
        openSettingsPane(SettingsPaneID.voiceID, in: app)
        XCTAssertTrue(app.navigationBars["Voice ID"].waitForExistence(timeout: 10))
        let status = app.descendants(matching: .any)["settings.voiceID.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Not enrolled"), status.label)
        XCTAssertTrue(app.buttons["settings.voiceID.enroll"].isEnabled, "Enrolling is available")

        let reset = app.buttons["settings.voiceID.sensitivity.reset"]
        if reset.waitForExistence(timeout: 2) {
            reset.tap()  // Left over from an earlier run on this simulator.
        }
        let slider = app.sliders["settings.voiceID.sensitivity"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "Balanced")
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(slider.value as? String, "Strict")

        // Saved: a relaunch shows the same sensitivity.
        app.terminate()
        app = launchWithStub()
        openSettingsPane(SettingsPaneID.voiceID, in: app)
        XCTAssertEqual(app.sliders["settings.voiceID.sensitivity"].value as? String, "Strict")
        app.buttons["settings.voiceID.sensitivity.reset"].tap()
        XCTAssertEqual(app.sliders["settings.voiceID.sensitivity"].value as? String, "Balanced")
    }

    func testTheSecondPassToggleIsSaved() {
        var app = launchWithStub()
        openSettingsPane(SettingsPaneID.transcription, in: app)
        let toggle = app.switches["settings.transcription.secondPass"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String == "0" {
            flip(toggle)  // Left off by an earlier run on this simulator.
        }
        XCTAssertEqual(toggle.value as? String, "1")
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "0")

        app.terminate()
        app = launchWithStub()
        openSettingsPane(SettingsPaneID.transcription, in: app)
        let reloaded = app.switches["settings.transcription.secondPass"]
        XCTAssertTrue(reloaded.waitForExistence(timeout: 10))
        XCTAssertEqual(reloaded.value as? String, "0")
        flip(reloaded)
        XCTAssertEqual(reloaded.value as? String, "1")
    }

    // MARK: Account

    func testTestConnectionChecksTheStoredKey() {
        let app = launchWithStub()
        openSettingsPane(SettingsPaneID.account, in: app)
        let field = app.secureTextFields["xai.apiKey.field"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("xai-" + String(repeating: "UITest0Key", count: 5) + "e5f6")
            app.buttons["xai.apiKey.connect"].tap()
        }
        let test = app.buttons["settings.account.testConnection"]
        XCTAssertTrue(test.waitForExistence(timeout: 10), "No Test Connection button once connected")
        test.tap()
        let result = app.descendants(matching: .any)["settings.account.connectionResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "No connection test result")
        XCTAssertTrue(result.label.contains("Connected to xAI"), result.label)

        // The usage estimate for this month (no conversations yet).
        let usage = app.descendants(matching: .any)["settings.account.cost"]
        scrollTo(usage, in: app.collectionViews.firstMatch)
        XCTAssertTrue(usage.label.contains("$0.00"), usage.label)
        screenshot(app, "Settings → xAI Account")
    }

    // MARK: Knowledge

    func testKnowledgeShowsLearningAndTheMemorySearchIndex() {
        let app = launchOnFakes()
        openSettingsPane(SettingsPaneID.knowledge, in: app)
        let learn = app.switches["settings.memory.learn"]
        scrollTo(learn, in: app.collectionViews.firstMatch)
        XCTAssertTrue(learn.waitForExistence(timeout: 10), "No Learn From Conversations in Settings → Knowledge")
        XCTAssertTrue(app.buttons["settings.memory.learned"].exists, "No What Blau Learned in Settings → Knowledge")

        let status = app.descendants(matching: .any)["settings.memory.status"]
        scrollTo(status, in: app.collectionViews.firstMatch)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "No search index status in Settings → Knowledge")
        XCTAssertTrue(status.label.contains("Search Index"), status.label)
    }

    // MARK: Data

    func testExportingConversationsOffersTheShareSheet() {
        let app = launchOnFakes()
        openSettingsPane(SettingsPaneID.iCloud, in: app)
        let export = app.buttons["settings.icloud.export.prepare"]
        scrollTo(export, in: app.collectionViews.firstMatch)
        export.tap()
        let share = app.buttons["settings.icloud.export.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "No share button after exporting")
        XCTAssertTrue(app.buttons["settings.icloud.export.again"].exists, "No Export Again after exporting")
        share.tap()
        let opened =
            app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
            || app.buttons["Copy"].waitForExistence(timeout: 2)
        XCTAssertTrue(opened, "Share sheet did not open")
    }

    func testDeletingConversationsAsksFirst() {
        let app = launchOnFakes()
        openSettingsPane(SettingsPaneID.privacy, in: app)
        let delete = app.buttons["settings.privacy.delete.conversations"]
        scrollTo(delete, in: app.collectionViews.firstMatch)
        delete.tap()

        // The dialog's button (the row's own title ends in an ellipsis).
        let confirm = app.buttons.matching(identifier: "Delete All Conversations").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation before deleting")
        XCTAssertTrue(
            app.staticTexts["Delete all conversations?"].exists, "The confirmation doesn't say what it deletes")
        confirm.tap()
        let result = app.staticTexts["settings.privacy.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "No result after deleting")
        XCTAssertEqual(result.label, "Deleted 0 conversations.")
    }
}
