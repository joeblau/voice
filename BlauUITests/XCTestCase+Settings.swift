import XCTest

/// Opening the settings sheet (#43) and its panes from UI tests.
///
/// Settings opens from the main screen's bottom-left button as a sheet at
/// the medium detent, with one row per pane (`SettingsPane`); a row pushes
/// its pane and grows the sheet to the large detent.
extension XCTestCase {
    enum SettingsPaneID {
        static let account = "settings.pane.account"
        static let voice = "settings.pane.voice"
        static let voiceID = "settings.pane.voiceID"
        static let transcription = "settings.pane.transcription"
        static let knowledge = "settings.pane.knowledge"
        static let iCloud = "settings.pane.iCloud"
        /// Speech Models keeps the identifier of its former link.
        static let models = "blau.models.settingsLink"
        static let privacy = "settings.pane.privacy"
        static let developer = "settings.pane.developer"

        static let all = [account, voice, voiceID, transcription, knowledge, iCloud, models, privacy, developer]
    }

    /// Taps the main screen's Settings button and returns the settings list.
    @MainActor
    @discardableResult
    func openSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let button = app.buttons["blau.settings.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "No Settings button", file: file, line: line)
        button.tap()
        let list = app.collectionViews["settings.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Settings did not open", file: file, line: line)
        return list
    }

    /// Opens Settings, then the pane whose row has `identifier`.
    @MainActor
    func openSettingsPane(
        _ identifier: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let list = openSettings(in: app, file: file, line: line)
        let row = app.buttons[identifier]
        scrollTo(row, in: list, file: file, line: line)
        row.tap()
    }
}
