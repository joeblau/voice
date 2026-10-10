import BlauCore
import BlauPersistence
import Foundation

/// One finished utterance as the chat transcript (#42) shows it: who said
/// what, and when.
///
/// A plain value copied out of a `StoredUtterance` (or a just-recorded
/// `BlauCore.Utterance`), so building the transcript's rows never touches
/// SwiftData and runs the same on macOS tests as in the app.
public struct ChatLine: Identifiable, Hashable, Sendable {
    /// The utterance's id (the same in the pipeline and the store).
    public var id: UUID
    public var role: UtteranceRole
    public var text: String
    /// Wall-clock time the speech started.
    public var startedAt: Date
    /// Wall-clock time the speech ended. For an agent reply cut short, the
    /// end of what was heard.
    public var endedAt: Date?
    /// The store says the speech was cut short (`StoredUtterance.isInterrupted`,
    /// schema v3, #160): an agent reply the user interrupted. Synced, so it
    /// holds after a relaunch and on the user's other devices.
    public var isInterrupted: Bool

    public init(
        id: UUID, role: UtteranceRole, text: String, startedAt: Date, endedAt: Date? = nil,
        isInterrupted: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isInterrupted = isInterrupted
    }

    /// The line for a stored utterance, or `nil` when its role was written
    /// by a newer version of Blau and isn't known to this one.
    public init?(_ stored: StoredUtterance) {
        guard let role = stored.role else { return nil }
        self.init(
            id: stored.id, role: role, text: stored.text, startedAt: stored.startedAt, endedAt: stored.endedAt,
            isInterrupted: stored.isInterrupted)
    }

    /// The line for a pipeline utterance, ended where its speech ends (as
    /// `StoredUtterance(_:source:)` stores it).
    public init(_ utterance: Utterance) {
        self.init(
            id: utterance.id, role: UtteranceRole(utterance.speaker), text: utterance.text,
            startedAt: utterance.startedAt,
            endedAt: utterance.startedAt.addingTimeInterval(utterance.duration.timeInterval))
    }

    /// Whether the text is empty or only whitespace.
    public var isBlank: Bool { text.allSatisfy(\.isWhitespace) }
}
