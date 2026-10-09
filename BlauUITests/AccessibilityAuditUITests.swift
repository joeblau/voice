import XCTest

/// The accessibility pass (#81, docs/accessibility.md): XCTest's
/// accessibility audit, the same checks as Accessibility Inspector's Audit
/// tab (contrast, element detection, hit regions, descriptions, Dynamic
/// Type, clipped text, traits), on every main surface, at the default text
/// size and at the largest accessibility size (AX5,
/// `UICTContentSizeCategoryAccessibilityXXXL`). Runs on fake services
/// (`BLAU_APP_ENVIRONMENT=ui-test`) with the canned topic history.
///
/// The surfaces: the empty main screen, the timeline, recording, the
/// history with the live caption, Settings, the speech-model setup card on
/// the main screen, and every onboarding page a fresh install goes through
/// (the speech models page included).
///
/// Every issue fails the test except these, each of which the audit can't
/// judge fairly:
///
/// - **No element, on the timeline.** The audit reports some issues
///   against nodes it can't resolve to an on-screen element (rows the lazy
///   stack built off screen, with no frame). They can't be located or
///   checked; `unattributed` logs how many. On screens without the lazy
///   timeline (onboarding, the setup card over the empty main screen) they
///   fail like any other issue.
/// - **Contrast under the bars.** Content scrolls under the Liquid Glass
///   bars, where the system's scroll edge effect fades it on purpose (the
///   fade reaches about 24 pt past each bar), and
///   under the controls floating above the bottom bar (the Now pill and the
///   live caption). Only elements wholly inside the area between them are
///   judged; the floating controls themselves are.
/// - **Contrast of disabled controls.** They are dimmed to show they're
///   inactive, which WCAG 1.4.3 exempts (Connect on the xAI page and Save
///   and Continue on About You, until there is text).
/// - **Dynamic Type of bar buttons.** Navigation and toolbar buttons are
///   system controls that cap their text size and show the large content
///   viewer instead (touch and hold).
/// - **"Partially unsupported" Dynamic Type of text in the timeline** (only
///   in the audits that use the main screen's content area). The
///   audit grows the text size and measures each element again, but the
///   timeline is a scroll view anchored to its latest line (or, reading
///   history, to the top), so growing everything moves the texts it
///   measures. It reports some of them as partially scaling: always plain
///   texts away from the anchor, never the ones beside it. They do scale:
///   `testTimelineTextScalesWithDynamicType` measures the same headings at
///   the default size and at AX5. Text that doesn't scale at all ("font
///   sizes are unsupported") still fails. Outside the timeline one text
///   is excused the same way, the Settings version footer at the bottom of
///   the sheet (moving it into a row didn't change the finding);
///   `testSettingsFooterScalesWithDynamicType` measures it instead.
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
        static let settingsVersion = "settings.version"
        static let modelSetup = "blau.models.setup"
        static let modelProgress = "blau.models.progress"
        static let modelStatus = "blau.models.status"
        static let modelAction = "blau.models.action"
    }

    /// Onboarding's identifiers (`OnboardingIdentifiers` in the app).
    enum Onboarding {
        static let back = "blau.onboarding.back"
        static let progress = "blau.onboarding.progress"
        static let primary = "blau.onboarding.primary"
        static let skip = "blau.onboarding.skip"
        static let xaiSkip = "xai.onboarding.skip"
        static func step(_ step: String) -> String { "blau.onboarding.step.\(step)" }
    }

    /// The fixture models' pace while a test looks at the setup card: 25
    /// chunks of 2 s, so the download takes minutes instead of a second.
    static let slowModelDownload = ["-BlauModelFixtureChunkDelay", "2000"]

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

    // MARK: Speech-model setup card

    /// The card the main screen shows while the speech models download, on
    /// every first launch.
    func testSpeechModelCard() throws {
        try auditSpeechModelCard(largestText: false)
    }

    func testSpeechModelCardAtTheLargestTextSize() throws {
        try auditSpeechModelCard(largestText: true)
    }

    private func auditSpeechModelCard(largestText: Bool) throws {
        let app = launch(Self.slowModelDownload, largestText: largestText, waitForModels: false)
        let card = app.descendants(matching: .any)[Identifier.modelSetup]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "No setup card")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelProgress].waitForExistence(timeout: 15),
            "Not downloading")
        waitUntilStill(card)
        try assertAuditPasses(
            app, "Speech model card",
            alsoJudged: [Identifier.modelStatus, Identifier.modelAction, Identifier.modelProgress],
            allowsUnattributed: false)
        XCTAssertTrue(card.exists, "The card went away during the audit")
    }

    // MARK: Onboarding

    func testOnboarding() throws {
        try auditOnboarding(largestText: false)
    }

    func testOnboardingAtTheLargestTextSize() throws {
        try auditOnboarding(largestText: true)
    }

    /// Every page a fresh install goes through, as `OnboardingUITests` does:
    /// skipping the key, allowing the (stub) microphone, and with the fixture
    /// models still downloading, so the speech models page and its setup
    /// card show.
    private func auditOnboarding(largestText: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchEnvironment["BLAU_UI_TEST_ONBOARDING"] = "fresh"
        app.launchEnvironment["BLAU_UI_TEST_MICROPHONE"] = "undetermined"
        app.launchEnvironment["BLAU_UI_TEST_XAI"] = "accept"
        app.launchArguments += Self.slowModelDownload
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()

        try auditOnboardingPage("welcome", app)
        tapOnboardingButton(Onboarding.primary, on: "welcome", app)

        try auditOnboardingPage("xaiAccount", app)
        let skipKey = app.buttons[Onboarding.xaiSkip]
        scrollTo(skipKey, in: app.descendants(matching: .any)[Onboarding.step("xaiAccount")])
        waitUntilStill(skipKey)
        try auditOnboardingPage("xaiAccount", app, context: "Onboarding xaiAccount, scrolled to Skip")
        skipKey.tap()

        try auditOnboardingPage("microphone", app)
        tapOnboardingButton(Onboarding.primary, on: "microphone", app)

        let models = try auditOnboardingPage("speechModels", app)
        XCTAssertTrue(
            models.descendants(matching: .any)[Identifier.modelProgress].exists, "The models aren't downloading")
        tapOnboardingButton(Onboarding.primary, on: "speechModels", app)

        try auditOnboardingPage("iCloud", app)
        tapOnboardingButton(Onboarding.primary, on: "iCloud", app)

        try auditOnboardingPage("voiceEnrollment", app)
        tapOnboardingButton(Onboarding.primary, on: "voiceEnrollment", app)

        try auditOnboardingPage("aboutYou", app)
        tapOnboardingButton(Onboarding.skip, on: "aboutYou", app)

        try auditOnboardingPage("ready", app)
    }

    /// Waits for onboarding's `step` page to settle, then audits it: the
    /// page between the top bar and its pinned buttons (content scrolls
    /// under the buttons' bar), plus the bar's own controls.
    @discardableResult
    private func auditOnboardingPage(_ step: String, _ app: XCUIApplication, context: String? = nil) throws
        -> XCUIElement
    {
        let page = app.descendants(matching: .any)[Onboarding.step(step)]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "The \(step) page didn't appear")
        waitUntilStill(page)
        let window = app.windows.firstMatch.frame
        let progress = app.descendants(matching: .any)[Onboarding.progress]
        let top = progress.exists ? progress.frame.maxY : page.frame.minY
        let primary = page.buttons[Onboarding.primary]
        let bottom = primary.exists ? primary.frame.minY - 12 : min(page.frame.maxY, window.maxY)
        let area = CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
        try assertAuditPasses(
            app, context ?? "Onboarding \(step)", contentArea: area,
            alsoJudged: [
                Onboarding.back, Onboarding.progress, Onboarding.primary, Onboarding.skip, Onboarding.xaiSkip,
                Identifier.modelStatus, Identifier.modelAction, Identifier.modelProgress,
            ],
            allowsUnattributed: false)
        return page
    }

    private func tapOnboardingButton(_ identifier: String, on step: String, _ app: XCUIApplication) {
        let button = app.descendants(matching: .any)[Onboarding.step(step)].buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No \(identifier) on \(step)")
        button.tap()
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

    /// The Settings version footer grows with Dynamic Type: at least twice
    /// as tall at AX5 as at the default size (its text about three times,
    /// the footer's insets not at all). The audit flags it as "partially
    /// unsupported" at the default size, the one excused text outside the
    /// timeline (see the class comment).
    func testSettingsFooterScalesWithDynamicType() throws {
        var small: CGFloat?
        for largestText in [false, true] {
            let app = launch(["-BlauTimelineFixture", "12"], largestText: largestText)
            app.buttons[Identifier.settings].tap()
            let list = app.collectionViews[Identifier.settingsList]
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            app.navigationBars["Settings"].swipeUp()
            waitUntilStill(list)
            let footer = app.staticTexts[Identifier.settingsVersion]
            scrollTo(footer, in: list)
            let frame = footer.frame
            if let small {
                XCTAssertGreaterThanOrEqual(frame.height, small * 2, "\(small) → \(frame.height)")
            } else {
                small = frame.height
            }
            app.terminate()
        }
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

    private func launch(_ arguments: [String] = [], largestText: Bool, waitForModels: Bool = true)
        -> XCUIApplication
    {
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
        // "download" after every launch; audit the screen without it (the
        // card has audits of its own).
        if waitForModels {
            XCTAssertTrue(
                app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 30),
                "The model setup card stayed")
        }
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
    ///
    /// - Parameters:
    ///   - contentArea: Where content isn't covered by bars, or `nil` for
    ///     the main screen's (`contentArea(_:)`). Only the main screen's
    ///     excuses the timeline's "partially unsupported" Dynamic Type.
    ///   - alsoJudged: Controls whose contrast is judged outside the content
    ///     area too (they float over it, or sit in a bar).
    ///   - allowsUnattributed: Whether issues with no element pass (only
    ///     the lazy timeline has them for a reason).
    private func assertAuditPasses(
        _ app: XCUIApplication, _ context: String, contentArea: CGRect? = nil, alsoJudged: Set<String> = [],
        allowsUnattributed: Bool = true, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let area = contentArea ?? Self.contentArea(app)
        let excusesTimelineScaling = contentArea == nil
        // The floating controls and the bottom bar's own buttons: content
        // under the bars is excused, the bars' controls are not.
        let floatingIdentifiers: Set<String> =
            alsoJudged.union([Identifier.now, Identifier.caption, Identifier.record, Identifier.settings])
        let navigationBars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let bars = navigationBars + app.toolbars.allElementsBoundByIndex.map(\.frame)
        var failures: [String] = []
        var unattributed = 0
        try app.performAccessibilityAudit(for: .all) { issue in
            guard let element = issue.element, element.exists, !element.frame.isEmpty else {
                unattributed += 1
                if !allowsUnattributed {
                    failures.append("\(issue.compactDescription) (no element): \(issue.detailedDescription)")
                }
                return true
            }
            let frame = element.frame
            if issue.auditType == .contrast, !area.insetBy(dx: -1, dy: -1).contains(frame),
                !floatingIdentifiers.contains(element.identifier)
            {
                return true
            }
            // WCAG 1.4.3 exempts inactive controls, which are dimmed on
            // purpose (Connect and Save and Continue until there's text).
            if issue.auditType == .contrast, !element.isEnabled {
                return true
            }
            if issue.auditType == .dynamicType || issue.auditType == .textClipped,
                element.elementType == .button, bars.contains(where: { $0.contains(frame) })
            {
                return true
            }
            if issue.auditType == .dynamicType, element.elementType == .staticText,
                issue.compactDescription.localizedCaseInsensitiveContains("partially"),
                (excusesTimelineScaling && Self.isInTimeline(element, app))
                    || element.identifier == Identifier.settingsVersion
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
