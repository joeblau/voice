import BlauAudio
import BlauCore
import BlauRealtime
import Foundation
import Observation

/// How much of a reply item has been heard: the conversation's
/// `StreamingAudioPlayer.playedItem(for:)` in the live app.
typealias ChatPlaybackProgress = @Sendable (PlaybackItemID) -> PlayedItem?

/// The live half of the chat transcript (#42): follows the turn
/// orchestrator's snapshots and the transcript feed, and publishes what the
/// view shows on top of the store.
///
/// The rules live in BlauKit's `ChatLiveState`; this only feeds it and
/// splits its output into observable properties that change at different
/// rates, so the long list of finished rows isn't rebuilt for every word of
/// a reply:
///
/// - `recorded`, `liveAgentIDs` and `interruptedAgentIDs` change at most
///   once per utterance; the finished rows depend on them.
/// - `liveRows` changes with every partial and transcript delta; only the
///   rows at the bottom depend on it.
///
/// Each property is assigned only when its value changed.
@MainActor
@Observable
final class ChatTranscriptModel {
    /// The conversation on screen while one runs (and after it ends, until
    /// another starts).
    private(set) var conversationID: ConversationID?
    /// Utterances just written to the store, newest version of each.
    private(set) var recorded: [UUID: ChatLine] = [:]
    /// Stored replies the live rows stand in for while they play.
    private(set) var liveAgentIDs: Set<UUID> = []
    /// Stored replies the user cut short in the running conversation.
    private(set) var interruptedAgentIDs: Set<UUID> = []
    /// Grok's reply as it plays, then the user's speech in progress.
    private(set) var liveRows: [ChatRow] = []

    /// How much of each reply item has been heard, to reveal its words in
    /// step with the audio. `nil` (previews, fakes): replies show in full.
    let progress: ChatPlaybackProgress?

    @ObservationIgnored private var state: ChatLiveState
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private var subscriptions: [Task<Void, Never>] = []
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// - Parameters:
    ///   - snapshots: The turn orchestrator's snapshots, if there is one.
    ///   - events: The transcript feed's events.
    ///   - progress: Playback progress per reply item.
    init(
        snapshots: AsyncStream<TurnSnapshot>?,
        events: AsyncStream<TranscriptFeed.Event>?,
        progress: ChatPlaybackProgress?,
        clock: any BlauClock = SystemClock(),
        holdDuration: TimeInterval = 1.5
    ) {
        self.progress = progress
        self.clock = clock
        self.state = ChatLiveState(holdDuration: holdDuration)
        if let snapshots {
            subscriptions.append(
                Task { [weak self] in
                    for await snapshot in snapshots {
                        self?.apply(snapshot)
                    }
                })
        }
        if let events {
            subscriptions.append(
                Task { [weak self] in
                    for await event in events {
                        self?.apply(event)
                    }
                })
        }
    }

    /// Follows `realtime` when it is the live `TurnOrchestrator` and reveals
    /// replies as `player` plays them.
    convenience init(realtime: any RealtimeService, feed: TranscriptFeed?, player: StreamingAudioPlayer?) {
        var progress: ChatPlaybackProgress?
        if let player {
            progress = { item in player.playedItem(for: item) }
        }
        let orchestrator = realtime as? TurnOrchestrator
        self.init(snapshots: orchestrator?.updates(), events: feed?.events(), progress: progress)
    }

    isolated deinit {
        for subscription in subscriptions {
            subscription.cancel()
        }
        expiry?.cancel()
    }

    // MARK: Input

    func apply(_ snapshot: TurnSnapshot) {
        let conversation = state.conversationID
        state.apply(snapshot, at: clock.now)
        // A snapshot only changes the recorded lines by switching
        // conversations; skip comparing them on every partial.
        publish(recordedChanged: state.conversationID != conversation)
        scheduleExpiry()
    }

    func apply(_ event: TranscriptFeed.Event) {
        state.apply(event)
        publish(recordedChanged: true)
        scheduleExpiry()
    }

    /// Lets a held partial go once it expires: the speech wasn't committed
    /// (another voice, or nothing usable).
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let held = state.heldPartial else { return }
        let delay = max(0, held.expiresAt.timeIntervalSince(clock.now))
        let clock = clock
        expiry = Task { [weak self] in
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.expireHeldPartial()
        }
    }

    private func expireHeldPartial() {
        if state.expireHeldPartial(at: clock.now) {
            publish(recordedChanged: false)
        }
    }

    // MARK: Output

    private func publish(recordedChanged: Bool) {
        if conversationID != state.conversationID {
            conversationID = state.conversationID
        }
        if recordedChanged, recorded != state.recorded {
            recorded = state.recorded
        }
        let agentIDs = state.liveAgentIDs
        if liveAgentIDs != agentIDs {
            liveAgentIDs = agentIDs
        }
        let interrupted = state.interruptedAgentIDs
        if interruptedAgentIDs != interrupted {
            interruptedAgentIDs = interrupted
        }
        let rows = state.liveRows(now: clock.now)
        if liveRows != rows {
            liveRows = rows
        }
    }
}
