import XCTest

/// Paging the timeline's history (#57) on a 2,000-topic history
/// (`-BlauTimelineHistory 2000`, fake services): conversations of five
/// topics, two a day, titled "<title> <n>" with n counting from the oldest.
///
/// Scrolls from the current topic to the very first topic with slow, held
/// drags, so each drag must move the content by the finger's travel (give
/// or take the pan's slop and a small fling). A page of history landing
/// above the screen without the scroll view keeping its position
/// (FB24968838) moves the rows on screen by the page's height, thousands
/// of points, and the lazy stack measuring the page's rows moves them by
/// hundreds; the drag check catches both. Run it on an iOS 26 and an iOS
/// 27 simulator (docs/timeline.md).
@MainActor
final class TopicTimelinePagingUITests: XCTestCase {
    private enum Identifier {
        static let timeline = "blau.timeline"
        static let current = "blau.timeline.topic.current"
        static let topic = "blau.timeline.topic"
        static let now = "blau.timeline.now"
        static let hud = "blau.hud"
        static let modelSetup = "blau.models.setup"
    }

    private static let topicCount = 2_000
    /// The oldest topic's title (`TopicTimelineFixture.historyTitle(for: 0)`).
    private static let oldestTitle = "Seed Round Planning 1"
    /// How far the timeline may grow the app's footprint while it pages in
    /// the whole history. 2,000 compressed bullets are a few megabytes of
    /// values; anything near this means rows or transcripts are kept.
    private static let memoryBudgetMB = 60.0

    override func setUp() async throws {
        // About 25 minutes for both tests: longer than CI's app-tests job
        // allows. `TEST_RUNNER_BLAU_LONG_UI_TESTS=1 xcodebuild test …` (or
        // the scheme's environment) runs them.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BLAU_LONG_UI_TESTS"] == "1",
            "Set BLAU_LONG_UI_TESTS=1 to scroll through 2,000 topics")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += [
            "-BlauTimelineHistory", "\(Self.topicCount)",
            // The HUD's Memory row reports the app's footprint.
            "-blau.featureFlag.perfHUD", "YES",
        ]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.timeline].waitForExistence(timeout: 60),
            "The timeline did not appear")
        XCTAssertTrue(app.buttons[Identifier.current].waitForExistence(timeout: 60), "No current topic")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.modelSetup].waitForNonExistence(timeout: 60),
            "The model setup card stayed")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        return app
    }

    /// A bullet on screen in one snapshot of the app.
    private struct Bullet {
        let title: String
        let frame: CGRect
    }

    /// The topic bullets laid out in `area`, top to bottom, from a single
    /// snapshot (one round trip, however many bullets are built).
    private func bullets(in app: XCUIApplication, area: CGRect) throws -> [Bullet] {
        var found: [Bullet] = []
        func visit(_ element: XCUIElementSnapshot) {
            if element.identifier == Identifier.topic, area.contains(element.frame) {
                found.append(Bullet(title: element.label, frame: element.frame))
            }
            for child in element.children {
                visit(child)
            }
        }
        visit(try app.snapshot())
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// How much less than the finger's travel a drag may move the rows: the
    /// pan's slop before it starts scrolling.
    private static let slop: CGFloat = 40
    /// How much more: the little fling a synthesized drag sometimes ends
    /// with. A page landing without its offset moves the rows by the page,
    /// thousands of points.
    private static let fling: CGFloat = 250

    /// Waits for the scroll to stop, then returns the bullets on screen and
    /// the one titled `title`, if it is among them.
    private func settled(
        _ title: String, in app: XCUIApplication, area: CGRect
    ) throws -> (bullets: [Bullet], bullet: Bullet?) {
        var last = try bullets(in: app, area: area)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = try bullets(in: app, area: area)
            let frame = now.first { $0.title == title }?.frame
            if frame == last.first(where: { $0.title == title })?.frame {
                return (now, now.first { $0.title == title })
            }
            last = now
        }
        return (last, last.first { $0.title == title })
    }

    /// The app's physical footprint from the HUD's Memory row ("Memory",
    /// "123 MB · 2.1 GB free"), in MB.
    private func footprintMB(_ app: XCUIApplication) throws -> Double? {
        let hud = app.descendants(matching: .any)[Identifier.hud]
        guard hud.waitForExistence(timeout: 10) else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // The row's texts, in order: the first size after "Memory".
            var texts: [String] = []
            func visit(_ element: XCUIElementSnapshot) {
                texts.append(element.label)
                if let value = element.value as? String { texts.append(value) }
                for child in element.children {
                    visit(child)
                }
            }
            visit(try hud.snapshot())
            let joined = texts.joined(separator: " ")
            if let memory = joined.range(of: "Memory"),
                let match = joined[memory.upperBound...].range(of: #"[\d.]+ (MB|GB)"#, options: .regularExpression)
            {
                let parts = joined[match].split(separator: " ")
                if let value = Double(parts[0]) {
                    return parts[1] == "GB" ? value * 1_024 : value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    /// Scrolls from the current topic to the oldest of 2,000 with held
    /// drags: every drag moves the rows by the finger's travel (no jump
    /// when a page lands), the whole history loads, and the footprint stays
    /// within budget.
    func testScrollingThroughTwoThousandTopicsWithoutJumps() throws {
        let app = launch()
        let window = app.windows.firstMatch.frame
        let startMB = try footprintMB(app)

        // Drag where the HUD isn't.
        let hud = app.descendants(matching: .any)[Identifier.hud].frame
        let x = hud.isEmpty || hud.minX > window.midX ? 0.25 : 0.75
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.7))
        let travel = window.height * 0.4
        // Where bullets are read: below the status bar, above the bottom bar.
        let readable = CGRect(x: window.minX, y: window.minY + 60, width: window.width, height: window.height - 180)

        var drags = 0
        var shifts: [CGFloat] = []
        var titlesSeen = Set<String>()
        var oldestReached = false
        while !oldestReached {
            let before = try bullets(in: app, area: readable)
            titlesSeen.formUnion(before.map(\.title))
            if before.contains(where: { $0.title == Self.oldestTitle }) {
                oldestReached = true
                break
            }
            // The topmost bullet stays on screen after the drag moves it down.
            let reference = try XCTUnwrap(
                before.first { $0.frame.maxY + travel + Self.fling < window.maxY },
                "No bullet to follow after \(drags) drags")

            // A slow drag held at the end. A synthesized drag still flings
            // a little now and then (up to ~150 pt), so the content moves by
            // the finger's travel less the pan's slop, plus at most that.
            from.press(
                forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 500),
                thenHoldForDuration: 0.5)
            drags += 1

            let (after, moved) = try settled(reference.title, in: app, area: window)
            guard let moved else {
                let onScreen = after.map { "\($0.title) @\(Int($0.frame.minY))" }.prefix(4).joined(separator: ", ")
                XCTFail(
                    "Drag \(drags): \(reference.title) @\(Int(reference.frame.minY)) left the screen "
                        + "(it should have moved \(Int(travel)) pt); on screen now: \(onScreen)")
                return
            }
            let shift = moved.frame.minY - reference.frame.minY
            if after.contains(where: { $0.title == Self.oldestTitle }) {
                // The top of the whole history: the drag ran out of content
                // and bounced back, so the rows moved less than the finger.
                XCTAssert(
                    (0...travel + Self.fling).contains(shift),
                    "Drag \(drags): \(reference.title) moved \(Int(shift)) pt at the top of the history")
                titlesSeen.formUnion(after.map(\.title))
                oldestReached = true
                break
            }
            shifts.append(shift)
            XCTAssert(
                (travel - Self.slop...travel + Self.fling).contains(shift),
                "Drag \(drags): \(reference.title) moved \(Int(shift)) pt for \(Int(travel)) pt of finger travel")
            XCTAssertLessThan(drags, 600, "Too many drags to reach the oldest topic")
            if drags >= 600 { return }
        }
        XCTAssertTrue(oldestReached, "Never reached \(Self.oldestTitle)")
        XCTAssertGreaterThan(titlesSeen.count, Self.topicCount / 2, "Scrolled past most bullets unseen")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "The oldest topic after \(drags) drags"
        attachment.lifetime = .keepAlways
        add(attachment)

        var report =
            "\(drags) drags of \(Int(travel)) pt; the rows moved "
            + "\(Int(shifts.min() ?? 0))–\(Int(shifts.max() ?? 0)) pt; \(titlesSeen.count) bullets seen"
        if let startMB, let endMB = try footprintMB(app) {
            let growth = endMB - startMB
            report += "; footprint \(Int(startMB)) MB → \(Int(endMB)) MB"
            XCTAssertLessThan(growth, Self.memoryBudgetMB, "The footprint grew \(Int(growth)) MB")
        } else {
            XCTFail("The HUD didn't report the footprint")
        }
        let summary = XCTAttachment(string: report)
        summary.name = "Paging summary"
        summary.lifetime = .keepAlways
        add(summary)
        print("TopicTimelinePaging: \(report)")
    }

    /// Flinging up through 2,000 topics reaches the oldest one (each fling
    /// that reaches the top of what's loaded comes to rest there and the
    /// next page lands), and one tap on Now goes all the way back to the
    /// current topic's latest line.
    func testNowReturnsFromTheOldestTopic() throws {
        let app = launch()
        let timeline = app.descendants(matching: .any)[Identifier.timeline]
        let oldest = app.buttons.matching(identifier: Identifier.topic)
            .matching(NSPredicate(format: "label == %@", Self.oldestTitle)).firstMatch
        var flings = 0
        while !(oldest.exists && oldest.isHittable) && flings < 200 {
            timeline.swipeDown(velocity: .fast)
            flings += 1
        }
        XCTAssertTrue(oldest.isHittable, "Never reached \(Self.oldestTitle) in \(flings) flings")

        let now = app.buttons[Identifier.now]
        XCTAssertTrue(now.waitForExistence(timeout: 5))
        now.tap()
        XCTAssertTrue(now.waitForNonExistence(timeout: 10), "Now didn't return to the latest line")
        XCTAssertTrue(app.buttons[Identifier.current].isHittable, "The current topic isn't on screen")
    }
}
