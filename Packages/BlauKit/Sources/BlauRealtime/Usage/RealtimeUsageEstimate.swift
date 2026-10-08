import BlauPersistence
import Foundation
import SwiftData

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

    /// The estimated charge in US dollars at `pricing` (xAI's published
    /// speech-to-speech rates, shared with the performance HUD's estimate):
    /// Grok's speaking time by the minute plus one charge per text input.
    public func cost(at pricing: RealtimePricing = .grokVoice) -> Double {
        agentMinutes * pricing.audioPerMinuteUSD + Double(textInputs) * pricing.textInputUSD
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
