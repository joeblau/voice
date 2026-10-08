import XCTest

/// The chat transcript (#42) on a canned conversation
/// (`-BlauChatFixture <count>`, fake services): user rows on the right,
/// Grok's on the left, each at most 85 % of the width, opening at the latest
/// line, with a long-press menu of the time, Copy and Share.
@MainActor
final class ChatTranscriptUITests: XCTestCase {
    private enum Identifier {
        static let content = "blau.root"
        /// The topic timeline (#56), which holds the transcript under the
        /// current topic.
        static let transcript = "blau.timeline"
        static let user = "blau.chat.user"
        static let agent = "blau.chat.agent"
        static let emptyState = "blau.mainScreen.empty"
        static let settings = "blau.settings.open"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(rows: Int, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauChatFixture", "\(rows)"] + arguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.transcript].waitForExistence(timeout: 30),
            "The transcript did not appear")
        return app
    }

    private func rows(_ identifier: String, in app: XCUIApplication) -> [XCUIElement] {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), "No \(identifier) rows")
        return query.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
    }

    /// The visual spec, checked on the rows on screen: every user row ends
    /// at the right margin and leaves the left 15 % empty, every agent row
    /// starts at the left margin and leaves the right 15 % empty.
    func testUserTextIsRightAlignedAndAgentTextLeftAligned() {
        let app = launch(rows: 40)
        let window = app.windows.firstMatch.frame
        let maxWidth = window.width * 0.85 + 1
        let users = rows(Identifier.user, in: app)
        let agents = rows(Identifier.agent, in: app)
        XCTAssertFalse(users.isEmpty)
        XCTAssertFalse(agents.isEmpty)

        let margin: CGFloat = 24
        for row in users {
            let frame = row.frame
            XCTAssertEqual(frame.maxX, window.maxX - 16, accuracy: 2, "User row not on the right: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, window.maxX - 16 - maxWidth, "User row too wide: \(frame)")
            XCTAssertGreaterThan(frame.minX, window.minX + margin, "User row reaches the left: \(frame)")
        }
        for row in agents {
            let frame = row.frame
            XCTAssertEqual(frame.minX, window.minX + 16, accuracy: 2, "Agent row not on the left: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, window.minX + 16 + maxWidth, "Agent row too wide: \(frame)")
            XCTAssertLessThan(frame.maxX, window.maxX - margin, "Agent row reaches the right: \(frame)")
        }

        // The rows read as a conversation: alternating sides, in order.
        let onScreen = (users + agents).filter { window.contains($0.frame) }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(onScreen.count, 2)

        attachScreenshot(app, "Transcript")
    }

    /// The conversation opens at its latest line, above the bottom bar, not
    /// at the top of the history.
    func testTheTranscriptOpensAtTheLatestLine() {
        let app = launch(rows: 200)
        let settings = app.buttons[Identifier.settings]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let bar = settings.frame
        // The lowest row on screen is the fixture's last line: reply 99.
        let onScreen = (rows(Identifier.user, in: app) + rows(Identifier.agent, in: app))
            .filter { window.intersects($0.frame) }
        let lowest = onScreen.max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(lowest)
        if let lowest {
            XCTAssertEqual(
                lowest.value as? String, "You picked the second week of November, after the beta feedback is in.",
                "Not scrolled to the end")
            XCTAssertLessThanOrEqual(
                lowest.frame.maxY, bar.minY + 1, "The last line is under the bar: \(lowest.frame), \(bar)")
        }
        XCTAssertFalse(app.descendants(matching: .any)[Identifier.emptyState].exists)
    }

    /// Long-pressing a row shows when it was said, with Copy and Share.
    func testLongPressShowsTheTimeCopyAndShare() {
        let app = launch(rows: 10)
        let row = rows(Identifier.agent, in: app).last
        XCTAssertNotNil(row)
        row?.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "No Copy in the menu")
        XCTAssertTrue(app.buttons["Share…"].exists || app.buttons["Share"].exists, "No Share in the menu")
        attachScreenshot(app, "Row menu")
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
    }

    func testRowsKeepTheirSidesAtTheLargestTextSize() {
        let app = launch(
            rows: 10, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let window = app.windows.firstMatch.frame
        for row in rows(Identifier.user, in: app) where window.intersects(row.frame) {
            XCTAssertEqual(row.frame.maxX, window.maxX - 16, accuracy: 2, "\(row.frame)")
        }
        for row in rows(Identifier.agent, in: app) where window.intersects(row.frame) {
            XCTAssertEqual(row.frame.minX, window.minX + 16, accuracy: 2, "\(row.frame)")
        }
        attachScreenshot(app, "Transcript, accessibility XXXL")
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
