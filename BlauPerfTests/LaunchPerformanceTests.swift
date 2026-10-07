import XCTest

/// Launch-time performance. Run through the `Blau-Perf` scheme (Release
/// configuration) with `make perf`. Simulator numbers are only useful as a
/// smoke check; meaningful baselines come from a physical device.
@MainActor
final class LaunchPerformanceTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// The app under test, with fixture speech models so launches never
    /// start a real model download.
    private static func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_MODEL_FIXTURES"] = "1"
        return app
    }

    func testColdLaunch() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            Self.app().launch()
        }
    }

    func testLaunchUntilResponsive() throws {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            Self.app().launch()
        }
    }
}
