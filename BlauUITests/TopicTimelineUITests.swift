import XCTest

/// The topic timeline (#56) on a canned history (`-BlauTimelineFixture
/// <topics>`, fake services): 12 topics over three conversations (two days
/// ago, yesterday, today), four lines each, the last topic open with a
/// provisional title. Every third topic starts provisional ("Draft <n>").
@MainActor
final class TopicTimelineUITests: XCTestCase {
    private enum Identifier {
        static let timeline = "blau.timeline"
        static let current = "blau.timeline.topic.current"
        static let topic = "blau.timeline.topic"
        static let summary = "blau.timeline.topic.summary"
        static let day = "blau.timeline.day"
        static let now = "blau.timeline.now"
        static let user = "blau.chat.user"
        static let agent = "blau.chat.agent"
        static let settings = "blau.settings.open"
        /// The speech-model setup card, shown while the fixture models
        /// "download" after every `ui-test` launch. It insets the timeline
        /// from below until it goes.
        static let modelSetup = "blau.models.setup"
    }

    /// The fixture's topics, oldest first, as their refined titles.
    private static let topicCount = 12
    private static let linesPerTopic = 4
    private static let oldestTitle = "Seed Round Planning"
    /// The topic just above the current one.
    private static let previousTitle = "Sourdough Starter"
    /// Its first line.
    private static let previousTopicFirstLine = "How long would that take if I started tomorrow morning?"

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauTimelineFixture", "\(Self.topicCount)"] + arguments
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.timeline].waitForExistence(timeout: 30),
            "The timeline did not appear")
        XCTAssertTrue(currentBullet(app).waitForExistence(timeout: 30), "No current topic")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 30),
            "The model setup card stayed")
        waitUntilStill(currentBullet(app))
        return app
    }

    /// Waits until `element` stops moving: the timeline settles after the
    /// fixture lands and the setup card leaves.
    private func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        var stillSince = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let frame = element.frame
            if frame != last {
                last = frame
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 1 {
                return
            }
        }
        XCTFail("\(element) kept moving")
    }

    private func currentBullet(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[Identifier.current]
    }

    private func bullet(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Identifier.topic).matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    /// The compressed and expanded older bullets laid out on screen.
    private func olderBullets(_ app: XCUIApplication) -> [XCUIElement] {
        let window = app.windows.firstMatch.frame
        return app.buttons.matching(identifier: Identifier.topic).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && window.intersects($0.frame) }
    }

    /// The transcript rows in the accessibility tree: only those of
    /// expanded topics are built.
    private func transcriptRowCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: Identifier.user).count
            + app.descendants(matching: .any).matching(identifier: Identifier.agent).count
    }

    private func swipeIntoHistory(_ app: XCUIApplication, until element: XCUIElement, maxSwipes: Int = 8) {
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            timeline.swipeDown()
            swipes += 1
        }
    }

    // MARK: Tests

    /// It opens on the current topic: its bullet on screen with its
    /// transcript below it, older topics' bullets above it in the same
    /// screen, each compressed to one row of the same height, and only the
    /// current topic's lines built.
    func testOpensOnTheCurrentTopicWithBulletsAboveTheFold() {
        let app = launch()
        let window = app.windows.firstMatch.frame
        let current = currentBullet(app)
        XCTAssertTrue(current.isHittable, "The current topic isn't on screen: \(current.frame)")
        XCTAssertTrue(window.contains(current.frame))

        // The current topic's lines, below its bullet, ending above the bar.
        let settings = app.buttons[Identifier.settings]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let rows =
            (app.descendants(matching: .any).matching(identifier: Identifier.user).allElementsBoundByIndex
            + app.descendants(matching: .any).matching(identifier: Identifier.agent).allElementsBoundByIndex)
            .filter { $0.exists && window.intersects($0.frame) }
        XCTAssertEqual(rows.count, Self.linesPerTopic, "Only the current topic is expanded")
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.frame.minY, current.frame.maxY - 1, "A line above its bullet: \(row.frame)")
            XCTAssertLessThanOrEqual(row.frame.maxY, settings.frame.minY + 1, "A line under the bar: \(row.frame)")
        }
        XCTAssertEqual(transcriptRowCount(app), Self.linesPerTopic, "Older topics' lines were built")
        XCTAssertFalse(app.descendants(matching: .any)[Identifier.summary].exists, "An older topic is expanded")

        // Older bullets above the fold, compressed to rows of one height.
        let older = olderBullets(app)
        XCTAssertGreaterThanOrEqual(older.count, 3, "Too few older bullets on screen")
        let heights = older.map(\.frame.height)
        for bullet in older {
            XCTAssertLessThan(bullet.frame.maxY, current.frame.minY + 1, "\(bullet.label) is below the current topic")
            XCTAssertEqual(bullet.frame.height, heights[0], accuracy: 1, "\(bullet.label) isn't one row")
            XCTAssertTrue((bullet.value as? String ?? "").hasSuffix("collapsed"), "\(bullet.label) is expanded")
        }
        XCTAssertFalse(app.buttons[Identifier.now].exists, "The Now pill shows at the latest line")
        attachScreenshot(app, "Opened on the current topic")
    }

    /// Swiping down reveals the oldest topics and the Now pill; Now returns
    /// to the current topic's latest line.
    func testSwipeDownRevealsHistoryAndNowReturns() {
        let app = launch()
        let oldest = bullet(Self.oldestTitle, in: app)
        XCTAssertFalse(oldest.exists && oldest.isHittable, "The oldest topic is already on screen")

        swipeIntoHistory(app, until: oldest)
        XCTAssertTrue(oldest.isHittable, "Swiping down didn't reveal the oldest topic")
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.day].firstMatch.exists, "No day heading")
        attachScreenshot(app, "History")
        let now = app.buttons[Identifier.now]
        XCTAssertTrue(now.waitForExistence(timeout: 5), "No Now pill in the history")

        now.tap()
        XCTAssertTrue(now.waitForNonExistence(timeout: 5), "The Now pill stayed")
        XCTAssertTrue(currentBullet(app).isHittable, "Now didn't return to the current topic")
        XCTAssertFalse(oldest.isHittable, "Still in the history")

        // Swiping back works too.
        swipeIntoHistory(app, until: oldest)
        XCTAssertTrue(now.waitForExistence(timeout: 5))
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        for _ in 0..<6 where now.exists {
            timeline.swipeUp()
        }
        XCTAssertTrue(now.waitForNonExistence(timeout: 5), "Swiping back didn't reach the latest line")
        XCTAssertTrue(currentBullet(app).isHittable)

        // So does tapping the current topic's bullet.
        swipeIntoHistory(app, until: bullet(Self.previousTitle, in: app), maxSwipes: 1)
        timeline.swipeDown()
        if now.waitForExistence(timeout: 5), currentBullet(app).isHittable {
            currentBullet(app).tap()
            XCTAssertTrue(now.waitForNonExistence(timeout: 5), "Tapping the current topic didn't return")
        }
    }

    /// Tapping a compressed bullet expands it inline, in place; tapping it
    /// again compresses it.
    func testTappingABulletExpandsAndCompressesIt() {
        let app = launch()
        let previous = bullet(Self.previousTitle, in: app)
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        XCTAssertTrue((previous.value as? String ?? "").hasSuffix("collapsed"), "\(previous.value ?? "")")
        let before = previous.frame

        previous.tap()
        let summary = app.descendants(matching: .any)[Identifier.summary]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "No summary under the expanded bullet")
        XCTAssertTrue((previous.value as? String ?? "").hasSuffix("expanded"), "\(previous.value ?? "")")
        XCTAssertEqual(previous.frame.minY, before.minY, accuracy: 2, "The tapped bullet moved")
        XCTAssertGreaterThan(summary.frame.minY, previous.frame.minY, "The topic didn't open below its bullet")
        // Its first line, below the summary (rows further down, the
        // current topic's among them, may be past the fold and not built).
        let firstLine = app.descendants(matching: .any).matching(identifier: Identifier.user)
            .matching(NSPredicate(format: "value == %@", Self.previousTopicFirstLine)).firstMatch
        XCTAssertTrue(firstLine.waitForExistence(timeout: 5), "The topic's lines aren't shown")
        XCTAssertGreaterThan(firstLine.frame.minY, summary.frame.minY, "A line above the summary")
        attachScreenshot(app, "Expanded")

        previous.tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5), "The topic didn't compress")
        XCTAssertTrue((previous.value as? String ?? "").hasSuffix("collapsed"))
        XCTAssertFalse(firstLine.exists, "The topic's lines stayed")
    }

    /// Collapsing an older topic while at the latest line stays at the
    /// latest line: no Now pill, and the current topic in view. (The
    /// at-bottom state comes from the scroll geometry alone, so a collapse
    /// that leaves the view at the bottom can't leave it stuck as "away".)
    func testCollapsingAtTheLatestLineDoesntShowNow() {
        let app = launch()
        let previous = bullet(Self.previousTitle, in: app)
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        let now = app.buttons[Identifier.now]

        previous.tap()
        let summary = app.descendants(matching: .any)[Identifier.summary]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The topic didn't expand")
        // Its transcript pushed the latest line out of view.
        XCTAssertTrue(now.waitForExistence(timeout: 5), "No Now pill after expanding at the latest line")

        // Back to the latest line, with the expanded topic still on screen.
        now.tap()
        XCTAssertTrue(now.waitForNonExistence(timeout: 5), "Now didn't return to the latest line")
        waitUntilStill(currentBullet(app))
        XCTAssertTrue(previous.isHittable, "The expanded topic's bullet isn't on screen: \(previous.frame)")
        let currentBefore = currentBullet(app).frame

        previous.tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5), "The topic didn't compress")
        waitUntilStill(currentBullet(app))
        XCTAssertFalse(now.waitForExistence(timeout: 2), "The Now pill showed at the latest line")
        XCTAssertTrue(currentBullet(app).isHittable, "The current topic left the screen")
        XCTAssertGreaterThanOrEqual(
            currentBullet(app).frame.minY, currentBefore.minY - 1, "The current topic moved up: \(currentBefore)")
        attachScreenshot(app, "Collapsed at the latest line")
    }

    /// Provisional titles are refined in place while the user reads the
    /// history: the titles change and nothing on screen moves.
    func testRefinedLabelsDontMoveTheHistory() {
        let relabelAfter: TimeInterval = 30
        let launchedAt = Date()
        let app = launch(arguments: ["-BlauTimelineRelabelAfter", "\(Int(relabelAfter))"])
        let drafts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Draft'"))
        XCTAssertGreaterThan(drafts.count, 0, "No provisional titles")
        swipeIntoHistory(app, until: bullet("Hiring the First Engineer", in: app))
        XCTAssertTrue(app.buttons[Identifier.now].waitForExistence(timeout: 5), "Not in the history")
        XCTAssertLessThan(Date().timeIntervalSince(launchedAt), relabelAfter, "Too slow to reach the history first")

        let before = olderBullets(app).map(\.frame).sorted { $0.minY < $1.minY }
        let refined = expectation(
            for: NSPredicate(format: "count == 0"), evaluatedWith: drafts, handler: nil)
        wait(for: [refined], timeout: 60)
        // Let the cross-fade finish.
        Thread.sleep(forTimeInterval: 1)

        let after = olderBullets(app).map(\.frame).sorted { $0.minY < $1.minY }
        XCTAssertEqual(before.count, after.count, "Bullets came or went: \(before) → \(after)")
        for (old, new) in zip(before, after) {
            XCTAssertEqual(old.minY, new.minY, accuracy: 1, "A bullet moved: \(old) → \(new)")
            XCTAssertEqual(old.height, new.height, accuracy: 1, "A bullet changed height: \(old) → \(new)")
        }
        XCTAssertTrue(bullet("Japan Trip Itinerary", in: app).exists, "A provisional title wasn't refined")
        attachScreenshot(app, "Refined titles")

        app.buttons[Identifier.now].tap()
        XCTAssertTrue(currentBullet(app).waitForExistence(timeout: 5))
        XCTAssertEqual(currentBullet(app).label, "Beta Feedback", "The current topic wasn't refined")
    }

    /// VoiceOver reads the timeline as a list of topics, each titled, with
    /// when it started and how long it lasted.
    func testVoiceOverReadsTopicsWithTimes() throws {
        let app = launch()
        let current = currentBullet(app)
        XCTAssertEqual(current.label, "Draft 12")
        let currentValue = current.value as? String ?? ""
        XCTAssertTrue(currentValue.hasPrefix("Current topic, started "), currentValue)
        XCTAssertTrue(Self.containsTime(currentValue), currentValue)

        for bullet in olderBullets(app) {
            let value = bullet.value as? String ?? ""
            XCTAssertFalse(bullet.label.isEmpty, "A bullet without a title")
            XCTAssertTrue(Self.containsTime(value), "\(bullet.label): \(value)")
            XCTAssertTrue(value.contains("minutes"), "\(bullet.label): no duration in \(value)")
        }
        XCTAssertTrue(app.staticTexts["Today"].exists || app.staticTexts["Yesterday"].exists, "No day heading")

        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription]) { issue in
            // Only judge the timeline's own elements.
            guard let element = issue.element else { return true }
            return !element.identifier.hasPrefix("blau.timeline")
        }
    }

    func testTheTimelineAtTheLargestTextSize() {
        let app = launch(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let current = currentBullet(app)
        XCTAssertTrue(current.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(current.frame))
        attachScreenshot(app, "Timeline, accessibility XXXL")
    }

    /// "9:41 AM", "9:41 PM" or a 24-hour "21:41".
    private static func containsTime(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
