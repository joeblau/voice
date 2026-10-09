import Accessibility
import BlauAudio
import BlauCore
import BlauRealtime
import BlauTopics
import Foundation
import SwiftUI
import Testing

@testable import Blau

/// The app side of the accessibility pass (#81): what VoiceOver is told,
/// the Reduce Motion alternatives and the live caption's model. When to
/// announce a topic and how a caption is cut are tested by `swift test` in
/// BlauKit (`TopicAnnouncerTests`, `ChatCaptionTests`); the audits run in
/// `AccessibilityAuditUITests`.
@Suite("Accessibility")
@MainActor
struct AccessibilityTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Announcements

    @Test func topicAnnouncementsNameTheTopic() {
        #expect(BlauAnnouncement.text(for: .newTopic(title: "Pricing")) == "New topic: Pricing")
        #expect(BlauAnnouncement.text(for: .newTopic(title: nil)) == "New topic", "never 'New topic: New topic'")
        #expect(
            BlauAnnouncement.text(for: .titleRefined(title: "Pricing Experiments"))
                == "Topic named Pricing Experiments")
    }

    @Test func anIssueAnnouncementSaysWhatHappenedAndWhatItMeans() {
        let issue = UserFacingIssue(.offline)
        let text = BlauAnnouncement.text(for: issue)
        #expect(text.hasPrefix(issue.title))
        #expect(text.hasSuffix(issue.message))
    }

    @Test func politeAnnouncementsWaitAndUrgentOnesInterrupt() {
        let polite = BlauAnnouncement.attributed("New topic: Pricing", urgency: .polite)
        let urgent = BlauAnnouncement.attributed("Microphone unavailable", urgency: .urgent)
        #expect(String(polite.characters) == "New topic: Pricing")
        #expect(polite.accessibilitySpeechAnnouncementPriority == .low)
        #expect(urgent.accessibilitySpeechAnnouncementPriority == .high)
    }

    // MARK: Reduce Motion

    @Test func reduceMotionTurnsSpringsIntoAShortEase() {
        let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)
        #expect(Motion.animation(spring, reduceMotion: false) == spring)
        #expect(Motion.animation(spring, reduceMotion: true) == .easeInOut(duration: 0.2))
    }

    // MARK: Live caption

    /// The caption follows the live model: Grok's streaming reply, in the
    /// running conversation only.
    @Test func theCaptionIsGroksStreamingReplyInTheRunningConversation() async throws {
        let (snapshots, input) = AsyncStream.makeStream(of: TurnSnapshot.self)
        let model = ChatTranscriptModel(snapshots: snapshots, events: nil, progress: nil)
        let conversation = ConversationID()
        input.yield(TurnSnapshot(state: .userSpeaking, conversationID: conversation, userPartial: "What about"))
        try await waitUntil { !model.liveRows.isEmpty }
        #expect(ChatCaption.speakingRow(in: model.liveRows) == nil, "the user's speech isn't captioned")

        let reply = TurnSnapshot.AgentSpeech(
            utteranceID: UUID(), playbackID: PlaybackItemID(itemID: "item_1"), transcript: LiveCaptionFixture.reply,
            startedAt: Self.t0)
        input.yield(TurnSnapshot(state: .agentSpeaking, conversationID: conversation, agentSpeech: [reply]))
        try await waitUntil { ChatCaption.speakingRow(in: model.liveRows) != nil }
        let row = try #require(ChatCaption.speakingRow(in: model.liveRows))
        #expect(row.id == reply.utteranceID)
        #expect(row.text == LiveCaptionFixture.reply)
        #expect(model.conversationID == conversation)
        input.finish()
    }

    @Test func theFixtureReplyIsLongEnoughToBeCut() {
        let caption = ChatCaption.tail(
            of: LiveCaptionFixture.reply, maxCharacters: ChatCaption.maxCharacters(isAccessibilitySize: false))
        #expect(caption.hasPrefix("\u{2026}"))
        #expect(caption.hasSuffix("what would make them stop using it?"))
    }

    private func waitUntil(
        timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
