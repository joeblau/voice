import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauRealtime

/// Settings → xAI account → usage: Grok's speaking time and text inputs
/// from the stored transcript, priced at xAI's speech-to-speech rates.
@Suite("Realtime usage estimate")
@MainActor
struct RealtimeUsageEstimateTests {
    let october = DateInterval(
        start: Date(timeIntervalSince1970: 1_790_812_800),  // 2026-10-01 00:00 UTC
        end: Date(timeIntervalSince1970: 1_793_491_200))  // 2026-11-01 00:00 UTC
    var midMonth: Date { october.start.addingTimeInterval(10 * 86_400) }

    private func row(_ role: UtteranceRole, at offset: TimeInterval, seconds: TimeInterval?, isFinal: Bool = true)
        -> RealtimeUsageEstimator.Row
    {
        let start = midMonth.addingTimeInterval(offset)
        return .init(
            role: role, startedAt: start, endedAt: seconds.map { start.addingTimeInterval($0) }, isFinal: isFinal)
    }

    @Test func countsAgentSpeechAndUserTextInputs() {
        let estimate = RealtimeUsageEstimator.estimate(
            rows: [
                row(.user, at: 0, seconds: 3),
                row(.agent, at: 4, seconds: 90),
                row(.user, at: 100, seconds: 2),
                row(.agent, at: 103, seconds: 30),
                row(.system, at: 140, seconds: 1),
            ], conversations: 1, period: october)

        #expect(estimate.textInputs == 2)
        #expect(estimate.agentSpeech == .seconds(120))
        #expect(estimate.agentMinutes == 2)
        #expect(estimate.conversations == 1)
        // 2 min × $0.08 + 2 × $0.004
        #expect(estimate.cost() == Decimal(string: "0.168"))
    }

    @Test func partialsUnfinishedRepliesAndOtherMonthsDontCount() {
        let estimate = RealtimeUsageEstimator.estimate(
            rows: [
                row(.user, at: 0, seconds: 3, isFinal: false),
                row(.agent, at: 4, seconds: nil),
                row(.agent, at: 10, seconds: 0),
                .init(
                    role: .user, startedAt: october.end, endedAt: october.end.addingTimeInterval(2), isFinal: true),
                .init(
                    role: .agent, startedAt: october.start.addingTimeInterval(-60),
                    endedAt: october.start.addingTimeInterval(-30), isFinal: true),
            ], conversations: 0, period: october)
        #expect(estimate.isEmpty)
        #expect(estimate.cost() == 0)
    }

    @Test func costFollowsThePricing() {
        let estimate = RealtimeUsageEstimate(period: october, textInputs: 10, agentSpeech: .seconds(30))
        let pricing = RealtimePricing(
            audioPerMinute: Decimal(string: "0.10")!, perTextInput: Decimal(string: "0.01")!, model: "test",
            asOf: "2026-10")
        // 0.5 min × $0.10 + 10 × $0.01
        #expect(estimate.cost(at: pricing) == Decimal(string: "0.15"))
        #expect(RealtimePricing.grokVoiceThinkFast.audioPerMinute == Decimal(string: "0.08"))
        #expect(RealtimePricing.grokVoiceThinkFast.perTextInput == Decimal(string: "0.004"))
    }

    @Test func monthContainingADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(RealtimeUsageEstimator.month(containing: midMonth, calendar: calendar) == october)
    }

    @Test func readsTheStore() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = container.mainContext
        let conversation = Conversation(startedAt: midMonth)
        context.insert(conversation)
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "Hi", startedAt: midMonth,
                endedAt: midMonth.addingTimeInterval(1), isFinal: true, source: .parakeet))
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .agent, text: "Hello there",
                startedAt: midMonth.addingTimeInterval(2),
                endedAt: midMonth.addingTimeInterval(62), isFinal: true, source: .grok))
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "And", startedAt: midMonth.addingTimeInterval(70),
                isFinal: false, source: .parakeet))
        let lastMonth = Conversation(startedAt: october.start.addingTimeInterval(-86_400))
        context.insert(lastMonth)
        context.insert(
            StoredUtterance(
                conversation: lastMonth, role: .agent, text: "Old", startedAt: lastMonth.startedAt,
                endedAt: lastMonth.startedAt.addingTimeInterval(600), isFinal: true, source: .grok))
        try context.save()

        let estimate = try RealtimeUsageEstimator.estimate(in: context, period: october)

        #expect(estimate.conversations == 1)
        #expect(estimate.textInputs == 1)
        #expect(estimate.agentSpeech == .seconds(60))
        #expect(estimate.cost() == Decimal(string: "0.084"))
    }
}
