import XCTest

/// The xAI key entry points (onboarding and Settings → xAI account) against
/// the app's DEBUG stub (`BLAU_UI_TEST_XAI`): an in-memory key store and
/// canned xAI responses, so these tests never use the network or Keychain.
@MainActor
final class XAIKeyEntryUITests: XCTestCase {
    /// Assembled at runtime so the repository never contains a key-shaped literal.
    private let fakeKey = "xai-" + String(repeating: "UITest0Key", count: 5) + "e5f6"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(stub: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = stub
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    private func enterKey(_ key: String, in app: XCUIApplication) {
        let field = app.secureTextFields["xai.apiKey.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Key field missing")
        field.tap()
        field.typeText(key)
        app.buttons["xai.apiKey.connect"].tap()
    }

    private func assertProblem(
        _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let problem = app.staticTexts["xai.apiKey.problem.title"]
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "No problem shown", file: file, line: line)
        XCTAssertEqual(problem.label, title, file: file, line: line)
    }

    /// The field stays usable after an error: the user can edit and retry.
    private func assertRecoverable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.secureTextFields["xai.apiKey.field"]
        XCTAssertTrue(field.exists, file: file, line: line)
        XCTAssertTrue(field.isEnabled, file: file, line: line)
        XCTAssertTrue(app.buttons["xai.apiKey.connect"].isEnabled, file: file, line: line)

        // Editing clears the error...
        field.tap()
        field.typeText("x")
        XCTAssertTrue(
            app.staticTexts["xai.apiKey.problem.title"].waitForNonExistence(timeout: 5), file: file, line: line)
        // ...and trying again checks again.
        app.buttons["xai.apiKey.connect"].tap()
        XCTAssertTrue(
            app.staticTexts["xai.apiKey.problem.title"].waitForExistence(timeout: 10), file: file, line: line)
    }

    func testInvalidKeyShowsRecoverableErrorInOnboarding() {
        let app = launch(stub: "reject")
        let open = app.buttons["xai.onboarding.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        enterKey(fakeKey, in: app)

        assertProblem("xAI didn't accept this key", in: app)
        assertRecoverable(in: app)
        // The user can still leave onboarding without a key.
        XCTAssertTrue(app.buttons["xai.onboarding.skip"].isHittable)
    }

    func testInvalidKeyShowsRecoverableErrorInSettings() {
        let app = launch(stub: "reject")
        let settings = app.buttons["blau.settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        enterKey(fakeKey, in: app)

        assertProblem("xAI didn't accept this key", in: app)
        assertRecoverable(in: app)
    }

    func testUnfundedKeyIsExplainedInSettings() {
        let app = launch(stub: "unfunded")
        app.buttons["blau.settings.open"].tap()
        enterKey(fakeKey, in: app)
        assertProblem("No xAI credits", in: app)
        XCTAssertFalse(app.buttons["xai.apiKey.saveAnyway"].exists)
    }

    func testOfflineKeyCanBeSavedWithoutChecking() {
        let app = launch(stub: "offline")
        app.buttons["blau.settings.open"].tap()
        enterKey(fakeKey, in: app)
        assertProblem("Couldn't reach xAI", in: app)

        app.buttons["xai.apiKey.saveAnyway"].tap()

        let status = app.descendants(matching: .any)["xai.account.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "e5f6", in: app).exists)
    }

    /// Settings rows (`LabeledContent`) merge label and value into one
    /// accessibility element, so match on a fragment of the label.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testValidKeyConnectsFromOnboardingAndShowsInSettings() {
        let app = launch(stub: "accept")
        app.buttons["xai.onboarding.open"].tap()
        enterKey(fakeKey, in: app)

        // Onboarding finishes and the prompt disappears from the main screen.
        XCTAssertTrue(app.buttons["xai.onboarding.open"].waitForNonExistence(timeout: 10))

        app.buttons["blau.settings.open"].tap()
        XCTAssertTrue(element(containing: "e5f6", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "UI test key", in: app).exists)
        XCTAssertFalse(app.secureTextFields["xai.apiKey.field"].exists)
    }
}
