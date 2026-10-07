import BlauPersistence
import Foundation
import SwiftData

/// What xAI charges for a realtime voice session, for the usage estimate in
/// Settings → xAI account.
///
/// Speech to speech bills the audio exchanged by the minute and each text
/// input separately (https://docs.x.ai/developers/pricing). Blau commits the
/// user's verified utterances as **text** (`turn_detection: null`) and gets
/// Grok's reply as audio, so the bill is Grok's speaking time plus one text
/// input per turn.
public struct RealtimePricing: Sendable, Hashable {
    /// Price per minute of audio.
    public var audioPerMinute: Decimal
    /// Price per text input.
    public var perTextInput: Decimal
    /// The model the prices are for.
    public var model: String
    /// When the prices were read from xAI's pricing page.
    public var asOf: String

    public init(audioPerMinute: Decimal, perTextInput: Decimal, model: String, asOf: String) {
        self.audioPerMinute = audioPerMinute
        self.perTextInput = perTextInput
        self.model = model
        self.asOf = asOf
    }

    /// `grok-voice-think-fast-2.0`: $0.08 per minute of audio, $0.004 per
    /// text input (xAI's pricing page, October 2026). Update this with the
    /// pinned realtime model (`AppConfig.xaiRealtimeModel`).
    public static let grokVoiceThinkFast = RealtimePricing(
        audioPerMinute: Decimal(string: "0.08")!,
        perTextInput: Decimal(string: "0.004")!,
        model: "grok-voice-think-fast-2.0",
        asOf: "2026-10")
}

/// How much Blau used Grok's realtime voice in a period, from the stored
/// transcript, and what that likely cost.
///
/// An **estimate**: it counts what was stored (Grok's spoken replies by
/// their audio length, the user's committed utterances as text inputs). A
/// reply interrupted before it was stored, merged turns and xAI's own
/// rounding make the real bill differ a little; the xAI console has the
/// exact figure.
public struct RealtimeUsageEstimate: Sendable, Hashable {
    /// The period counted.
    public var period: DateInterval
    /// Conversations started in the period.
    public var conversations: Int
    /// The user's committed utterances, each sent to Grok as a text input.
    public var textInputs: Int
    /// Grok's speaking time: the summed length of its stored replies.
    public var agentSpeech: Duration

    public init(period: DateInterval, conversations: Int = 0, textInputs: Int = 0, agentSpeech: Duration = .zero) {
        self.period = period
        self.conversations = conversations
        self.textInputs = textInputs
        self.agentSpeech = agentSpeech
    }

    /// Whether nothing was used.
    public var isEmpty: Bool { textInputs == 0 && agentSpeech == .zero }

    /// Grok's speaking time in minutes.
    public var agentMinutes: Double {
        Double(agentSpeech.components.seconds) / 60 + Double(agentSpeech.components.attoseconds) / 6e19
    }

    /// The estimated charge in US dollars at `pricing`.
    public func cost(at pricing: RealtimePricing = .grokVoiceThinkFast) -> Decimal {
        let milliseconds =
            agentSpeech.components.seconds * 1_000 + agentSpeech.components.attoseconds / 1_000_000_000_000_000
        let minutes = Decimal(milliseconds) / 60_000
        return minutes * pricing.audioPerMinute + Decimal(textInputs) * pricing.perTextInput
    }
}

/// Builds a ``RealtimeUsageEstimate`` from the stored transcript.
public enum RealtimeUsageEstimator {
    /// One stored utterance, as the estimate sees it.
    public struct Row: Sendable, Hashable {
        public var role: UtteranceRole
        public var startedAt: Date
        public var endedAt: Date?
        public var isFinal: Bool

        public init(role: UtteranceRole, startedAt: Date, endedAt: Date?, isFinal: Bool) {
            self.role = role
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isFinal = isFinal
        }
    }

    /// The calendar month that contains `date`.
    public static func month(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// The estimate for `rows` (utterances that started in `period`) and
    /// `conversations` started in it.
    ///
    /// Only committed (`isFinal`) utterances count. A user utterance is one
    /// text input; an agent utterance's length (`endedAt - startedAt`, the
    /// duration of the audio Grok sent) is speaking time. System notes count
    /// for nothing.
    public static func estimate(rows: [Row], conversations: Int, period: DateInterval) -> RealtimeUsageEstimate {
        var estimate = RealtimeUsageEstimate(period: period, conversations: conversations)
        for row in rows where row.isFinal && period.contains(row.startedAt) && row.startedAt < period.end {
            switch row.role {
            case .user:
                estimate.textInputs += 1
            case .agent:
                guard let endedAt = row.endedAt, endedAt > row.startedAt else { continue }
                estimate.agentSpeech += .milliseconds(
                    Int64((endedAt.timeIntervalSince(row.startedAt) * 1_000).rounded()))
            case .system:
                continue
            }
        }
        return estimate
    }

    /// The estimate for `period` from the store behind `context`.
    public static func estimate(in context: ModelContext, period: DateInterval) throws -> RealtimeUsageEstimate {
        let start = period.start
        let end = period.end
        let utterances = try context.fetch(
            FetchDescriptor<StoredUtterance>(
                predicate: #Predicate { $0.isFinal && $0.startedAt >= start && $0.startedAt < end }))
        let conversations = try context.fetchCount(
            FetchDescriptor<Conversation>(predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }))
        let rows = utterances.compactMap { utterance -> Row? in
            guard let role = UtteranceRole(rawValue: utterance.roleRaw) else { return nil }
            return Row(
                role: role, startedAt: utterance.startedAt, endedAt: utterance.endedAt, isFinal: utterance.isFinal)
        }
        return estimate(rows: rows, conversations: conversations, period: period)
    }
}
