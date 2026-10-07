import BlauCore
import BlauPersistence
import BlauRealtime
import Foundation
import Testing
import UIKit

@testable import Blau

/// The issue banner's model and the composition root's wiring (#80).
@MainActor
struct IssueCenterTests {
    @Test func everyCatalogEntryHasASymbol() {
        for code in IssueCode.allCases {
            let name = IssueBanner.symbol(for: code)
            #expect(UIImage(systemName: name) != nil, "\(code): no SF Symbol named \(name)")
        }
    }

    @Test func theCenterShowsTheWorstIssueAndHonoursDismissals() {
        let environment = AppEnvironment.fake(kind: .unitTest)
        let center = environment.issues
        #expect(center.primary == nil)

        center.update(.storage, UserFacingIssue(.iCloudFull))
        center.update(.conversation, UserFacingIssue(.offline))
        #expect(center.visible.map(\.code) == [.iCloudFull, .offline])

        center.dismiss(UserFacingIssue(.iCloudFull))
        #expect(center.primary?.code == .offline)

        center.update(.audio, UserFacingIssue(.microphoneDenied))
        center.dismiss(UserFacingIssue(.microphoneDenied))
        #expect(center.primary?.code == .microphoneDenied, "blocking issues can't be dismissed")
    }

    @Test func theStoreFeedsTheBoard() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        environment.issues.start()
        // The in-memory store has nothing to report.
        await environment.persistence.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(environment.issues.board.issue(from: .storage) == nil)
    }

    @Test func fixturesShowDiscardForConnectionIssues() throws {
        let offline = IssueCenter.fixtureIssue(.offline)
        #expect(offline.actions == [.discardQueued])
        #expect(offline.message.hasSuffix("2 messages are waiting to send."))
        #expect(IssueCenter.fixtureIssue(.missingAPIKey) == UserFacingIssue(.missingAPIKey))

        let defaults = try #require(UserDefaults(suiteName: "IssueCenterTests"))
        defaults.set("connection.offline", forKey: IssueCenter.fixtureArgument)
        #expect(IssueCenter.fixtureCode(in: defaults) == .offline)
        defaults.set("not.a.code", forKey: IssueCenter.fixtureArgument)
        #expect(IssueCenter.fixtureCode(in: defaults) == nil)
        defaults.removePersistentDomain(forName: "IssueCenterTests")
    }

    @Test func actionsWithoutALiveConversationDoNothing() async {
        let environment = AppEnvironment.fake(kind: .unitTest)
        // The fake realtime service is not an orchestrator: Try Again and
        // Discard have nothing to act on, and must not start a conversation.
        await environment.issues.perform(.retry, models: environment.speechModels)
        await environment.issues.perform(.discardQueued, models: environment.speechModels)
        #expect(await !environment.realtime.isConnected)
    }
}
