import XCTest

/// The debug performance HUD (#71): turning it on from Settings → Developer
/// and with the DEBUG triple-tap, expanding it, dragging it, and its live
/// device values. Launches on fake services (`BLAU_APP_ENVIRONMENT=ui-test`),
/// whose HUD preferences and flags live in memory, so every launch starts
/// with the HUD hidden.
@MainActor
final class PerformanceHUDUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func hud(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["blau.hud"]
    }

    /// The row whose label starts with `label` (rows combine label and value).
    private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        hud(app).descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    func testSettingsDeveloperTogglesTheHUD() {
        let app = launch()
        XCTAssertFalse(hud(app).exists, "The HUD starts hidden")

        app.buttons["blau.settings.open"].tap()
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Settings did not open")
        let toggle = app.switches["settings.developer.performanceHUD"]
        scrollTo(toggle, in: form)
        XCTAssertEqual(toggle.value as? String, "0")
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
        XCTAssertEqual(toggle.value as? String, "1")

        XCTAssertTrue(hud(app).waitForExistence(timeout: 5), "The HUD did not appear")
        app.buttons["Done"].tap()
        XCTAssertTrue(hud(app).waitForExistence(timeout: 5), "The HUD should stay over the main screen")
    }

    func testTheHUDShowsLiveDeviceValuesAndExpands() {
        let app = launch(arguments: ["-blau.featureFlag.perfHUD", "YES"])
        let panel = hud(app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The perfHUD flag should show the HUD")

        // The display link and the sampler fill the device rows within a
        // second or two.
        let fps = row(app, "FPS")
        XCTAssertTrue(fps.waitForExistence(timeout: 5))
        let filled = NSPredicate(format: "NOT (label CONTAINS %@)", "–")
        expectation(for: filled, evaluatedWith: fps)
        expectation(for: filled, evaluatedWith: row(app, "CPU"))
        expectation(for: filled, evaluatedWith: row(app, "Memory"))
        expectation(for: filled, evaluatedWith: row(app, "Thermal"))
        waitForExpectations(timeout: 10)

        // Tap: every section.
        let expanded = app.descendants(matching: .any)["blau.hud.expanded"]
        XCTAssertFalse(expanded.exists)
        panel.tap()
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "Tapping should expand the HUD")
        XCTAssertTrue(row(app, "HUD cost").waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "EOU → audio").exists)
        XCTAssertTrue(row(app, "Turn").exists)
        panel.tap()
        XCTAssertFalse(expanded.waitForExistence(timeout: 2), "Tapping again should collapse it")
    }

    func testTheHUDCanBeDragged() {
        let app = launch(arguments: ["-blau.featureFlag.perfHUD", "YES"])
        let panel = hud(app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let before = panel.frame
        let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 60, dy: 240))
        start.press(forDuration: 0.1, thenDragTo: end)
        let moved = NSPredicate { _, _ in panel.frame.minY > before.minY + 100 }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    func testTripleTapTogglesTheHUDInDebugBuilds() {
        let app = launch()
        XCTAssertFalse(hud(app).exists)
        // The "Blau" title is plain text in the main screen's content, away
        // from every button (the content's centre can be the onboarding
        // button).
        let title = app.descendants(matching: .any)["blau.mainScreen.empty"].staticTexts["Blau"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // The speech-model setup card re-centres the empty state when it goes
        // away, which moves the onboarding button to where the title was. Let
        // that happen first, so no tap lands on the button mid-move and opens
        // the onboarding sheet instead.
        let setup = app.descendants(matching: .any)["blau.models.setup"]
        _ = setup.waitForExistence(timeout: 5)
        XCTAssertTrue(setup.waitForNonExistence(timeout: 120), "The speech models never became ready")
        waitForStableFrame(of: title)
        title.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(hud(app).waitForExistence(timeout: 5), "Triple-tap should show the HUD")
        title.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: hud(app))
        waitForExpectations(timeout: 5)
    }

    /// Waits until `element` stays put for half a second (layout and its
    /// animations have settled), up to `timeout`.
    private func waitForStableFrame(of element: XCUIElement, timeout: TimeInterval = 5) {
        var last = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let frame = element.frame
            if frame == last { return }
            last = frame
        }
    }
}
