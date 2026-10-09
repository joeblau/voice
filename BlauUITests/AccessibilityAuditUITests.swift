import XCTest

/// The accessibility pass (#81, docs/accessibility.md): XCTest's
/// accessibility audit, the same checks as Accessibility Inspector's Audit
/// tab (contrast, element detection, hit regions, descriptions, Dynamic
/// Type, clipped text, traits), on every main surface, at the default text
/// size and at the largest accessibility size (AX5,
/// `UICTContentSizeCategoryAccessibilityXXXL`). Runs on fake services
/// (`BLAU_APP_ENVIRONMENT=ui-test`) with the canned topic history.
///
/// Every issue fails the test except these, each of which the audit can't
/// judge fairly:
///
/// - **No element.** The audit reports some issues against nodes it can't
///   resolve to an on-screen element (rows the lazy stack built off screen,
///   with no frame). They can't be located or checked; `unattributed` logs
///   how many.
/// - **Contrast under the bars.** Content scrolls under the Liquid Glass
///   bars, where the system's scroll edge effect fades it on purpose (the
///   fade reaches about 24 pt past each bar), and
///   under the controls floating above the bottom bar (the Now pill and the
///   live caption). Only elements wholly inside the area between them are
///   judged; the floating controls themselves are.
/// - **Dynamic Type of bar buttons.** Navigation and toolbar buttons are
///   system controls that cap their text size and show the large content
///   viewer instead (touch and hold).
/// - **"Partially unsupported" Dynamic Type of text in the timeline.** The
///   audit grows the text size and measures each element again, but the
///   timeline is a scroll view anchored to its latest line (or, reading
///   history, to the top), so growing everything moves the texts it
///   measures. It reports some of them as partially scaling: always plain
///   texts away from the anchor, never the ones beside it. They do scale:
///   `testTimelineTextScalesWithDynamicType` measures the same headings at
///   the default size and at AX5. Text that doesn't scale at all ("font
///   sizes are unsupported") still fails.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    enum Identifier {
        static let content = "blau.root"
        static let timeline = "blau.timeline"
        static let current = "blau.timeline.topic.current"
        static let topic = "blau.timeline.topic"
        static let day = "blau.timeline.day"
        static let now = "blau.timeline.now"
        static let caption = "blau.caption"
        static let streaming = "blau.chat.agent.streaming"
        static let record = "blau.record"
        static let settings = "blau.settings.open"
        static let settingsList = "settings.list"
        static let modelSetup = "blau.models.setup"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Main screen

    func testEmptyMainScreen() throws {
        try auditEmptyMainScreen(largestText: false)
    }

    func testEmptyMainScreenAtTheLargestTextSize() throws {
        try auditEmptyMainScreen(largestText: true)
    }

    private func auditEmptyMainScreen(largestText: Bool) throws {
        let app = launch(largestText: largestText)
        XCTAssertTrue(app.descendants(matching: .any)["blau.mainScreen.empty"].exists)
        try assertAuditPasses(app, "Empty main screen")
    }

    // MARK: Timeline

    func testTimelineAtTheLatestLine() throws {
        try auditTimeline(largestText: false)
    }

    func testTimelineAtTheLatestLineAtTheLargestTextSize() throws {
        try auditTimeline(largestText: true)
    }

    private func auditTimeline(largestText: Bool) throws {
        let app = launch(["-BlauTimelineFixture", "12"], largestText: largestText)
        XCTAssertTrue(app.buttons[Identifier.current].waitForExistence(timeout: 30))
        try assertAuditPasses(app, "Timeline")
    }

    /// While a conversation runs: the record button's recording face and
    /// the current topic's recording state.
    func testRecording() throws {
        try auditRecording(largestText: false)
    }

    func testRecordingAtTheLargestTextSize() throws {
        try auditRecording(largestText: true)
    }

    private func auditRecording(largestText: Bool) throws {
        let app = launch(["-BlauTimelineFixture", "12"], largestText: largestText)
        let record = app.buttons[Identifier.record]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        waitFor(record, value: "Listening")
        try assertAuditPasses(app, "Recording")
    }

    /// Reading history while Grok speaks: an expanded older topic, the Now
    /// pill and the live caption.
    func testHistoryWithCaption() throws {
        try auditHistory(largestText: false)
    }

    func testHistoryWithCaptionAtTheLargestTextSize() throws {
        try auditHistory(largestText: true)
    }

    private func auditHistory(largestText: Bool) throws {
        let app = launch(["-BlauTimelineFixture", "12", "-BlauCaptionFixture", "1"], largestText: largestText)
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.streaming].waitForExistence(timeout: 15),
            "Grok isn't speaking")
        let now = app.buttons[Identifier.now]
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        func olderTopicOnScreen() -> XCUIElement? {
            let content = Self.contentArea(app)
            return app.buttons.matching(identifier: Identifier.topic).allElementsBoundByIndex.first { bullet in
                let frame = bullet.frame
                return frame.midY > content.minY && frame.minY < content.maxY - 20 && bullet.isHittable
            }
        }
        var older: XCUIElement?
        for _ in 0..<8 {
            if now.exists, let bullet = olderTopicOnScreen() {
                older = bullet
                break
            }
            timeline.swipeDown()
        }
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "History before expanding"
        add(before)
        XCTAssertTrue(now.waitForExistence(timeout: 5), "No Now pill in the history")
        try XCTUnwrap(older, "No older topic on screen").tap()
        waitUntilStill(now)
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.caption].exists, "No live caption")
        try assertAuditPasses(app, "History")
    }

    // MARK: Settings

    func testSettings() throws {
        try auditSettings(largestText: false)
    }

    func testSettingsAtTheLargestTextSize() throws {
        try auditSettings(largestText: true)
    }

    /// At the large detent: at the medium one the sheet is translucent
    /// glass over the timeline, which the contrast check can't separate
    /// from the text on it.
    private func auditSettings(largestText: Bool) throws {
        let app = launch(["-BlauTimelineFixture", "12"], largestText: largestText)
        let open = app.buttons[Identifier.settings]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let list = app.collectionViews[Identifier.settingsList]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Settings did not open")
        waitUntilStill(list)
        app.navigationBars["Settings"].swipeUp()
        waitUntilStill(list)
        let navigationBar = app.navigationBars["Settings"].frame
        let area = CGRect(
            x: list.frame.minX, y: navigationBar.maxY, width: list.frame.width,
            height: list.frame.maxY - navigationBar.maxY)
        try assertAuditPasses(app, "Settings", contentArea: area)
    }

    /// Text in the timeline grows with Dynamic Type: the day and
    /// conversation headings the audit flags are at least twice as tall at
    /// AX5 as at the default size, and no wider than the screen.
    func testTimelineTextScalesWithDynamicType() throws {
        let probes = ["Today", "Yesterday"]
        var heights: [String: CGFloat] = [:]
        for largestText in [false, true] {
            let app = launch(["-BlauTimelineFixture", "12"], largestText: largestText)
            let window = app.windows.firstMatch.frame
            for label in probes + ["conversation"] {
                let element =
                    label == "conversation"
                    ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Conversation ·'")).firstMatch
                    : app.staticTexts[label]
                findInTimeline(element, app)
                XCTAssertTrue(element.exists, "No \(label) in the timeline")
                let frame = element.frame
                XCTAssertLessThanOrEqual(frame.width, window.width, "\(label) is wider than the screen")
                if let small = heights[label] {
                    XCTAssertGreaterThanOrEqual(
                        frame.height, small * 2, "\(label) didn't grow with Dynamic Type: \(small) → \(frame.height)")
                } else {
                    heights[label] = frame.height
                }
            }
            app.terminate()
        }
    }

    // MARK: Support

    /// How far the bars' scroll edge effect fades content past them.
    static let scrollEdge: CGFloat = 24

    /// Scrolls the timeline into the history until `element` is built.
    private func findInTimeline(_ element: XCUIElement, _ app: XCUIApplication) {
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 12 {
            timeline.swipeDown()
            swipes += 1
        }
    }

    /// Whether `element` is inside the timeline's scroll view.
    private static func isInTimeline(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        let timeline = app.descendants(matching: .any)[Identifier.content]
        return timeline.exists && timeline.frame.intersects(element.frame)
            && app.descendants(matching: .any)[Identifier.timeline].exists
    }

    private func launch(_ arguments: [String] = [], largestText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += arguments
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.content].waitForExistence(timeout: 30),
            "The main screen did not appear")
        // The speech-model setup card shows while the fixture models
        // "download" after every launch; audit the screen without it.
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 30),
            "The model setup card stayed")
        waitUntilStill(app.buttons[Identifier.record])
        return app
    }

    /// The area content isn't covered in: below the top bar (or the status
    /// bar) and its scroll edge effect, above the bottom bar's buttons, their
    /// edge effect and the controls floating over the content (the live
    /// caption, the Now pill).
    static func contentArea(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let top = (navigationBar.exists ? navigationBar.frame.maxY : window.minY + 60) + scrollEdge
        var bottom = window.maxY - 100
        let settings = app.buttons[Identifier.settings]
        if settings.exists, !settings.frame.isEmpty {
            bottom = settings.frame.minY - scrollEdge
        }
        for identifier in [Identifier.now, Identifier.caption] {
            let element = app.descendants(matching: .any)[identifier]
            if element.exists, !element.frame.isEmpty {
                bottom = min(bottom, element.frame.minY - 8)
            }
        }
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    /// Runs the full audit and fails with every issue it finds, except the
    /// ones the class comment lists.
    private func assertAuditPasses(
        _ app: XCUIApplication, _ context: String, contentArea: CGRect? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let area = contentArea ?? Self.contentArea(app)
        let floatingIdentifiers: Set = [Identifier.now, Identifier.caption]
        let navigationBars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let bars = navigationBars + app.toolbars.allElementsBoundByIndex.map(\.frame)
        var failures: [String] = []
        var unattributed = 0
        try app.performAccessibilityAudit(for: .all) { issue in
            guard let element = issue.element, element.exists else {
                unattributed += 1
                return true
            }
            let frame = element.frame
            if frame.isEmpty {
                unattributed += 1
                return true
            }
            if issue.auditType == .contrast, !area.insetBy(dx: -1, dy: -1).contains(frame),
                !floatingIdentifiers.contains(element.identifier)
            {
                return true
            }
            if issue.auditType == .dynamicType || issue.auditType == .textClipped,
                element.elementType == .button, bars.contains(where: { $0.contains(frame) })
            {
                return true
            }
            if issue.auditType == .dynamicType, element.elementType == .staticText,
                issue.compactDescription.localizedCaseInsensitiveContains("partially"), Self.isInTimeline(element, app)
            {
                return true
            }
            failures.append(
                "\(issue.compactDescription): \(element.elementType.rawValue) "
                    + "\"\(element.label)\" (\(element.identifier)) at \(frame)")
            return true
        }
        print("AccessibilityAuditUITests: \(context): \(failures.count) issues, \(unattributed) unattributed")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = context
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(
            failures.isEmpty, "\(context): \(failures.count) audit issues:\n" + failures.joined(separator: "\n"),
            file: file, line: line)
    }

    private func waitFor(_ element: XCUIElement, value: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
            "Expected \(value), got \(String(describing: element.value))", file: file, line: line)
    }

    /// Waits until `element` stops moving, so the audit doesn't catch an
    /// animation halfway.
    private func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.exists ? element.frame : .zero
        var stillSince = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let frame = element.exists ? element.frame : .zero
            if frame != last {
                last = frame
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 1 {
                return
            }
        }
    }
}

/// Live captions (#81): Grok's words stay on screen while its row in the
/// transcript is out of view. `-BlauCaptionFixture 1` has Grok "speaking"
/// in the latest conversation of the canned history.
@MainActor
final class LiveCaptionUITests: XCTestCase {
    private typealias Identifier = AccessibilityAuditUITests.Identifier

    private static let replyEnd = "what would make them stop using it?"

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauTimelineFixture", "12", "-BlauCaptionFixture", "1"]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons[Identifier.current].waitForExistence(timeout: 30), "No current topic")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 30),
            "The model setup card stayed")
        return app
    }

    private func scrollIntoHistory(_ app: XCUIApplication) {
        let now = app.buttons[Identifier.now]
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        var swipes = 0
        while !now.exists && swipes < 4 {
            timeline.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(now.waitForExistence(timeout: 5), "No Now pill in the history")
    }

    /// At the latest line Grok's words are the streaming row; scrolled into
    /// the history they are a caption above Now that VoiceOver reads as
    /// Grok's. It doesn't stop the history scrolling, and Now takes it away.
    func testCaptionKeepsGroksWordsOnScreenWhileReadingHistory() {
        let app = launch()
        let caption = app.descendants(matching: .any)[Identifier.caption]
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.streaming].waitForExistence(timeout: 15),
            "Grok's reply isn't in the transcript")
        XCTAssertFalse(caption.exists, "A caption at the latest line, where the row is in view")

        scrollIntoHistory(app)
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "No caption while reading history")
        XCTAssertEqual(caption.label, "Grok")
        let value = caption.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix(Self.replyEnd), "The caption isn't the reply's latest words: \(value)")
        XCTAssertTrue(value.hasPrefix("\u{2026}"), "A long reply's caption starts with an ellipsis: \(value)")
        let now = app.buttons[Identifier.now]
        XCTAssertLessThanOrEqual(caption.frame.maxY, now.frame.minY + 1, "The caption isn't above Now")
        attach(app, "Caption while reading history")

        // A swipe that starts on the caption still scrolls the history.
        let day = app.descendants(matching: .any).matching(identifier: Identifier.day).firstMatch
        XCTAssertTrue(day.exists, "No day heading built")
        let before = day.frame.minY
        // Upward, toward the latest line: the history may already be at its
        // top.
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            .press(forDuration: 0.05, thenDragTo: caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        XCTAssertLessThan(day.frame.minY, before - 20, "The caption blocked scrolling")

        if now.exists {
            now.tap()
        }
        XCTAssertTrue(caption.waitForNonExistence(timeout: 5), "The caption stayed at the latest line")
        XCTAssertTrue(now.waitForNonExistence(timeout: 5), "Not back at the latest line")
    }

    /// At AX5 the caption shows fewer words, wrapped rather than clipped,
    /// and stays on screen with the Now pill.
    func testCaptionAtTheLargestTextSize() {
        let app = launch(largestText: true)
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.streaming].waitForExistence(timeout: 15),
            "Grok isn't speaking")
        scrollIntoHistory(app)
        let caption = app.descendants(matching: .any)[Identifier.caption]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "No caption while reading history")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(caption.frame), "The caption runs off screen: \(caption.frame)")
        XCTAssertTrue(app.buttons[Identifier.now].isHittable, "The caption covers Now")
        let value = caption.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix(Self.replyEnd), value)
        XCTAssertLessThanOrEqual(value.count, 60, "Too many words for the largest size: \(value)")
        attach(app, "Caption, accessibility XXXL")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
