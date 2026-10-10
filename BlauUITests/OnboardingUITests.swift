import XCTest

/// Onboarding (#44) end to end on fake services: the xAI stub
/// (`BLAU_UI_TEST_XAI`), a stub microphone permission
/// (`BLAU_UI_TEST_MICROPHONE`, so the system alert never appears) and
/// fixture speech models. `BLAU_UI_TEST_ONBOARDING` turns onboarding on and
/// says how its saved progress starts (`fresh`, `resume`, `finished`).
@MainActor
final class OnboardingUITests: XCTestCase {
    /// Assembled at runtime so the repository never contains a key-shaped literal.
    private let fakeKey = "xai-" + String(repeating: "Onboard0Key", count: 4) + "e5f6"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(onboarding: String, microphone: String, app: XCUIApplication = XCUIApplication())
        -> XCUIApplication
    {
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchEnvironment["BLAU_UI_TEST_ONBOARDING"] = onboarding
        app.launchEnvironment["BLAU_UI_TEST_MICROPHONE"] = microphone
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "accept"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    /// The page for `step`, once it is on screen.
    @discardableResult
    private func page(
        _ step: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let page = app.descendants(matching: .any)["blau.onboarding.step.\(step)"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "The \(step) page didn't appear", file: file, line: line)
        return page
    }

    /// Taps the page's main button.
    private func tapPrimary(
        on step: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let button = page(step, in: app, file: file, line: line).buttons["blau.onboarding.primary"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No main button on \(step)", file: file, line: line)
        button.tap()
    }

    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "Expected \(value), value: \(String(describing: element.value))")
    }

    /// Acceptance criterion: a fresh install reaches a working conversation
    /// through onboarding.
    func testFreshInstallReachesAWorkingConversation() {
        let app = launch(onboarding: "fresh", microphone: "undetermined")
        XCTAssertFalse(app.buttons["blau.record"].exists, "Onboarding should come before the main screen")

        tapPrimary(on: "welcome", in: app)

        // The key is checked with xAI (the stub) before it is stored.
        page("xaiAccount", in: app)
        let field = app.secureTextFields["xai.apiKey.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(fakeKey)
        app.buttons["xai.apiKey.connect"].tap()

        // Allow Microphone answers the (stubbed) prompt and moves on.
        tapPrimary(on: "microphone", in: app)

        // The fixture models start downloading at launch and are usually
        // ready by now, in which case setup passes over their page. If it is
        // still there: progress, then Continue once they are ready.
        let models = app.descendants(matching: .any)["blau.onboarding.step.speechModels"]
        let iCloudPage = app.descendants(matching: .any)["blau.onboarding.step.iCloud"]
        let either = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in models.exists || iCloudPage.exists }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [either], timeout: 15), .completed, "No page after the microphone")
        if models.exists {
            XCTAssertTrue(models.descendants(matching: .any)["blau.models.setup"].waitForExistence(timeout: 10))
            let continueButton = models.buttons["blau.onboarding.primary"]
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Continue'"), object: continueButton)
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 120), .completed, "The models never became ready")
            continueButton.tap()
        }

        let iCloud = page("iCloud", in: app)
        XCTAssertTrue(iCloud.descendants(matching: .any)["blau.onboarding.iCloud.status"].exists)
        tapPrimary(on: "iCloud", in: app)

        tapPrimary(on: "voiceEnrollment", in: app)

        let aboutYou = page("aboutYou", in: app)
        let about = aboutYou.descendants(matching: .any)["blau.onboarding.aboutYou.field"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        about.typeText("I'm testing Blau.")
        tapPrimary(on: "aboutYou", in: app)

        let done = page("ready", in: app)
        XCTAssertFalse(
            done.descendants(matching: .any)["blau.onboarding.ready.missing"].exists,
            "Nothing should be missing after a full setup")
        tapPrimary(on: "ready", in: app)

        // The main screen, and a conversation that starts and listens.
        let record = app.buttons["blau.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "The main screen didn't appear after onboarding")
        XCTAssertFalse(app.descendants(matching: .any)["blau.onboarding"].exists)
        record.tap()
        waitForValue("Listening", of: record)
        record.tap()
        waitForValue("Not listening", of: record)
    }

    /// Acceptance criterion: denied microphone permission shows a recovery
    /// path to Settings.app.
    func testDeniedMicrophoneOffersTheWayToSettings() {
        let app = launch(onboarding: "fresh", microphone: "denied")
        tapPrimary(on: "welcome", in: app)
        page("xaiAccount", in: app)
        app.buttons["xai.onboarding.skip"].tap()

        let microphone = page("microphone", in: app)
        let status = microphone.staticTexts["blau.onboarding.microphone.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Microphone not allowed")
        let openSettings = microphone.buttons["blau.onboarding.openSettings"]
        XCTAssertTrue(openSettings.exists, "No way to the Settings app")
        XCTAssertTrue(microphone.buttons["blau.onboarding.skip"].exists, "The user should be able to go on without it")

        openSettings.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "The Settings app didn't open")

        // Back in Blau, the same page is waiting.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(page("microphone", in: app).buttons["blau.onboarding.openSettings"].exists)
    }

    /// Setup interrupted (here: the app is terminated, as iOS does after a
    /// privacy change in Settings) resumes on the step where it stopped.
    func testInterruptedSetupResumesWhereItStopped() {
        let app = launch(onboarding: "fresh", microphone: "undetermined")
        tapPrimary(on: "welcome", in: app)
        page("xaiAccount", in: app)
        app.buttons["xai.onboarding.skip"].tap()
        page("microphone", in: app)
        app.terminate()

        let relaunched = launch(onboarding: "resume", microphone: "granted")
        let microphone = page("microphone", in: relaunched)
        XCTAssertFalse(relaunched.descendants(matching: .any)["blau.onboarding.step.welcome"].exists)
        // Allowed in the meantime: the page says so and moves on.
        XCTAssertEqual(microphone.staticTexts["blau.onboarding.microphone.status"].label, "Microphone allowed")
        tapPrimary(on: "microphone", in: relaunched)
        // Downloads can finish while the runner inspects the microphone
        // page. As on a fresh install, ready models skip their setup page.
        let models = relaunched.descendants(matching: .any)["blau.onboarding.step.speechModels"]
        let iCloud = relaunched.descendants(matching: .any)["blau.onboarding.step.iCloud"]
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in models.exists || iCloud.exists }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [advanced], timeout: 15), .completed, "Setup didn't advance")
        if models.exists {
            XCTAssertTrue(models.descendants(matching: .any)["blau.models.setup"].waitForExistence(timeout: 10))
            XCTAssertTrue(models.buttons["blau.onboarding.primary"].exists)
        } else {
            XCTAssertTrue(iCloud.descendants(matching: .any)["blau.onboarding.iCloud.status"].exists)
        }
    }

    /// After setup, onboarding comes back with only the missing
    /// requirements (here no key and no microphone), and Not Now leaves it.
    func testFinishedSetupComesBackForMissingRequirements() {
        let app = launch(onboarding: "finished", microphone: "denied")
        // Recovery: no welcome, straight to what's missing.
        page("xaiAccount", in: app)
        XCTAssertTrue(app.buttons["blau.onboarding.notNow"].exists)
        app.buttons["xai.onboarding.skip"].tap()

        let microphone = page("microphone", in: app)
        XCTAssertTrue(microphone.buttons["blau.onboarding.openSettings"].exists)
        app.buttons["blau.onboarding.notNow"].tap()

        XCTAssertTrue(app.buttons["blau.record"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["blau.onboarding"].exists)
    }

    /// Finished setup with nothing missing opens on the main screen.
    func testFinishedSetupWithEverythingInPlaceOpensTheMainScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchEnvironment["BLAU_UI_TEST_ONBOARDING"] = "finished"
        app.launchEnvironment["BLAU_UI_TEST_MICROPHONE"] = "granted"
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "accept"
        // An unsatisfied key would bring it back, so connect one first...
        app.launch()
        page("xaiAccount", in: app)
        let field = app.secureTextFields["xai.apiKey.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(fakeKey)
        app.buttons["xai.apiKey.connect"].tap()
        // ...which was the only thing missing.
        XCTAssertTrue(app.buttons["blau.record"].waitForExistence(timeout: 10))
    }
}
