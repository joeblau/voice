import XCTest

/// Launch-time performance. Run through the `Blau-Perf` scheme (Release
/// configuration) with `make perf`. Simulator numbers are only useful as a
/// smoke check; meaningful baselines come from a physical device.
@MainActor
final class LaunchPerformanceTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testColdLaunch() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    func testLaunchUntilResponsive() throws {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            XCUIApplication().launch()
        }
    }
}
