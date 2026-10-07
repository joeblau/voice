import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import CoreGraphics
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Blau

/// The app side of the chat transcript (#42): the live model, the fixture,
/// and how a row is drawn. The row-building rules are tested by
/// `swift test` in BlauKit (`ChatTranscriptTests`, `ChatLiveStateTests`).
@Suite("Chat transcript")
@MainActor
struct ChatTranscriptViewTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Live model

    @Test func theModelFollowsSnapshotsAndTranscriptWrites() async throws {
        let (snapshots, snapshotInput) = AsyncStream.makeStream(of: TurnSnapshot.self)
        let feed = TranscriptFeed()
        let clock = ManualClock(now: Self.t0)
        let model = ChatTranscriptModel(
            snapshots: snapshots, events: feed.events(), progress: nil, clock: clock, holdDuration: 1.5)
        let conversation = ConversationID()

        snapshotInput.yield(
            TurnSnapshot(state: .userSpeaking, conversationID: conversation, userPartial: "What should"))
        try await waitUntil { model.liveRows.map(\.text) == ["What should"] }
        #expect(model.conversationID == conversation)
        #expect(model.liveRows.first?.kind == .partial)

        // Final: the partial is held until the write arrives.
        snapshotInput.yield(TurnSnapshot(state: .committing, conversationID: conversation))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.liveRows.map(\.text) == ["What should"])
        let final = BlauCore.Utterance(
            conversationID: conversation, speaker: .user, text: "What should I focus on?",
            timeRange: TimeRange(start: .zero, duration: .seconds(2)), startedAt: Self.t0)
        feed.publish(.recorded(final))
        try await waitUntil { model.liveRows.isEmpty }
        #expect(model.recorded[final.id]?.text == "What should I focus on?")

        // The reply streams under the id it is stored with.
        let reply = TurnSnapshot.AgentSpeech(
            utteranceID: UUID(), playbackID: PlaybackItemID(itemID: "item_1"), transcript: "Start with",
            startedAt: Self.t0)
        snapshotInput.yield(TurnSnapshot(state: .agentSpeaking, conversationID: conversation, agentSpeech: [reply]))
        try await waitUntil { model.liveAgentIDs == [reply.utteranceID] }
        #expect(model.liveRows.map(\.kind) == [.streaming(reply.playbackID)])
        snapshotInput.finish()
    }

    @Test func aHeldPartialGoesAwayWhenNoFinalComes() async throws {
        let (snapshots, input) = AsyncStream.makeStream(of: TurnSnapshot.self)
        let clock = ManualClock(now: Self.t0)
        let model = ChatTranscriptModel(
            snapshots: snapshots, events: nil, progress: nil, clock: clock, holdDuration: 1.5)
        let conversation = ConversationID()
        input.yield(TurnSnapshot(state: .userSpeaking, conversationID: conversation, userPartial: "Hey Siri"))
        input.yield(TurnSnapshot(state: .listening, conversationID: conversation))
        try await waitUntil { model.liveRows.count == 1 }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1.5))
        try await waitUntil { model.liveRows.isEmpty }
        input.finish()
    }

    // MARK: Fixture

    @Test func theFixtureSeedsOneConversationWithInterruptedReplies() async throws {
        let persistence = PersistenceController.inMemory()
        await ChatTranscriptFixture.seed(count: 1_000, into: persistence, endingAt: Self.t0)
        let container = try #require(persistence.stack?.container)
        let context = ModelContext(container)
        let conversation = try #require(try context.fetch(ChatTranscript.latestConversation).first)
        let stored = try context.fetch(ChatTranscript.utterances(in: conversation.id))
        #expect(stored.count == 1_000)
        let rows = ChatTranscript.rows(stored: stored.compactMap(ChatLine.init))
        #expect(rows.count == 1_000)
        #expect(rows.filter { $0.role == .user }.count == 500)
        // Reply 6, 13, 20...: every seventh of 500.
        #expect(rows.filter(\.isInterrupted).count == 500 / ChatTranscriptFixture.interruptedEvery)
        #expect(rows.filter(\.isInterrupted).allSatisfy { $0.role == .agent })
    }

    @Test func aUITestLaunchSeedsTheFixtureItAsksFor() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ChatTranscriptViewTests.\(UUID().uuidString)"))
        let environment = AppEnvironment.fake(kind: .uiTest)
        await ChatTranscriptFixture.seedIfRequested(in: environment, defaults: defaults)
        await environment.persistence.start()
        let container = try #require(environment.persistence.stack?.container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredUtterance>()) == 0)

        defaults.set(10, forKey: ChatTranscriptFixture.launchArgument)
        await ChatTranscriptFixture.seedIfRequested(in: environment, defaults: defaults)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredUtterance>()) == 10)
    }

    // MARK: Drawing

    /// The visual spec: user text on the right, agent text on the left, at
    /// most 85 % of the width, and no bubble behind either. The row is
    /// hosted in a scroll view in a window, as on the main screen, and the
    /// screen is read back: on a white background a bubble would fill its
    /// box with color, while bare text inks only a fraction of it.
    @Test(arguments: [UtteranceRole.user, .agent])
    func aRowIsBareTextOnItsSpeakersSide(role: UtteranceRole) throws {
        let width: CGFloat = 393
        let row = ChatRow(
            id: UUID(), role: role,
            text: "Start with the launch checklist, then block two mornings for customer calls next week.",
            startedAt: Self.t0)
        let ink = InkMap(try snapshot(ChatRowView(row: row), width: width))
        let scale = CGFloat(ink.width) / width

        let drawn = ink.boundingColumns()
        try #require(!drawn.isEmpty, "Nothing was drawn")
        // Nothing drawn outside the speaker's 85 % of the width.
        let margin = Int((width * (1 - ChatTranscriptLayout.maxWidthFraction) * scale).rounded(.down)) - 1
        let opposite = role == .user ? 0..<margin : (ink.width - margin)..<ink.width
        #expect(ink.coverage(columns: opposite) == 0, "Drew outside the row's side: \(drawn)")
        // Hugging its side.
        if role == .user {
            #expect(drawn.upperBound >= ink.width - Int(4 * scale), "\(drawn)")
        } else {
            #expect(drawn.lowerBound <= Int(4 * scale), "\(drawn)")
        }
        // Text, not a filled shape: a bubble would cover close to all of its
        // box.
        #expect(ink.coverage(columns: drawn) < 0.35, "Looks like a filled background")
    }

    // MARK: Helpers

    /// Hosts `view` in a scroll view `width` points wide on a white window
    /// and reads the screen back.
    private func snapshot(_ view: some View, width: CGFloat) throws -> CGImage {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host app has no window scene")
        let content = ScrollView { view }
            .scrollDisabled(true)
            .environment(\.colorScheme, .light)
        let controller = UIHostingController(rootView: content)
        controller.overrideUserInterfaceStyle = .light
        controller.view.backgroundColor = .white
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        window.frame = CGRect(x: 0, y: 0, width: width, height: 240)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            _ = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        return try #require(image.cgImage)
    }

    /// Polls `condition` until it holds. The timeout is generous because it
    /// only bounds a failure: under a loaded simulator the model's stream
    /// tasks can take seconds to get onto the main actor.
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Which pixels of a screenshot on white are inked (clearly not white).
private struct InkMap {
    let width: Int
    let height: Int
    private let inked: [Bool]

    init(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        inked = stride(from: 0, to: pixels.count, by: 4).map { index in
            min(pixels[index], pixels[index + 1], pixels[index + 2]) < 200
        }
    }

    /// The share of pixels in `columns` (all rows) that are inked.
    func coverage(columns: Range<Int>) -> Double {
        let columns = columns.clamped(to: 0..<width)
        guard !columns.isEmpty, height > 0 else { return 0 }
        var count = 0
        for y in 0..<height {
            for x in columns where inked[y * width + x] {
                count += 1
            }
        }
        return Double(count) / Double(columns.count * height)
    }

    /// The columns between the first and the last inked one.
    func boundingColumns() -> Range<Int> {
        var first = width
        var last = -1
        for y in 0..<height {
            for x in 0..<width where inked[y * width + x] {
                first = min(first, x)
                last = max(last, x)
            }
        }
        return last < first ? 0..<0 : first..<(last + 1)
    }
}
