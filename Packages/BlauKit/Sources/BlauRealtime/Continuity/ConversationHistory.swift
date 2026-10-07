import BlauCore
import Foundation

/// The recent conversation as it was stored: each user and agent utterance
/// in the order it was first written, with its latest text (a merged
/// utterance, a refined transcript, a reply cut to what was heard).
///
/// The turn orchestrator fills it from every transcript write, and reseeds a
/// new server session from its tail (#39). It keeps only the last
/// ``capacity`` utterances: a reseed needs a handful of exchanges, not the
/// whole conversation, which stays in SwiftData.
struct ConversationHistory: Sendable {
    struct Entry: Sendable, Hashable {
        let id: UUID
        let speaker: Speaker
        var text: String
    }

    /// The utterances kept, oldest first.
    private(set) var entries: [Entry] = []
    private var positions: [UUID: Int] = [:]
    let capacity: Int

    init(capacity: Int = 400) {
        precondition(capacity > 0, "A history keeps at least one utterance")
        self.capacity = capacity
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Adds `utterance`, or updates its text if it was recorded before.
    mutating func record(_ utterance: Utterance) {
        if let position = positions[utterance.id] {
            entries[position].text = utterance.text
            return
        }
        positions[utterance.id] = entries.count
        entries.append(Entry(id: utterance.id, speaker: utterance.speaker, text: utterance.text))
        guard entries.count > capacity else { return }
        // Drop the oldest quarter at once, so trimming stays amortized O(1).
        entries.removeFirst(max(entries.count - capacity, capacity / 4))
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
    }

    mutating func removeAll() {
        entries.removeAll()
        positions.removeAll()
    }

    /// The most recent exchanges, oldest first, for reseeding a session.
    ///
    /// An exchange is a user utterance and the agent utterances after it.
    /// Whole exchanges are taken from the end until `exchanges` of them, or
    /// `characters` of text, are reached; the newest one is always kept (its
    /// texts cut to the budget if they alone exceed it). Blank utterances
    /// and the ones in `excluded` (queued utterances that will be sent as
    /// new turns) are left out.
    func recent(exchanges: Int, characters: Int, excluding excluded: Set<UUID> = []) -> [Entry] {
        guard exchanges > 0, characters > 0 else { return [] }
        let usable = entries.compactMap { entry -> Entry? in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !excluded.contains(entry.id) else { return nil }
            return Entry(id: entry.id, speaker: entry.speaker, text: text)
        }
        // Group into exchanges: a new one starts at every user utterance.
        var groups: [[Entry]] = []
        for entry in usable {
            if entry.speaker == .user || groups.isEmpty {
                groups.append([entry])
            } else {
                groups[groups.count - 1].append(entry)
            }
        }
        var taken: [[Entry]] = []
        var used = 0
        for group in groups.reversed() {
            guard taken.count < exchanges else { break }
            let size = group.reduce(0) { $0 + $1.text.count }
            if used + size > characters {
                if taken.isEmpty {
                    taken.append(Self.fit(group, into: characters))
                }
                break
            }
            used += size
            taken.append(group)
        }
        return taken.reversed().flatMap { $0 }
    }

    /// `group` cut to `characters`: the user's words first, then the reply.
    private static func fit(_ group: [Entry], into characters: Int) -> [Entry] {
        var remaining = characters
        var fitted: [Entry] = []
        for var entry in group where remaining > 0 {
            entry.text = RealtimeInstructions.truncated(entry.text, to: remaining)
            remaining -= entry.text.count
            fitted.append(entry)
        }
        return fitted
    }
}
