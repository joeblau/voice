import XCTest

/// Scrolling a 1,000-row conversation (#42): hitches and scroll frame rate
/// while flinging through the history and back. Runs on fake services with
/// a canned conversation (`-BlauChatFixture 1000`) through the `Blau-Perf`
/// scheme (Release): `make perf`.
///
/// The acceptance bar is no hitches at 120 Hz, which only a ProMotion
/// iPhone can show: on the simulator the numbers are a smoke check that the
/// metrics are collected and nothing regresses badly. Record device
/// baselines in Xcode's test report (docs/performance.md).
@MainActor
final class ChatTranscriptScrollPerformanceTests: XCTestCase {
    static let rows = 1_000

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-BlauChatFixture", "\(Self.rows)"]
        app.launch()
        let transcript = app.descendants(matching: .any)["blau.timeline"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 60), "The transcript did not appear")
        // The fixture's rows are on screen.
        XCTAssertTrue(
            app.descendants(matching: .any)["blau.chat.agent"].firstMatch.waitForExistence(timeout: 30),
            "The fixture wasn't seeded")
        return app
    }

    /// Flings up through the history, then back down, measuring hitches
    /// (`XCTHitchMetric`) and the scroll's frame rate and hitch ratio
    /// (`XCTOSSignpostMetric.scrollingAndDecelerationMetric`).
    func testScrollingAThousandRows() throws {
        let app = launch()
        let content = app.descendants(matching: .any)["blau.root"]
        XCTAssertTrue(content.waitForExistence(timeout: 10))

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(
            metrics: [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric],
            options: options
        ) {
            for _ in 0..<3 {
                content.swipeDown(velocity: .fast)
            }
            for _ in 0..<3 {
                content.swipeUp(velocity: .fast)
            }
            stopMeasuring()
        }
    }
}
