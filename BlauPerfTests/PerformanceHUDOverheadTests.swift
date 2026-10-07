import XCTest

/// The performance HUD's own cost (#71): the app's CPU time over 10 s idle
/// spans with the HUD hidden and with it shown (`XCTCPUMetric`, five each). The
/// difference between the two "CPU Time" averages, divided by 10 s, is the
/// HUD's share of one core; the budget is under 1%. It covers everything
/// the HUD adds to the app process (display link, 1 Hz sampling, signpost
/// tap, SwiftUI updates of the panel); the render server's compositing is
/// outside the app.
///
/// XCTest only reports a metric's values to the log and the result bundle,
/// not to the test, so the two runs are compared from the output:
///
/// ```sh
/// make perf DESTINATION='id=<udid>' 2>&1 | grep "IdleCPUWithTheHUD.*measured \[CPU Time"
/// ```
///
/// Run through the `Blau-Perf` scheme (Release). The app runs on fake
/// services (`BLAU_APP_ENVIRONMENT=ui-test`), so nothing else (no model
/// download, no microphone) runs in either phase. Simulator numbers are a
/// smoke check; the device numbers go in docs/performance.md.
@MainActor
final class PerformanceHUDOverheadTests: XCTestCase {
    /// How long each measured idle span lasts.
    static let idleSeconds: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(hudShown: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += ["-blau.featureFlag.perfHUD", hudShown ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        let hud = app.descendants(matching: .any)["blau.hud"]
        if hudShown {
            XCTAssertTrue(hud.waitForExistence(timeout: 10), "The HUD did not appear")
        } else {
            XCTAssertFalse(hud.exists)
        }
        // Let launch work (store setup, fixture checks) finish first.
        Thread.sleep(forTimeInterval: 5)
        return app
    }

    private func measureIdleCPU(hudShown: Bool) {
        let app = launch(hudShown: hudShown)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: Self.idleSeconds)
        }
        app.terminate()
    }

    func testIdleCPUWithTheHUDHidden() {
        measureIdleCPU(hudShown: false)
    }

    func testIdleCPUWithTheHUDShown() {
        measureIdleCPU(hudShown: true)
    }
}
