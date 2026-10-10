import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import SwiftData

/// One row of the chat transcript (#42): a finished utterance, the user's
/// speech in progress, or Grok's reply as it plays.
public struct ChatRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A finished utterance.
        case final
        /// The user's speech in progress: the latest ASR partial. Shown in a
        /// secondary style until the final text replaces it.
        case partial
        /// Grok's reply while its audio plays. `text` is everything received
        /// so far; the view shows the part already heard
        /// (``ChatTranscript/revealedText(of:played:)``).
        case streaming(PlaybackItemID)
        /// A tool Grok called, shown as a subtle chip (#68). The row's role
        /// is `system` and its text the chip's title.
        case tool(ChatToolCall)
    }

    /// The utterance's id. A streaming reply keeps the id it is stored
    /// under, so it turns into its final row in place;
    /// ``ChatRow/livePartialID`` marks the user's speech in progress.
    public var id: UUID
    public var role: UtteranceRole
    public var text: String
    public var startedAt: Date
    public var kind: Kind
    /// An agent reply the user cut off: only what was heard is shown, with
    /// a marker.
    public var isInterrupted: Bool
    /// Whether a user utterance reached Grok (#80).
    public var delivery: Delivery

    /// Whether a user utterance has gone to Grok.
    public enum Delivery: Hashable, Sendable {
        /// Sent (or not the user's, or from an earlier session).
        case sent
        /// Stored and waiting for the connection: Grok answers once it is
        /// back.
        case waiting
        /// The user discarded it while it waited: stored, never sent.
        case notSent
    }

    public init(
        id: UUID, role: UtteranceRole, text: String, startedAt: Date, kind: Kind = .final,
        isInterrupted: Bool = false, delivery: Delivery = .sent
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.startedAt = startedAt
        self.kind = kind
        self.isInterrupted = isInterrupted
        self.delivery = delivery
    }

    /// The row id of the user's speech in progress. There is at most one.
    public static let livePartialID = UUID(uuidString: "B1A00000-0000-4000-8000-0000000000A1")!

    /// The chip row for a tool call.
    public init(tool call: ChatToolCall) {
        self.init(id: call.rowID, role: .system, text: call.title, startedAt: call.startedAt, kind: .tool(call))
    }

    /// The tool call, for a chip row.
    public var toolCall: ChatToolCall? {
        if case .tool(let call) = kind { call } else { nil }
    }
}

/// Builds the chat transcript's rows. Pure functions over plain values, so
/// the rules are tested on the Mac and the view only lays rows out.
public enum ChatTranscript {
    /// How far a user utterance must start before the end of the agent
    /// reply in front of it for that reply to count as interrupted. Absorbs
    /// the difference between when a reply's audio arrived (its stored
    /// times) and when it was heard (the jitter buffer adds ~120 ms).
    public static let interruptionTolerance: TimeInterval = 0.25

    /// The finished rows: `stored` updated by `recorded` (the same id in
    /// both means `recorded` is newer: the app just wrote it), in the order
    /// spoken, without blank lines and without `excluding` (agent replies
    /// still playing, which the live rows show).
    ///
    /// An agent row is marked interrupted when it is in `interrupted` (the
    /// replies the turn orchestrator cut short in the running conversation,
    /// `TurnSnapshot.interruptedAgentUtterances`), when the store says so
    /// (``ChatLine/isInterrupted``, written since schema v3 and synced, so it
    /// holds after a relaunch and on other devices), or when the next user
    /// utterance started before the reply ended
    /// (``isInterrupted(_:before:)``). That last rule is the fallback for
    /// rows stored without the mark (before v3, or by an older app version);
    /// it runs on every unmarked row, because an unmarked v3 row can't be
    /// told from an older one.
    ///
    /// A user row in `waiting` (queued for the connection,
    /// `TurnSnapshot.queuedUtteranceIDs`) or `notSent` (discarded,
    /// `TurnSnapshot.discardedUtteranceIDs`) carries that ``ChatRow/delivery``
    /// (#80).
    public static func rows(
        stored: [ChatLine],
        recorded: [UUID: ChatLine] = [:],
        excluding excluded: Set<UUID> = [],
        interrupted: Set<UUID> = [],
        waiting: Set<UUID> = [],
        notSent: Set<UUID> = [],
        toolCalls: [ChatToolCall] = []
    ) -> [ChatRow] {
        let rows = utteranceRows(
            stored: stored, recorded: recorded, excluding: excluded, interrupted: interrupted, waiting: waiting,
            notSent: notSent)
        return merged(rows, toolCalls: toolCalls)
    }

    /// `rows` with a chip for each of `toolCalls`, placed by start time: a
    /// chip goes after the rows that started at or before it (the question
    /// and the "let me check"), before the answer.
    public static func merged(_ rows: [ChatRow], toolCalls: [ChatToolCall]) -> [ChatRow] {
        guard !toolCalls.isEmpty else { return rows }
        let chips = toolCalls.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }.map(ChatRow.init(tool:))
        var result: [ChatRow] = []
        result.reserveCapacity(rows.count + chips.count)
        var next = chips.startIndex
        for row in rows {
            while next < chips.endIndex, chips[next].startedAt < row.startedAt {
                result.append(chips[next])
                next += 1
            }
            result.append(row)
        }
        result += chips[next...]
        return result
    }

    private static func utteranceRows(
        stored: [ChatLine],
        recorded: [UUID: ChatLine],
        excluding excluded: Set<UUID>,
        interrupted: Set<UUID>,
        waiting: Set<UUID>,
        notSent: Set<UUID>
    ) -> [ChatRow] {
        var lines: [ChatLine]
        if recorded.isEmpty {
            lines = stored
        } else {
            lines = stored.map { line in
                guard var newer = recorded[line.id] else { return line }
                // A just-recorded line carries no stored mark: keep it.
                newer.isInterrupted = newer.isInterrupted || line.isInterrupted
                return newer
            }
            let storedIDs = Set(stored.map(\.id))
            lines += recorded.values.filter { !storedIDs.contains($0.id) }
        }
        lines.removeAll(where: \.isBlank)
        lines.sort(by: spokenBefore)

        var rows: [ChatRow] = []
        rows.reserveCapacity(lines.count)
        // Walk backwards so each agent line knows the user line after it.
        var nextUser: ChatLine?
        for line in lines.reversed() {
            if !excluded.contains(line.id) {
                rows.append(
                    ChatRow(
                        id: line.id, role: line.role, text: line.text, startedAt: line.startedAt,
                        isInterrupted: line.role == .agent
                            && (interrupted.contains(line.id) || line.isInterrupted
                                || isInterrupted(line, before: nextUser)),
                        delivery: delivery(of: line, waiting: waiting, notSent: notSent)))
            }
            if line.role == .user {
                nextUser = line
            }
        }
        rows.reverse()
        return rows
    }

    /// Whether `agent` was cut off by `next`, the first user utterance after
    /// it: the user started speaking more than ``interruptionTolerance``
    /// before the reply ended.
    ///
    /// The fallback for rows stored without the interrupted mark
    /// (``ChatLine/isInterrupted``, schema v3): before v3, or by an older
    /// app version on another device. A cut reply is stored ending where it
    /// was heard, which is after the user started the utterance that cut it
    /// (the cut happens when that utterance is final). A reply that played
    /// to the end ends before the user's next utterance starts.
    public static func isInterrupted(_ agent: ChatLine, before next: ChatLine?) -> Bool {
        guard agent.role == .agent, let next, next.role == .user, let ended = agent.endedAt else { return false }
        return next.startedAt < ended.addingTimeInterval(-interruptionTolerance)
    }

    /// The part of a reply's transcript the user has heard: the same share
    /// of its characters as the share of its received audio that has
    /// played, cut back to the last whole word.
    ///
    /// The transcript arrives ahead of the audio, so this keeps the words on
    /// screen in step with the voice instead of racing ahead of it. With no
    /// audio yet (`played` is `nil` or nothing was received) nothing has
    /// been heard.
    public static func revealedText(of transcript: String, played: PlayedItem?) -> String {
        guard let played, played.receivedFrames > 0 else { return "" }
        return revealedText(of: transcript, fraction: Double(played.playedFrames) / Double(played.receivedFrames))
    }

    /// `transcript`'s first `fraction` (`0...1`), cut back to the last whole
    /// word and without trailing whitespace.
    public static func revealedText(of transcript: String, fraction: Double) -> String {
        guard fraction < 1 else { return transcript }
        guard fraction > 0, !transcript.isEmpty else { return "" }
        let characters = Array(transcript)
        let cut = Int((Double(characters.count) * fraction).rounded(.down))
        guard cut < characters.count else { return transcript }
        var end = cut
        if !characters[cut].isWhitespace {
            // Mid-word: drop the word being spoken.
            while end > 0, !characters[end - 1].isWhitespace {
                end -= 1
            }
        }
        while end > 0, characters[end - 1].isWhitespace {
            end -= 1
        }
        return String(characters[..<end])
    }

    private static func delivery(of line: ChatLine, waiting: Set<UUID>, notSent: Set<UUID>) -> ChatRow.Delivery {
        guard line.role == .user else { return .sent }
        if waiting.contains(line.id) { return .waiting }
        if notSent.contains(line.id) { return .notSent }
        return .sent
    }

    /// The order lines are shown in: by start time; at the same instant
    /// the user's line first (they spoke, then Grok answered), then by id
    /// so every device shows the same order.
    static func spokenBefore(_ lhs: ChatLine, _ rhs: ChatLine) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.role != rhs.role { return rank(lhs.role) < rank(rhs.role) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func rank(_ role: UtteranceRole) -> Int {
        switch role {
        case .user: 0
        case .agent: 1
        case .system: 2
        }
    }

    // MARK: Fetching

    /// The stored utterances of conversation `id`, oldest first: what the
    /// transcript view's `@Query` fetches.
    public static func utterances(in id: UUID) -> FetchDescriptor<StoredUtterance> {
        FetchDescriptor(
            predicate: #Predicate { $0.conversation?.id == id },
            sortBy: [SortDescriptor(\.startedAt)]
        )
    }

    /// The most recently started conversation: the one the main screen
    /// shows when none is running.
    public static var latestConversation: FetchDescriptor<Conversation> {
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }
}
