import XCTest

/// The automated long-session soak test (#76): one or two hours of the
/// voice loop's real pipeline in the app (`SoakRun`), fed mixed audio (the
/// user's lines, TV dialogue, silence) through the capture hub and answered
/// by a local fake realtime server, then judged on memory growth, latency
/// drift, dropped frames, session renewal and topic count
/// (docs/soak.md).
///
/// Run with `make soak`: a Release build with the `BLAU_PERF` condition
/// (which compiles the soak in) and the `BlauSoak` test plan, which sets
/// `BLAU_SOAK=1`. In any other plan the test skips; the `BlauPerf` plan
/// leaves it out altogether.
///
/// Test-runner environment (prefix each with `TEST_RUNNER_` on the
/// xcodebuild command line; `make soak` maps `SOAK_MINUTES` and friends):
///
/// - `BLAU_SOAK_MINUTES`: the session's length on the audio timeline
///   (default 120).
/// - `BLAU_SOAK_SPEED`: a factor, `realtime` or `max` (default 10).
/// - `BLAU_SOAK_ASR`: `scripted` (default, hermetic) or `parakeet` (the
///   installed models, on a device).
/// - `BLAU_SOAK_ROLLOVER_MINUTES`: where the session renewal lands (default
///   60% of the session), or `xai` for xAI's real 110 minutes.
/// - `BLAU_SOAK_SAMPLE_SECONDS`: audio between samples.
/// - `BLAU_SOAK_HOLD_SECONDS`: how long to keep the app open after the
///   run, idle, so `scripts/soak/soak.sh` can take its last leaks reading
///   (default 0).
@MainActor
final class SoakTests: XCTestCase {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static let forwardedKeys = [
        "BLAU_SOAK_MINUTES", "BLAU_SOAK_SPEED", "BLAU_SOAK_ASR", "BLAU_SOAK_ROLLOVER_MINUTES",
        "BLAU_SOAK_SAMPLE_SECONDS",
    ]

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLongSession() throws {
        let environment = Self.environment
        guard environment["BLAU_SOAK"] == "1" else {
            throw XCTSkip("The soak test runs for an hour or two. Run it with `make soak` (the BlauSoak test plan).")
        }
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_SOAK"] = "1"
        // Fixture speech models: launching never starts a real download.
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        if environment["BLAU_SOAK_ASR"] != "parakeet" {
            // Fakes for every app service the soak doesn't use (no Keychain,
            // no iCloud, no audio session): only the soak's pipeline runs.
            app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        }
        for key in Self.forwardedKeys {
            app.launchEnvironment[key] = environment[key]
        }
        app.launch()

        let start = app.buttons["blau.soak.start"]
        guard start.waitForExistence(timeout: 60) else {
            throw XCTSkip(
                "The soak isn't compiled into this build. Run `make soak`, which builds with the BLAU_PERF condition.")
        }
        start.tap()

        let status = app.staticTexts["blau.soak.status"]
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@ AND label != %@", "running", "idle"), object: status)
        let timeout = Self.timeout(environment)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ended], timeout: timeout), .completed,
            "The soak didn't end within \(Int(timeout / 60)) minutes")

        let report = app.staticTexts["blau.soak.report"]
        if report.waitForExistence(timeout: 10) {
            add(Self.attachment(report.value as? String ?? "", name: "Soak report (JSON)", type: "public.json"))
            let markdown = app.staticTexts["blau.soak.markdown"]
            add(
                Self.attachment(
                    markdown.value as? String ?? "", name: "Soak report (Markdown)", type: "net.daringfireball.markdown"
                ))
            add(Self.attachment(report.label, name: "Soak summary", type: "public.plain-text"))
        }

        let hold = Double(environment["BLAU_SOAK_HOLD_SECONDS"] ?? "") ?? 0
        if hold > 0 {
            // The app sits idle with the run torn down: whatever is still
            // allocated now is kept for good.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "hold")], timeout: hold)
        }
        XCTAssertEqual(status.label, "passed", "The soak failed; see the attached report")
    }

    /// Three times the run's expected wall time, plus ten minutes.
    static func timeout(_ environment: [String: String]) -> TimeInterval {
        let minutes = Double(environment["BLAU_SOAK_MINUTES"] ?? "") ?? 120
        let speed: Double =
            switch environment["BLAU_SOAK_SPEED"] {
            case "realtime": 1
            case "max": 10
            case let value?: Double(value) ?? 10
            case nil: 10
            }
        return minutes * 60 / max(speed, 0.1) * 3 + 600
    }

    static func attachment(_ text: String, name: String, type: String) -> XCTAttachment {
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
