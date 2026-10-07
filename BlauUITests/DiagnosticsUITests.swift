import XCTest

/// The Developer diagnostics screen: open it, fill it with sample payloads
/// (Debug builds; the Simulator never receives MetricKit payloads) and export
/// through the share sheet.
@MainActor
final class DiagnosticsUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSamplePayloadsShowUpAndExportOpensTheShareSheet() throws {
        let app = XCUIApplication()
        app.launch()

        let root = app.descendants(matching: .any)["blau.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        root.press(forDuration: 1.2)

        let screen = app.descendants(matching: .any)["diagnostics.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "Diagnostics screen did not open")

        let addSamples = app.buttons["diagnostics.addSamples"]
        scrollTo(addSamples, in: screen)
        addSamples.tap()

        let hangReports = app.descendants(matching: .any)["diagnostics.hangReports"]
        XCTAssertTrue(hangReports.waitForExistence(timeout: 5), "Overview did not show hang reports")

        let export = app.buttons["diagnostics.export"]
        scrollTo(export, in: screen)
        export.tap()

        // The share sheet is a system view; its activity list or the Copy
        // action is enough to know it opened with our file.
        let shareSheet = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copy"]
        let opened = shareSheet.waitForExistence(timeout: 10) || copy.waitForExistence(timeout: 2)
        XCTAssertTrue(opened, "Share sheet did not open")
    }

    private func scrollTo(_ element: XCUIElement, in container: XCUIElement) {
        var attempts = 0
        while !(element.exists && element.isHittable) && attempts < 8 {
            container.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "\(element) not found")
    }
}
