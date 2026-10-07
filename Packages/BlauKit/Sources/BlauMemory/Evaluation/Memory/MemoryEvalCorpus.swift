import BlauPersistence
import CryptoKit
import Foundation

/// A `MemoryEvalDataset` as the memory index sees the synced store: the
/// snapshots `MemoryIndexRebuilder` chunks (conversations, documents with
/// their collection items, facts), the entity graph hybrid retrieval
/// expands through, and the way back from an index chunk to the evidence id
/// it stands for.
///
/// Record ids are derived from the dataset's ids (`uuid(_:_:)`), so chunk
/// ids, and the hashes recorded vectors are keyed by, are the same on every
/// run.
public struct MemoryEvalCorpus: Sendable {
    public let dataset: MemoryEvalDataset
    public let conversations: [ConversationSnapshot]
    public let documents: [DocumentSnapshot]
    public let facts: [FactSnapshot]
    public let entityGraph: MemoryEntityGraph
    /// Document, collection item and fact record ids → evidence id.
    private let evidenceByRecord: [UUID: String]
    /// A conversation and the start of an exchange → the turn's id.
    private let turnByExchange: [ExchangeKey: String]

    private struct ExchangeKey: Hashable {
        var conversation: UUID
        var start: Date
    }

    public init(_ dataset: MemoryEvalDataset) {
        self.dataset = dataset
        var evidence: [UUID: String] = [:]
        var turns: [ExchangeKey: String] = [:]
        var userUtterance: [String: UUID] = [:]

        var conversations: [ConversationSnapshot] = []
        for session in dataset.sessions {
            let id = Self.uuid("session", session.id)
            let topic = session.topic.map {
                ConversationSnapshot.TopicSnapshot(id: Self.uuid("topic", session.id), title: $0)
            }
            var utterances: [ConversationSnapshot.UtteranceSnapshot] = []
            for (index, turn) in session.turns.enumerated() {
                let start = MemoryEvalDataset.startOfTurn(index, in: session)
                let user = Self.uuid("utterance", turn.id + ":user")
                userUtterance[turn.id] = user
                turns[ExchangeKey(conversation: id, start: start)] = turn.id
                utterances.append(.init(id: user, role: .user, text: turn.user, startedAt: start, topicID: topic?.id))
                utterances.append(
                    .init(
                        id: Self.uuid("utterance", turn.id + ":agent"), role: .agent, text: turn.assistant,
                        startedAt: start.addingTimeInterval(60), topicID: topic?.id))
            }
            conversations.append(
                ConversationSnapshot(
                    id: id, startedAt: session.startedAt, topics: topic.map { [$0] } ?? [], utterances: utterances))
        }

        var documents: [DocumentSnapshot] = []
        for document in dataset.documents {
            let id = Self.uuid("document", document.id)
            evidence[id] = document.id
            let items = document.items.enumerated().map { ordinal, item in
                let itemID = Self.uuid("item", item.id)
                evidence[itemID] = item.id
                return DocumentSnapshot.ItemSnapshot(
                    id: itemID, ordinal: ordinal, prompt: item.prompt, referenceAnswer: item.answer,
                    createdAt: document.updatedAt)
            }
            documents.append(
                DocumentSnapshot(
                    id: id, kind: document.kind, title: document.title, body: document.body,
                    updatedAt: document.updatedAt, items: items))
        }

        let entityNames = Dictionary(uniqueKeysWithValues: dataset.entities.map { ($0.id, $0.name) })
        var facts: [FactSnapshot] = []
        var links: [MemoryEntityGraph.FactLink] = []
        for fact in dataset.facts {
            let id = Self.uuid("fact", fact.id)
            evidence[id] = fact.id
            facts.append(
                FactSnapshot(
                    id: id, statement: Self.statement(of: fact, subjectName: fact.subject.flatMap { entityNames[$0] }),
                    validFrom: fact.validFrom, invalidatedAt: fact.invalidatedAt,
                    sourceUtteranceID: fact.source.flatMap { userUtterance[$0] }))
            links.append(
                MemoryEntityGraph.FactLink(
                    id: id, subjectID: fact.subject.map { Self.uuid("entity", $0) }, validFrom: fact.validFrom,
                    invalidatedAt: fact.invalidatedAt))
        }
        let entities = dataset.entities.map { entity in
            MemoryEntityGraph.Entity(
                id: Self.uuid("entity", entity.id), name: entity.name, aliases: entity.aliases,
                type: entity.type.flatMap(MemoryEntityType.init(rawValue:)))
        }

        self.conversations = conversations
        self.documents = documents
        self.facts = facts
        self.entityGraph = MemoryEntityGraph(entities: entities, facts: links)
        self.evidenceByRecord = evidence
        self.turnByExchange = turns
    }

    /// The evidence id a chunk of the index stands for: the turn of an
    /// exchange, the document, the collection item or the fact. `nil` for a
    /// chunk the dataset didn't produce.
    public func evidenceID(of chunk: MemoryChunk) -> String? {
        switch chunk.sourceKind {
        case .conversation:
            turnByExchange[ExchangeKey(conversation: chunk.sourceID, start: chunk.createdAt)]
        case .document, .collectionItem, .fact:
            evidenceByRecord[chunk.sourceID]
        }
    }

    /// The corpus as the index's source provider.
    public var sources: some MemorySourceProvider { Sources(corpus: self) }

    /// A fact as one line, the way `Fact.statement()` writes it: subject
    /// (or "User"), predicate and object.
    public static func statement(of fact: MemoryEvalDataset.Fact, subjectName: String?) -> String {
        [subjectName ?? "User", fact.predicate, fact.object]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A stable record id for a dataset id: the first 16 bytes of SHA-256
    /// over `blau-memory-eval:<namespace>:<id>`, as an RFC 9562 version 8
    /// UUID.
    public static func uuid(_ namespace: String, _ id: String) -> UUID {
        let digest = SHA256.hash(data: Data("blau-memory-eval:\(namespace):\(id)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    struct Sources: MemorySourceProvider {
        let corpus: MemoryEvalCorpus

        func conversationIDs() async throws -> [UUID] {
            corpus.conversations.sorted { $0.startedAt < $1.startedAt }.map(\.id)
        }

        func conversations(_ ids: [UUID]) async throws -> [ConversationSnapshot] {
            let byID = Dictionary(uniqueKeysWithValues: corpus.conversations.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }

        func documents() async throws -> [DocumentSnapshot] { corpus.documents }

        func facts() async throws -> [FactSnapshot] { corpus.facts }
    }
}
