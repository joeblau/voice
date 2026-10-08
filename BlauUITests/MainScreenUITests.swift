import XCTest

/// The main screen scaffold (#40): Settings bottom-left and Record
/// bottom-right in the bottom bar, found by accessibility identifier, in
/// portrait, in landscape and at the largest text size. Runs on fake services
/// (`BLAU_APP_ENVIRONMENT=ui-test`), so the record button drives a fake
/// microphone and nothing touches the network or the Keychain.
///
/// Run it on more than one simulator to cover the iPhone sizes, for example
/// the smallest (iPhone SE) and the largest (Pro Max): see docs/app-shell.md.
@MainActor
final class MainScreenUITests: XCTestCase {
    private enum Identifier {
        static let content = "blau.root"
        static let settings = "blau.settings.open"
        static let record = "blau.record"
        static let emptyState = "blau.mainScreen.empty"
        /// The speech-model setup card (#99), shown while the fixture models
        /// "download" after every `ui-test` launch.
        static let modelSetup = "blau.models.setup"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.content].waitForExistence(timeout: 30),
            "The main screen did not appear")
        return app
    }

    private func settingsButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[Identifier.settings]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No settings button")
        return button
    }

    private func recordButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[Identifier.record]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No record button")
        return button
    }

    /// Settings sits in the left quarter and Record in the right quarter of
    /// the window, side by side in the bottom quarter, both on screen and
    /// tappable, and the speech-model setup card (while it shows) sits above
    /// them instead of covering them.
    private func assertBottomBarLayout(
        _ app: XCUIApplication, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        let settingsButton = settingsButton(app)
        let recordButton = recordButton(app)
        let settings = settingsButton.frame
        let record = recordButton.frame
        let details = "\(context): window \(window), settings \(settings), record \(record)"
        print("MainScreenUITests: \(details)")

        XCTAssertTrue(settingsButton.isHittable, "Settings isn't tappable. \(details)", file: file, line: line)
        XCTAssertTrue(recordButton.isHittable, "Record isn't tappable. \(details)", file: file, line: line)
        XCTAssertTrue(window.contains(settings), "Settings is off screen. \(details)", file: file, line: line)
        XCTAssertTrue(window.contains(record), "Record is off screen. \(details)", file: file, line: line)

        // Left and right.
        XCTAssertLessThan(
            settings.maxX, record.minX, "Settings isn't left of Record. \(details)", file: file, line: line)
        XCTAssertLessThan(
            settings.midX, window.minX + window.width * 0.25, "Settings isn't on the left. \(details)", file: file,
            line: line)
        XCTAssertGreaterThan(
            record.midX, window.minX + window.width * 0.75, "Record isn't on the right. \(details)", file: file,
            line: line)

        // Bottom, on one row.
        let bottomQuarter = window.minY + window.height * 0.75
        XCTAssertGreaterThan(
            settings.midY, bottomQuarter, "Settings isn't at the bottom. \(details)", file: file, line: line)
        XCTAssertGreaterThan(
            record.midY, bottomQuarter, "Record isn't at the bottom. \(details)", file: file, line: line)
        XCTAssertEqual(
            settings.midY, record.midY, accuracy: 8, "Settings and Record aren't on one row. \(details)", file: file,
            line: line)

        // Clear of the setup card. A snapshot rather than `frame`, because the
        // card can finish and go away between the check and the read.
        if let card = try? app.descendants(matching: .any)[Identifier.modelSetup].snapshot().frame {
            let cardDetails = "\(details), setup card \(card)"
            print("MainScreenUITests: \(cardDetails)")
            XCTAssertFalse(
                settings.intersects(card), "The setup card covers Settings. \(cardDetails)", file: file, line: line)
            XCTAssertFalse(
                record.intersects(card), "The setup card covers Record. \(cardDetails)", file: file, line: line)
            XCTAssertLessThanOrEqual(
                card.maxY, min(settings.minY, record.minY), "The setup card isn't above the bottom bar. \(cardDetails)",
                file: file, line: line)
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Main screen, \(context)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSettingsIsBottomLeftAndRecordIsBottomRight() {
        let app = launch()
        assertBottomBarLayout(app, "portrait")
    }

    /// The content runs under the bottom bar's glass instead of stopping
    /// above it.
    func testContentScrollsUnderTheBottomBar() {
        let app = launch()
        let content = app.descendants(matching: .any)[Identifier.content].frame
        let bar = settingsButton(app).frame
        XCTAssertGreaterThanOrEqual(content.maxY, bar.maxY, "content \(content), bar item \(bar)")
    }

    /// Before there is a conversation, the empty state sits in the middle of
    /// the area between the bars rather than against the bottom bar.
    ///
    /// Measured once the speech models are ready: while the setup card shows
    /// it takes bottom safe area, so the empty state is centered above the
    /// card instead (the card's own placement is checked by
    /// `assertBottomBarLayout`).
    func testEmptyStateIsCenteredAboveTheBottomBar() {
        let app = launch()
        let setup = app.descendants(matching: .any)[Identifier.modelSetup]
        // Each ui-test launch starts from a fresh fixture install, so the card
        // appears once the model check finishes; wait for it, then for the
        // models to be ready. If it already came and went, the first wait just
        // times out.
        _ = setup.waitForExistence(timeout: 5)
        XCTAssertTrue(setup.waitForNonExistence(timeout: 120), "The speech models never became ready")

        let window = app.windows.firstMatch.frame
        let empty = app.descendants(matching: .any)[Identifier.emptyState]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "No empty state")
        let bar = settingsButton(app).frame
        // Let the card's removal animation settle before measuring.
        let centered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(empty.frame.midY - window.midY) <= window.height * 0.1
            }, object: nil)
        _ = XCTWaiter.wait(for: [centered], timeout: 5)
        let frame = empty.frame
        let details = "window \(window), empty state \(frame), bar item \(bar)"
        XCTAssertFalse(setup.exists, "The setup card came back while measuring. \(details)")
        XCTAssertLessThan(frame.maxY, bar.minY, "The empty state runs into the bar. \(details)")
        XCTAssertEqual(frame.midY, window.midY, accuracy: window.height * 0.1, "Not centered. \(details)")
    }

    func testLayoutHoldsInLandscape() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let settings = settingsButton(app)
        // Wait for the rotation to finish and the bar to settle at the bottom
        // left of the landscape window.
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let bounds = window.frame
                let button = settings.frame
                return bounds.width > bounds.height && button.midX < bounds.midX
                    && button.midY > bounds.minY + bounds.height * 0.75
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 15), .completed,
            "The app didn't rotate: window \(window.frame), settings \(settings.frame)")
        assertBottomBarLayout(app, "landscape")
    }

    func testLayoutHoldsAtTheLargestTextSize() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        assertBottomBarLayout(app, "accessibility XXXL text")
    }

    func testSettingsButtonOpensSettings() {
        let app = launch()
        settingsButton(app).tap()
        // The settings sheet (#43): its first row is the xAI account, which
        // opens the key's status. SettingsUITests covers the other panes.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        let account = app.buttons["settings.pane.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Settings has no xAI Account row")
        account.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["xai.account.status"].waitForExistence(timeout: 10),
            "Settings → xAI Account has no key status")
    }

    private func waitForValue(
        _ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
            "Expected \(value), value: \(String(describing: element.value))", file: file, line: line)
    }

    /// Tap starts a conversation and tap ends it (#41). The `ui-test`
    /// environment runs a `FakeConversationSession` over the fake
    /// microphone, so it listens at once.
    func testRecordButtonStartsAndEndsTheConversation() {
        let app = launch()
        let record = recordButton(app)
        XCTAssertEqual(record.label, "Start Conversation")
        XCTAssertEqual(record.value as? String, "Not listening")

        record.tap()
        waitForValue("Listening", of: record)
        XCTAssertEqual(record.label, "End Conversation")
        assertBottomBarLayout(app, "listening")

        record.tap()
        waitForValue("Not listening", of: record)
        XCTAssertEqual(record.label, "Start Conversation")
    }

    /// Touch and hold offers Pause Listening while a conversation runs; the
    /// conversation keeps going, muted, until Resume Listening.
    func testLongPressPausesAndResumesListening() {
        let app = launch()
        let record = recordButton(app)
        record.tap()
        waitForValue("Listening", of: record)

        record.press(forDuration: 1.0)
        let pause = app.buttons["Pause Listening"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "No Pause Listening in the long-press menu")
        XCTAssertTrue(app.buttons["End Conversation"].exists, "No End Conversation in the long-press menu")
        pause.tap()
        waitForValue("Paused, microphone muted", of: record)
        XCTAssertEqual(record.label, "End Conversation")
        assertBottomBarLayout(app, "paused")

        record.press(forDuration: 1.0)
        let resume = app.buttons["Resume Listening"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "No Resume Listening in the long-press menu")
        resume.tap()
        waitForValue("Listening", of: record)

        // A tap while paused or listening ends the conversation.
        record.tap()
        waitForValue("Not listening", of: record)
    }
}
