import XCTest

/// The issue banner above the conversation (#80). Launches on fake services
/// with one catalog entry shown (`-BlauIssueFixture <code>`).
@MainActor
final class IssueBannerUITests: XCTestCase {
    private enum Identifier {
        static let banner = "blau.issue"
        static let title = "blau.issue.title"
        static let dismiss = "blau.issue.dismiss"
        static let discard = "blau.issue.action.discardQueued"
        static let updateKey = "blau.issue.action.updateAPIKey"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(issue code: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauIssueFixture", code]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func testOfflineShowsTheWaitingMessagesWithDiscardAndCanBeDismissed() {
        let app = launch(issue: "connection.offline")
        let banner = element(Identifier.banner, in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertEqual(banner.value as? String, "connection.offline")
        XCTAssertTrue(app.staticTexts["You're offline"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "2 messages are waiting to send"))
                .firstMatch.exists)
        XCTAssertTrue(app.buttons[Identifier.discard].isHittable)

        app.buttons[Identifier.dismiss].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }

    func testAMissingKeyCantBeDismissedAndOpensKeyEntry() {
        let app = launch(issue: "account.missingKey")
        XCTAssertTrue(element(Identifier.banner, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connect your xAI account"].exists)
        XCTAssertFalse(app.buttons[Identifier.dismiss].exists)

        app.buttons[Identifier.updateKey].tap()
        // The xAI key onboarding step: Skip for Now, or the connected
        // status if the hermetic account already has a key.
        let skip = element("xai.onboarding.skip", in: app)
        let connected = element("xai.account.status", in: app)
        XCTAssertTrue(skip.waitForExistence(timeout: 5) || connected.exists, "The key entry didn't open")
    }
}
