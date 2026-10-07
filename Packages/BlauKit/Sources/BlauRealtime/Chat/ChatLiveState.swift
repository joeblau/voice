import BlauCore
import BlauPersistence
import Foundation

/// What the chat transcript (#42) shows on top of the store while a
/// conversation runs: the user's speech in progress, Grok's reply as it
/// plays, and the utterances just recorded.
///
/// The store saves in batches (up to 2 s after a commit, see
/// `ConversationStoreSavePolicy`), so a `@Query` alone would lose the user's
/// words between the partial clearing and the saved row arriving. Feed this
/// the turn orchestrator's snapshots and the ``TranscriptFeed``'s events;
/// it keeps each utterance the orchestrator recorded (``recorded``), holds
/// the last partial until its final text is recorded (``heldPartial``), and
/// lists Grok's reply items (``agentSpeech``) so the view can reveal them in
/// step with the audio.
///
/// A plain value with explicit times, so the rules are tested on the Mac.
/// `ChatTranscriptModel` in the app drives it.
public struct ChatLiveState: Sendable, Equatable {
    /// The conversation the live rows belong to: the running one, or the
    /// one that just ended (its rows stay until the store has them).
    public private(set) var conversationID: ConversationID?
    /// The utterances recorded in ``conversationID``, newest version of each.
    public private(set) var recorded: [UUID: ChatLine] = [:]
    /// The user's speech in progress.
    public private(set) var userPartial: String?
    /// When the first partial of the speech in progress (or held) arrived.
    public private(set) var partialStartedAt: Date?
    /// The last partial, kept after the partial cleared until the final
    /// text is recorded (or ``holdDuration`` passes: speech that wasn't
    /// committed, e.g. another voice).
    public private(set) var heldPartial: HeldPartial?
    /// Grok's reply items while the reply plays.
    public private(set) var agentSpeech: [TurnSnapshot.AgentSpeech] = []
    /// The stored replies in ``conversationID`` the user cut short, as the
    /// orchestrator reported them (`TurnSnapshot.interruptedAgentUtterances`).
    /// Kept after the conversation ends, while its rows stay on screen.
    public private(set) var interruptedAgentIDs: Set<UUID> = []
    /// The user's utterances in ``conversationID`` waiting for the
    /// connection (`TurnSnapshot.queuedUtteranceIDs`, #80).
    public private(set) var waitingUserIDs: Set<UUID> = []
    /// The user's utterances in ``conversationID`` discarded while they
    /// waited, or still waiting when the conversation stopped: stored but
    /// never sent. Kept after the conversation ends, like
    /// ``interruptedAgentIDs``.
    public private(set) var unsentUserIDs: Set<UUID> = []
    /// How long a cleared partial is kept waiting for its final text.
    public var holdDuration: TimeInterval

    public struct HeldPartial: Sendable, Equatable {
        public var text: String
        /// When it stops being shown.
        public var expiresAt: Date
    }

    public init(holdDuration: TimeInterval = 1.5) {
        self.holdDuration = holdDuration
    }

    // MARK: Input

    /// Takes in one of the orchestrator's snapshots, received at `now`.
    public mutating func apply(_ snapshot: TurnSnapshot, at now: Date) {
        if let id = snapshot.conversationID {
            switchConversation(to: id)
        }
        let partial = snapshot.userPartial.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        if let partial {
            if userPartial == nil {
                partialStartedAt = now
            }
            heldPartial = nil
            userPartial = partial
        } else if let previous = userPartial {
            // The utterance ended: keep its words up until the final text
            // is recorded, so the row resolves in place instead of blinking.
            heldPartial = HeldPartial(text: previous, expiresAt: now.addingTimeInterval(holdDuration))
            userPartial = nil
        }
        agentSpeech = snapshot.agentSpeech.filter { !$0.transcript.allSatisfy(\.isWhitespace) }
        // Between conversations the orchestrator's set is empty; the marks
        // stay with the conversation still on screen.
        if snapshot.conversationID != nil {
            interruptedAgentIDs.formUnion(snapshot.interruptedAgentUtterances)
            unsentUserIDs.formUnion(snapshot.discardedUtteranceIDs)
        } else {
            // The conversation stopped: what still waited is never sent.
            unsentUserIDs.formUnion(waitingUserIDs)
        }
        waitingUserIDs = Set(snapshot.queuedUtteranceIDs)
    }

    /// Takes in one of the transcript feed's events.
    public mutating func apply(_ event: TranscriptFeed.Event) {
        switch event {
        case .began(let id, _):
            switchConversation(to: id)
        case .recorded(let utterance):
            if conversationID == nil {
                conversationID = utterance.conversationID
            }
            // A late write for an earlier conversation (a second pass landing
            // after a new one began) reaches the screen through the store.
            guard utterance.conversationID == conversationID else { return }
            recorded[utterance.id] = ChatLine(utterance)
            if utterance.speaker == .user, heldPartial != nil {
                heldPartial = nil
                partialStartedAt = nil
            }
        case .finished:
            // Keep the rows: the conversation stays on screen.
            break
        }
    }

    /// Drops the held partial once it has expired. Returns whether anything
    /// changed.
    @discardableResult
    public mutating func expireHeldPartial(at now: Date) -> Bool {
        guard let heldPartial, heldPartial.expiresAt <= now else { return false }
        self.heldPartial = nil
        if userPartial == nil {
            partialStartedAt = nil
        }
        return true
    }

    private mutating func switchConversation(to id: ConversationID) {
        guard id != conversationID else { return }
        conversationID = id
        recorded.removeAll()
        userPartial = nil
        partialStartedAt = nil
        heldPartial = nil
        agentSpeech = []
        interruptedAgentIDs.removeAll()
        waitingUserIDs.removeAll()
        unsentUserIDs.removeAll()
    }

    // MARK: Output

    /// The stored ids the live rows stand in for: replies still playing.
    public var liveAgentIDs: Set<UUID> {
        Set(agentSpeech.map(\.utteranceID))
    }

    /// The rows after the finished ones: Grok's reply as it plays, then the
    /// user's speech in progress (or held until its final text arrives).
    ///
    /// - Parameter now: Stands in for a start time that wasn't recorded.
    public func liveRows(now: Date) -> [ChatRow] {
        var rows = agentSpeech.map { speech in
            ChatRow(
                id: speech.utteranceID, role: .agent, text: speech.transcript, startedAt: speech.startedAt ?? now,
                kind: .streaming(speech.playbackID))
        }
        if let text = userPartial ?? heldPartial?.text {
            rows.append(
                ChatRow(
                    id: ChatRow.livePartialID, role: .user, text: text, startedAt: partialStartedAt ?? now,
                    kind: .partial))
        }
        return rows
    }
}
