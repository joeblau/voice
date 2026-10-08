import UIKit
import XCTest

/// The knowledge base screens (#65), on fake services
/// (`BLAU_APP_ENVIRONMENT=ui-test`, an in-memory store): pasting a YC
/// collection, and About Me, Company and Notes saving as the user types.
@MainActor
final class KnowledgeBaseUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLAU_APP_ENVIRONMENT"] = "ui-test"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["blau.root"].waitForExistence(timeout: 30))
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openKnowledgeRow(_ identifier: String, in app: XCUIApplication) {
        openSettingsPane(SettingsPaneID.knowledge, in: app)
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No \(identifier) row in Settings → Knowledge")
        row.tap()
    }

    /// Closes the simulator keyboard's one-time tip, which covers the
    /// bottom of the screen the first time a keyboard appears.
    private func dismissKeyboardTip(in app: XCUIApplication) {
        let tip = app.buttons["Continue"]
        if tip.exists { tip.tap() }
    }

    private func goBack(from title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "No \(title) page")
        bar.buttons.element(boundBy: 0).tap()
    }

    /// Acceptance: a YC collection with 30 questions, made by pasting, in
    /// well under a minute.
    func testPastingThirtyQuestionsCreatesACollectionInUnderAMinute() {
        let questions =
            ["# YC interview questions"]
            + [
                "What are you building?", "Who are your users?", "Why did you pick this idea?",
                "What's new about what you're making?", "Who are your competitors?",
                "What do you understand that they don't?", "How do you make money?", "How big could this get?",
                "How many users do you have?", "How fast are you growing?", "What's your revenue?",
                "Why will you succeed?", "How did your cofounders meet?", "Who does what on the team?", "Why now?",
                "What's the hardest technical problem?", "How long have you been working on this?",
                "What have you learned from users?", "What's the biggest risk?", "What would you do with the money?",
                "How will you get users?", "What's your unfair advantage?", "Who would use this first?",
                "What do people want that they can't get today?", "How do you know people want this?",
                "What's the worst thing that could happen?", "What are you going to do next?",
                "Why isn't someone already doing this?", "What will you be doing in a year?",
                "Is anyone else on the team full time?",
            ].enumerated().map { "\($0.offset + 1). \($0.element)" }
        UIPasteboard.general.string = questions.joined(separator: "\n")

        let app = launch()
        let start = Date()
        openKnowledgeRow("knowledge.collections", in: app)
        let new = app.buttons["knowledge.collections.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()

        // The system Paste button: no permission prompt, one tap.
        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "No Paste button")
        paste.tap()
        let preview = element("knowledge.collection.preview", in: app)
        scrollTo(
            preview,
            in: app.collectionViews.containing(.any, identifier: "knowledge.collection.pasteText").firstMatch)
        let counted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "30 questions"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 10), .completed, "Preview: \(preview.label)")
        // The heading named the collection.
        let name = app.textFields["knowledge.collection.name"]
        XCTAssertEqual(name.value as? String, "YC interview questions")
        screenshot(app, "New collection, pasted")

        app.buttons["knowledge.collection.create"].tap()
        let header = app.staticTexts["30 questions"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The new collection didn't open with 30 questions")
        XCTAssertTrue(app.navigationBars["YC interview questions"].exists)
        XCTAssertTrue(
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "What are you building?")).firstMatch.exists
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 60, "Creating the collection took \(elapsed) s")
        let measured = XCTAttachment(string: String(format: "Created a 30-question collection in %.1f s", elapsed))
        measured.lifetime = .keepAlways
        add(measured)
        screenshot(app, "YC collection")

        // It is listed, with its count.
        goBack(from: "YC interview questions", in: app)
        XCTAssertTrue(
            app.staticTexts["YC interview questions"].waitForExistence(timeout: 5), "Not listed in Collections")
    }

    func testEditingAQuestion() {
        UIPasteboard.general.string = "Why now?\nWho are your users?"
        let app = launch()
        openKnowledgeRow("knowledge.collections", in: app)
        app.buttons["knowledge.collections.new"].tap()
        let name = app.textFields["knowledge.collection.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Practice")
        app.buttons["Paste"].firstMatch.tap()
        app.buttons["knowledge.collection.create"].tap()

        let question = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Why now?")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap()
        let answer = element("knowledge.item.answer", in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        answer.typeText("Voice models just got good enough.")
        app.buttons["knowledge.item.save"].tap()
        let edited = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Voice models just got good enough.")
        ).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10), "The reference answer isn't shown")
    }

    func testAboutMeCompanyAndNotesSaveAsYouType() {
        let app = launch()

        // About Me.
        openKnowledgeRow("knowledge.aboutMe", in: app)
        let myName = element("knowledge.aboutMe.name", in: app)
        XCTAssertTrue(myName.waitForExistence(timeout: 10))
        myName.tap()
        myName.typeText("Joe")
        let text = element("knowledge.aboutMe.text", in: app)
        text.tap()
        text.typeText("I'm building Blau, a voice app.")
        let status = element("knowledge.saveStatus", in: app)
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Saved"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed, "About Me wasn't saved: \(status.label)")
        screenshot(app, "About Me")
        goBack(from: "About Me", in: app)
        XCTAssertTrue(app.staticTexts["Joe"].waitForExistence(timeout: 10), "The About Me row doesn't show the name")

        // Company.
        app.buttons["knowledge.company"].tap()
        let company = element("knowledge.company.name", in: app)
        XCTAssertTrue(company.waitForExistence(timeout: 10))
        company.tap()
        company.typeText("Larderly")
        let traction = element("knowledge.company.traction", in: app)
        traction.tap()
        traction.typeText("40 paying restaurants")
        screenshot(app, "Company")
        goBack(from: "Company", in: app)
        XCTAssertTrue(
            app.staticTexts["Larderly"].waitForExistence(timeout: 10), "The Company row doesn't show the name")

        // A note.
        app.buttons["knowledge.notes"].tap()
        let new = app.buttons["knowledge.notes.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let title = element("knowledge.note.title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Pricing")
        let body = element("knowledge.note.body", in: app)
        body.tap()
        body.typeText("## Tiers\n- Starter\n- Pro")
        dismissKeyboardTip(in: app)
        element("knowledge.note.preview", in: app).tap()
        XCTAssertTrue(app.staticTexts["Tiers"].waitForExistence(timeout: 5), "The preview doesn't render the heading")
        screenshot(app, "Note preview")
        goBack(from: "Pricing", in: app)
        XCTAssertTrue(app.staticTexts["Pricing"].waitForExistence(timeout: 10), "The note isn't listed")
        screenshot(app, "Notes")
    }
}
