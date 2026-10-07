import XCTest

/// Settings → Markdown Export (#78). A test simulator has no iCloud Drive
/// (no Apple Account, or an unsigned build without the entitlement), so
/// "Export Now" must explain why it can't export instead of failing
/// silently. Files in iCloud Drive → Blau need a signed build on a device
/// signed in to iCloud: see the manual test plan in docs/export.md.
@MainActor
final class MarkdownExportUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchIntoSettings() -> XCUIApplication {
        let app = XCUIApplication()
        // The DEBUG xAI stub (no Keychain, no network); it also keeps the
        // export settings in the `blau.uitests` defaults suite.
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "offline"
        // Fixture speech models: no real model download from a UI test.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 10))
        app.buttons["blau.settings.open"].tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10), "Settings did not open")
        return app
    }

    func testExportNowExplainsWhyICloudDriveIsUnavailable() {
        let app = launchIntoSettings()
        let form = app.collectionViews.firstMatch
        let exportNow = app.buttons["settings.export.now"]
        scrollTo(exportNow, in: form)
        XCTAssertTrue(app.switches["settings.export.automatic"].exists, "Export Automatically toggle missing")

        exportNow.tap()

        let status = app.descendants(matching: .any)["settings.export.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "No export status after Export Now")
        scrollTo(status, in: form)
        // Unsigned build: not signed for iCloud. Signed build on a simulator
        // without an Apple Account: iCloud Drive isn't available.
        XCTAssertTrue(
            status.label.contains("isn't signed for iCloud") || status.label.contains("iCloud Drive isn't available"),
            status.label)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Markdown export without iCloud Drive"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
