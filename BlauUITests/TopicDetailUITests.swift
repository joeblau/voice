import XCTest

/// The topic detail (#58) on the timeline's canned history
/// (`-BlauTimelineFixture <topics>`, fake services): tapping an older
/// bullet expands it inline to its summary, span, actions and transcript,
/// within 100 ms; Continue, Share, Rename and Split work from it.
@MainActor
final class TopicDetailUITests: XCTestCase {
    private enum Identifier {
        static let timeline = "blau.timeline"
        static let current = "blau.timeline.topic.current"
        static let topic = "blau.timeline.topic"
        static let summary = "blau.timeline.topic.summary"
        static let detail = "blau.timeline.topic.detail"
        static let span = "blau.timeline.topic.span"
        static let continueTopic = "blau.timeline.topic.continue"
        static let share = "blau.timeline.topic.share"
        static let more = "blau.timeline.topic.more"
        static let expandLatency = "blau.timeline.expandLatency"
        static let rename = "blau.topic.rename"
        static let split = "blau.topic.splitHere"
        static let user = "blau.chat.user"
        static let agent = "blau.chat.agent"
        static let record = "blau.record"
        static let modelSetup = "blau.models.setup"
    }

    private static let topicCount = 12
    /// The topic just above the current one, and two of its lines.
    private static let previousTitle = "Sourdough Starter"
    private static let previousTopicFirstLine = "How long would that take if I started tomorrow morning?"
    /// The issue's target for tap → expanded.
    private static let expandTarget = 100.0

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauTimelineFixture", "\(Self.topicCount)"]
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.timeline].waitForExistence(timeout: 30),
            "The timeline did not appear")
        XCTAssertTrue(app.buttons[Identifier.current].waitForExistence(timeout: 30), "No current topic")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 30),
            "The model setup card stayed")
        waitUntilStill(app.buttons[Identifier.current])
        return app
    }

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

    private func bullet(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: Identifier.topic).matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Expands the previous topic and waits for its detail.
    @discardableResult
    private func expandPrevious(_ app: XCUIApplication) -> XCUIElement {
        let previous = bullet(Self.previousTitle, in: app)
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        previous.tap()
        XCTAssertTrue(element(Identifier.detail, in: app).waitForExistence(timeout: 5), "No topic detail")
        return previous
    }

    /// The latency the app measured for the latest expansion, in ms.
    private func measuredLatency(_ app: XCUIApplication, after previous: String?)
        -> (value: String, milliseconds: Double)?
    {
        let probe = element(Identifier.expandLatency, in: app)
        guard probe.waitForExistence(timeout: 5) else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let value = probe.value as? String, value != previous,
                let milliseconds = value.split(separator: ":").last.flatMap({ Double($0) })
            {
                return (value, milliseconds)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    // MARK: Tests

    /// The detail opens under the bullet: summary, span, then the actions,
    /// then the transcript.
    func testTheDetailShowsTheSummarySpanAndActions() throws {
        let app = launch()
        let previous = expandPrevious(app)
        let summary = element(Identifier.summary, in: app)
        let span = element(Identifier.span, in: app)
        let continueButton = app.buttons[Identifier.continueTopic].firstMatch
        let share = app.buttons[Identifier.share].firstMatch
        let more = app.buttons[Identifier.more].firstMatch
        for (name, item) in [("summary", summary), ("span", span)] {
            XCTAssertTrue(item.exists, "No \(name)")
        }
        for (name, item) in [("Continue", continueButton), ("Share", share), ("More", more)] {
            XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(name)")
            XCTAssertTrue(item.isHittable, "\(name) isn't tappable")
            XCTAssertGreaterThan(item.frame.minY, summary.frame.minY, "\(name) is above the summary")
        }
        XCTAssertGreaterThan(summary.frame.minY, previous.frame.maxY - 1, "The summary is above its bullet")
        XCTAssertGreaterThan(span.frame.minY, summary.frame.minY)
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("Talked through sourdough starter"))
        // "9:41 AM – 9:49 AM · 8 min": a range and the duration.
        let spanText = span.label
        XCTAssertTrue(spanText.contains("8 minutes"), spanText)
        let firstLine = app.descendants(matching: .any).matching(identifier: Identifier.user)
            .matching(NSPredicate(format: "value == %@", Self.previousTopicFirstLine)).firstMatch
        XCTAssertTrue(firstLine.waitForExistence(timeout: 5), "The transcript isn't shown")
        XCTAssertGreaterThan(firstLine.frame.minY, continueButton.frame.maxY - 1, "A line above the actions")
        attachScreenshot(app, "Topic detail")

        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription]) { issue in
            guard let element = issue.element else { return true }
            return !element.identifier.hasPrefix("blau.timeline.topic")
        }
    }

    /// At large text sizes the same controls stack, stay on screen and
    /// remain tappable; the horizontal candidate must not clip a label.
    func testActionsStackAtTheLargestTextSize() {
        let app = launch(largestText: true)
        let previous = bullet(Self.previousTitle, in: app)
        let timeline = element(Identifier.timeline, in: app)
        for _ in 0..<8 where !previous.isHittable { timeline.swipeDown() }
        XCTAssertTrue(previous.isHittable, "The older bullet isn't reachable")
        expandPrevious(app)
        let controls = [
            app.buttons[Identifier.continueTopic].firstMatch,
            app.buttons[Identifier.share].firstMatch,
            app.buttons[Identifier.more].firstMatch,
        ]
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing action \(control)")
        }
        for _ in 0..<8 where !controls.allSatisfy(\.isHittable) { timeline.swipeUp() }
        let window = app.windows.firstMatch.frame
        for control in controls {
            XCTAssertTrue(control.isHittable, "An action isn't tappable at the largest text size")
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX - 1)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX + 1, "An action extends past the screen")
        }
        XCTAssertLessThanOrEqual(controls[0].frame.maxY, controls[1].frame.minY + 1, "Actions didn't stack")
        XCTAssertLessThanOrEqual(controls[1].frame.maxY, controls[2].frame.minY + 1, "Actions overlap")
        attachScreenshot(app, "Topic actions at the largest text size")
    }

    /// Tap → expanded under 100 ms (#58), as the app measured it
    /// (`TopicExpansionTimer`, the `timeline.expand` signpost), over
    /// several expansions.
    func testTappingExpandsWithinAHundredMilliseconds() {
        let app = launch()
        let previous = bullet(Self.previousTitle, in: app)
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        var samples: [Double] = []
        var last: String?
        for _ in 0..<5 {
            previous.tap()
            XCTAssertTrue(element(Identifier.detail, in: app).waitForExistence(timeout: 5), "Didn't expand")
            guard let sample = measuredLatency(app, after: last) else {
                XCTFail("No expansion latency was measured")
                return
            }
            samples.append(sample.milliseconds)
            last = sample.value
            previous.tap()
            XCTAssertTrue(element(Identifier.detail, in: app).waitForNonExistence(timeout: 5), "Didn't compress")
            waitUntilStill(previous, timeout: 5)
        }
        let report = samples.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")
        let attachment = XCTAttachment(string: "Tap → expanded: \(report)")
        attachment.name = "Expand latency"
        attachment.lifetime = .keepAlways
        add(attachment)
        for sample in samples {
            XCTAssertLessThan(sample, Self.expandTarget, "Expanding took \(sample) ms (\(report))")
        }
    }

    /// Continue starts a conversation that picks up the topic (the ui-test
    /// session listens at once).
    func testContinueStartsAConversation() {
        let app = launch()
        let record = app.buttons[Identifier.record]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        XCTAssertEqual(record.value as? String, "Not listening")
        expandPrevious(app)
        app.buttons[Identifier.continueTopic].firstMatch.tap()
        let listening = expectation(
            for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: record, handler: nil)
        wait(for: [listening], timeout: 10)
        XCTAssertEqual(record.label, "End Conversation")
        // Back at the latest line, where the conversation goes on.
        XCTAssertTrue(app.buttons[Identifier.current].isHittable)
        record.tap()
    }

    /// Share offers the topic as a Markdown file.
    func testShareOpensTheShareSheet() {
        let app = launch()
        expandPrevious(app)
        app.buttons[Identifier.share].firstMatch.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "No share sheet")
        attachScreenshot(app, "Share as Markdown")
        let close = sheet.buttons["Close"]
        if close.exists { close.tap() }
    }

    /// More → Rename… renames the topic in place.
    func testRenameFromTheDetail() {
        let app = launch()
        expandPrevious(app)
        app.buttons[Identifier.more].firstMatch.tap()
        let rename = app.buttons[Identifier.rename].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "No Rename in the menu")
        rename.tap()
        XCTAssertTrue(app.alerts["Rename Topic"].waitForExistence(timeout: 5), "No rename prompt")
        // An alert's text field doesn't carry its SwiftUI identifier.
        let field = app.alerts["Rename Topic"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No title field")
        // The alert focuses the field, its cursor after the prefilled title.
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            field.tap()
        }
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + "Bread Baking")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(bullet("Bread Baking", in: app).waitForExistence(timeout: 10), "The topic wasn't renamed")
    }

    /// Long-pressing a line (not the first) splits the topic there.
    func testSplitAtALine() {
        let app = launch()
        expandPrevious(app)
        let before = app.buttons.matching(identifier: Identifier.topic).count
        let lines = app.descendants(matching: .any).matching(identifier: Identifier.agent)
        let line = lines.element(boundBy: 0)
        XCTAssertTrue(line.waitForExistence(timeout: 5), "No line to split at")
        line.press(forDuration: 1.2)
        let split = app.buttons[Identifier.split].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5), "No Split Topic Here")
        split.tap()
        let more = NSPredicate(format: "count > %d", before)
        let added = expectation(
            for: more, evaluatedWith: app.buttons.matching(identifier: Identifier.topic), handler: nil)
        wait(for: [added], timeout: 10)
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
