import XCTest

/// The app without iCloud: a simulator with no Apple Account, or an unsigned
/// build without the iCloud entitlement. Either way Blau must launch, keep
/// data on the device and say so in Settings.
@MainActor
final class ICloudSyncUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Launches Blau with the xAI DEBUG stub (an in-memory key store, no
    /// network), so these tests never touch the Keychain or xAI.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "offline"
        // Fixture speech models: no real model download from a UI test.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        return app
    }

    /// Opens Settings and returns the iCloud status row.
    private func openICloudStatus(in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 10))
        // Settings → iCloud.
        openSettingsPane(SettingsPaneID.iCloud, in: app)
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10), "Settings → iCloud did not open")
        let status = app.descendants(matching: .any)["settings.icloud.status"]
        scrollTo(status, in: form)
        XCTAssertTrue(status.exists, "iCloud status row missing from Settings")
        return status
    }

    func testLaunchesWithTheOnDiskStoreAndICloudOff() throws {
        let app = makeApp()
        app.launch()

        let status = openICloudStatus(in: app)
        // No iCloud on a test simulator (no Apple Account, or no entitlement
        // in an unsigned build), so sync is off and data stays on device.
        XCTAssertTrue(status.label.contains("iCloud Sync"), status.label)
        XCTAssertTrue(status.label.contains("Off"), status.label)
        let reassurance = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Everything is saved on this iPhone"))
        XCTAssertTrue(reassurance.firstMatch.exists)

        // A signed build asks CloudKit for the account. With no Apple Account
        // on the simulator it settles on "Not signed in"; if cloudd is slow it
        // shows "Unknown" until it answers. Either way it must never claim to
        // be signed in, and sync stays off. An unsigned build never asks, so
        // the row is absent.
        let accountRow = app.descendants(matching: .any)["settings.icloud.account"]
        if accountRow.exists {
            let signedOut = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "Not signed in"), object: accountRow)
            let settled = XCTWaiter.wait(for: [signedOut], timeout: 45) == .completed
            print("ICloudSyncUITests: account row = \(accountRow.label), settled = \(settled)")
            XCTAssertFalse(accountRow.label.hasSuffix(", Signed in"), accountRow.label)
            XCTAssertTrue(status.label.contains("Off"), status.label)
        }
        print("ICloudSyncUITests: account row shown = \(accountRow.exists)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "iCloud settings without an account"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testInMemoryStoreForUITestsIsReported() throws {
        let app = makeApp()
        app.launchArguments += ["-BlauStore", "memory"]
        app.launch()

        let status = openICloudStatus(in: app)
        XCTAssertTrue(status.label.contains("Not saving"), status.label)
    }
}
