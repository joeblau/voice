import Foundation
import Testing

@testable import BlauCore

@Suite("Error catalog")
struct IssueCatalogTests {
    /// docs/errors.md, from this file's place in the repo.
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BlauCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // BlauKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appending(path: "docs/errors.md")

    @Test(arguments: IssueCode.allCases)
    func everyEntryIsComplete(code: IssueCode) {
        let issue = UserFacingIssue(code)
        #expect(!issue.title.isEmpty)
        #expect(issue.title.count <= 32, "keep titles short enough for a banner: \(issue.title)")
        #expect(issue.message.hasSuffix(".") || issue.message.hasSuffix(")."))
        #expect(issue.message.count <= 200, "\(issue.message.count) characters")
        #expect(!issue.title.hasSuffix("."))
        #expect(Set(issue.actions).count == issue.actions.count, "no duplicate actions")
        // Nothing works until the user acts, so there must be something to do.
        if issue.severity == .blocking, code != .storeUnavailable {
            #expect(!issue.actions.isEmpty)
        }
    }

    @Test func codesAreUniqueAndNamespacedByArea() {
        let rawValues = IssueCode.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
        let prefixes: [IssueArea: String] = [
            .connection: "connection.", .account: "account.", .replies: "reply.", .audio: "audio.",
            .speechModels: "models.", .storage: "storage.",
        ]
        for code in IssueCode.allCases {
            #expect(code.rawValue.hasPrefix(prefixes[code.area] ?? "?"), "\(code)")
        }
        #expect(IssueArea.allCases.allSatisfy { !IssueCode.codes(in: $0).isEmpty })
    }

    /// The acceptance criterion "error catalog documented": docs/errors.md
    /// lists every code, and no code that doesn't exist.
    @Test func theCatalogDocumentListsEveryCode() throws {
        let document = try String(contentsOf: Self.catalogURL, encoding: .utf8)
        for code in IssueCode.allCases {
            #expect(document.contains("`\(code.rawValue)`"), "docs/errors.md is missing \(code.rawValue)")
            #expect(document.contains(code.title), "docs/errors.md has another title for \(code.rawValue)")
        }
        let documented = Set(
            document.matches(of: /`((?:connection|account|reply|audio|models|storage)\.[A-Za-z]+)`/).map {
                String($0.output.1)
            })
        let known = Set(IssueCode.allCases.map(\.rawValue))
        #expect(documented.subtracting(known).isEmpty, "documented but unknown: \(documented.subtracting(known))")
    }

    @Test func customizingAnIssueKeepsItsEntry() {
        let issue = UserFacingIssue(.offline, detail: "")
            .withMessage("Two waiting.")
            .adding(.discardQueued)
            .adding(.discardQueued)
        #expect(issue.code == .offline)
        #expect(issue.title == "You're offline")
        #expect(issue.message == "Two waiting.")
        #expect(issue.actions == [.discardQueued])
        #expect(issue.primaryAction == .discardQueued)
        #expect(issue.detail == nil)
        #expect(issue.severity == .info)
    }

    @Test func everyActionHasATitle() {
        for action in RecoveryAction.allCases {
            #expect(!action.title.isEmpty)
        }
        #expect(RecoveryAction.xaiConsoleURL.host() == "console.x.ai")
    }
}

@Suite("Issue board")
struct IssueBoardTests {
    @Test func showsTheWorstFirst() {
        var board = IssueBoard()
        board.update(.storage, UserFacingIssue(.iCloudFull))
        board.update(.conversation, UserFacingIssue(.offline))
        board.update(.audio, UserFacingIssue(.microphoneDenied))
        #expect(board.visible.map(\.code) == [.microphoneDenied, .iCloudFull, .offline])
        #expect(board.primary?.code == .microphoneDenied)

        board.update(.audio, nil)
        #expect(board.visible.map(\.code) == [.iCloudFull, .offline])
    }

    @Test func equalSeverityFollowsTheSourceOrder() {
        var board = IssueBoard()
        board.update(.storage, UserFacingIssue(.iCloudFull))
        board.update(.conversation, UserFacingIssue(.grokUnreachable))
        #expect(board.visible.map(\.code) == [.grokUnreachable, .iCloudFull])
    }

    @Test func aDismissedIssueStaysHiddenUntilItChanges() {
        var board = IssueBoard()
        board.update(.storage, UserFacingIssue(.iCloudFull))
        board.dismiss(.iCloudFull)
        #expect(board.visible.isEmpty)
        // Reported again while it lasts: still hidden.
        board.update(.storage, UserFacingIssue(.iCloudFull))
        #expect(board.visible.isEmpty)
        #expect(board.issue(from: .storage)?.code == .iCloudFull)
        // Fixed, then broken again: shown again.
        board.update(.storage, nil)
        board.update(.storage, UserFacingIssue(.iCloudFull))
        #expect(board.visible.map(\.code) == [.iCloudFull])
    }

    @Test func aDismissedIssueComesBackAsSomethingElse() {
        var board = IssueBoard()
        board.update(.conversation, UserFacingIssue(.offline))
        board.dismiss(.offline)
        board.update(.conversation, UserFacingIssue(.grokUnreachable))
        #expect(board.visible.map(\.code) == [.grokUnreachable])
    }

    @Test func blockingIssuesCantBeDismissed() {
        var board = IssueBoard()
        board.update(.conversation, UserFacingIssue(.missingAPIKey))
        #expect(!IssueBoard.canDismiss(UserFacingIssue(.missingAPIKey)))
        #expect(IssueBoard.canDismiss(UserFacingIssue(.offline)))
        board.dismiss(.missingAPIKey)
        #expect(board.visible.map(\.code) == [.missingAPIKey])
    }

    @Test func severitiesAreOrdered() {
        #expect(IssueSeverity.info < .warning)
        #expect(IssueSeverity.warning < .blocking)
        #expect(IssueSeverity.allCases.max() == .blocking)
    }
}
