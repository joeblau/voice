import XCTest

/// The scripted five-minute session (#73): the real pipeline from the
/// capture hub to the stored transcript, fed the script's microphone audio
/// and answered by a scripted realtime server, in the app (`PerfReplay`,
/// docs/performance.md#performance-suite).
///
/// Measures the app's CPU and memory over a whole session, and the
/// canonical pipeline intervals with `XCTOSSignpostMetric`. Run with
/// `make perf` (a Release build with the `BLAU_PERF` condition, which
/// compiles the replay in); `make perf-check` then compares the results with
/// the committed baselines.
///
/// Test-runner environment (on the xcodebuild command line, prefix each
/// with `TEST_RUNNER_`, e.g. `TEST_RUNNER_BLAU_PERF_ITERATIONS=3 make perf`):
///
/// - `BLAU_PERF_ITERATIONS`: measured replays (default 5).
/// - `BLAU_PERF_REPLAY_SECONDS`: the session's spoken length (default 300).
/// - `BLAU_PERF_REPLAY_SPEED`: a factor, `realtime` or `max` (default 10).
/// - `BLAU_PERF_REPLAY_ASR`: `scripted` (default, hermetic) or `parakeet`
///   (the installed models, on a device; adds `asr.chunk`).
@MainActor
final class ReplaySessionPerformanceTests: XCTestCase {
    static let subsystem = "com.joeblau.blau"

    /// The intervals measured in every run, as `(category, name)`
    /// (docs/performance.md#canonical-intervals).
    static let intervals: [(category: String, name: String)] = [
        ("voiceid", "voiceid.verify"),
        ("topics", "topics.segment"),
        ("memory", "memory.search"),
        ("data", "db.save"),
    ]

    /// Only emitted when the replay transcribes with Parakeet.
    static let modelIntervals: [(category: String, name: String)] = [("asr", "asr.chunk")]

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static var usesParakeet: Bool { environment["BLAU_PERF_REPLAY_ASR"] == "parakeet" }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testScriptedSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_PERF_REPLAY"] = "1"
        // Fixture speech models: launching never starts a real download.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        if !Self.usesParakeet {
            // Fakes for every app service the replay doesn't use (no
            // Keychain, no iCloud, no audio session): the replay builds its
            // own pipeline, so only it shows up in the measurements.
            app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        }
        for key in ["BLAU_PERF_REPLAY_SECONDS", "BLAU_PERF_REPLAY_SPEED", "BLAU_PERF_REPLAY_ASR"] {
            app.launchEnvironment[key] = Self.environment[key]
        }
        app.launch()

        let start = app.buttons["blau.perf.replay.start"]
        guard start.waitForExistence(timeout: 60) else {
            throw XCTSkip(
                "The replay isn't compiled into this build. Run `make perf`, which builds with the BLAU_PERF condition."
            )
        }
        let status = app.staticTexts["blau.perf.replay.status"]
        var run = 0
        func replay() {
            run += 1
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            XCTAssertTrue(start.isEnabled, "A replay is still running")
            start.tap()
            let ended = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label == %@ OR label BEGINSWITH %@", "finished \(run)", "failed \(run)"),
                object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 900), .completed, "Replay \(run) never ended")
            XCTAssertEqual(status.label, "finished \(run)")
        }

        // One replay before measuring, so first-use costs (store creation,
        // SQLite, Swift metadata) stay out of the numbers.
        replay()
        let summary = XCTAttachment(string: app.staticTexts["blau.perf.replay.summary"].label)
        summary.name = "Replay summary"
        summary.lifetime = .keepAlways
        add(summary)

        let options = XCTMeasureOptions()
        options.iterationCount = Int(Self.environment["BLAU_PERF_ITERATIONS"] ?? "") ?? 5
        measure(metrics: Self.metrics(for: app), options: options) {
            replay()
        }
    }

    static func metrics(for app: XCUIApplication) -> [any XCTMetric] {
        let intervals = Self.intervals + (usesParakeet ? Self.modelIntervals : [])
        return intervals.map { XCTOSSignpostMetric(subsystem: subsystem, category: $0.category, name: $0.name) } + [
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app),
            XCTClockMetric(),
        ]
    }
}
