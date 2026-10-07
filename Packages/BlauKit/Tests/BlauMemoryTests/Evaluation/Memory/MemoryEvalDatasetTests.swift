import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Memory eval dataset")
struct MemoryEvalDatasetTests {
    typealias Dataset = MemoryEvalDataset

    // MARK: - The committed set

    @Test func theCommittedSetIsWellFormed() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        #expect(dataset.name == "blau-memory-eval")
        #expect(dataset.userName == "Jordan")
        // Every type #70 asks for, with enough questions to mean something.
        for type in Dataset.QuestionType.allCases {
            #expect(dataset.questions(ofTypes: [type]).count >= 20, "\(type) has too few questions")
        }
        // Several months of multi-session conversation and knowledge docs.
        #expect(dataset.sessions.count >= 60)
        #expect(dataset.documents.contains { $0.kind == .collection && $0.items.count >= 40 })
        #expect(dataset.facts.contains { $0.invalidatedAt != nil })
        // Every knowledge update has a superseded record to rank below.
        #expect(dataset.questions(ofTypes: [.knowledgeUpdate]).allSatisfy { !$0.stale.isEmpty })
        // Multi-hop questions need at least two pieces.
        #expect(dataset.questions(ofTypes: [.multiHop]).allSatisfy { $0.evidence.count >= 2 })
    }

    /// Every evidence id is a chunk of the index built from the set, and
    /// every chunk maps back to a record.
    @Test func everyRecordBecomesChunksAndBack() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        let evaluator = MemoryEvaluator(dataset: dataset)
        let index = try await evaluator.buildIndex(embedder: nil)
        let chunks = try await index.chunksNeedingEmbedding(modelVersion: "test", limit: 100_000)
        let mapped = chunks.map { evaluator.corpus.evidenceID(of: $0) }
        #expect(mapped.allSatisfy { $0 != nil }, "a chunk maps to no record")
        let indexed = Set(mapped.compactMap { $0 })
        var records = Set(dataset.sessions.flatMap(\.turns).map(\.id))
        records.formUnion(dataset.documents.map(\.id))
        records.formUnion(dataset.documents.flatMap(\.items).map(\.id))
        records.formUnion(dataset.facts.map(\.id))
        #expect(indexed == records)
    }

    @Test func factsReadLikeFactStatements() throws {
        let dataset = try MemoryEvalFixtures.dataset()
        let corpus = MemoryEvalCorpus(dataset)
        let alexJob = try #require(corpus.facts.first { $0.id == MemoryEvalCorpus.uuid("fact", "f-alex-job-2") })
        #expect(alexJob.statement.hasPrefix("Alex Moreno works as a senior park designer"))
        #expect(alexJob.sourceUtteranceID == MemoryEvalCorpus.uuid("utterance", "n-003:user"))
        let allergy = try #require(corpus.facts.first { $0.id == MemoryEvalCorpus.uuid("fact", "pf-004") })
        #expect(allergy.statement.hasPrefix("User is allergic to shellfish"))
        // The graph links facts to their subjects.
        let alex = MemoryEvalCorpus.uuid("entity", "alex")
        #expect(corpus.entityGraph.entities(mentionedIn: "what does Alex do") == [alex])
        #expect(corpus.entityGraph.facts(about: alex).contains { $0.id == alexJob.id })
    }

    @Test func idsAreStable() {
        #expect(MemoryEvalCorpus.uuid("fact", "pf-001") == MemoryEvalCorpus.uuid("fact", "pf-001"))
        #expect(MemoryEvalCorpus.uuid("fact", "pf-001") != MemoryEvalCorpus.uuid("document", "pf-001"))
        // Pinned: recorded vectors are keyed by key texts, which don't hold
        // ids, but chunk ids in reports do.
        #expect(MemoryEvalCorpus.uuid("fact", "pf-001").uuidString == "B3AC5D81-BD2E-81A5-9347-23CFE6C85C24")
    }

    @Test func turnsAreTwoMinutesApart() throws {
        let dataset = try Dataset.small()
        let corpus = MemoryEvalCorpus(dataset)
        let session = try #require(corpus.conversations.first)
        let times = session.utterances.map(\.startedAt).sorted()
        #expect(times.count == 4)
        #expect(times[1].timeIntervalSince(times[0]) == 60)
        #expect(times[2].timeIntervalSince(times[0]) == 120)
    }

    // MARK: - Decoding

    @Test func datesAreISO8601OrCalendarDays() throws {
        #expect(Dataset.parseDate("2026-09-15T19:00:00Z") == Date(timeIntervalSince1970: 1_789_498_800))
        #expect(Dataset.parseDate("2026-09-15") == Date(timeIntervalSince1970: 1_789_473_600))
        #expect(Dataset.parseDate("15 September") == nil)
    }

    @Test func evidenceAlternativesSplitOnBars() throws {
        let json = Data(#"["a|b", "c", " d | e "]"#.utf8)
        let evidence = try JSONDecoder().decode([Dataset.Evidence].self, from: json)
        #expect(evidence.map(\.alternatives) == [["a", "b"], ["c"], ["d", "e"]])
        #expect(String(decoding: try JSONEncoder().encode(evidence[0]), as: UTF8.self) == #""a|b""#)
    }

    @Test func loadsADirectoryOfParts() throws {
        let directory = try IndexTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            #"{"name": "tiny", "consent": "synthetic", "now": "2026-01-10T12:00:00Z", "timeZone": "UTC"}"#,
            to: directory, "manifest.json")
        try write(
            #"{"sessions": [{"id": "s", "startedAt": "2026-01-02", "turns": [{"id": "t", "user": "Hi", "assistant": "Hello"}]}]}"#,
            to: directory, "a.json")
        try write(
            #"{"questions": [{"id": "q", "type": "single-fact", "question": "Q?", "answer": "A.", "evidence": ["t"]}]}"#,
            to: directory, "b.json")
        let dataset = try Dataset.load(directory: directory)
        #expect(dataset.sessions.map(\.id) == ["s"])
        #expect(dataset.questions.map(\.id) == ["q"])
        #expect(dataset.userName == "the user")
    }

    @Test func aDirectoryWithoutManifestIsRejected() throws {
        let directory = try IndexTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: Dataset.LoadError.self) { try Dataset.load(directory: directory) }
    }

    @Test func limitingKeepsTheCorpus() throws {
        let dataset = try Dataset.small()
        let limited = dataset.limited(toTypes: [.temporal, .abstention], first: 1)
        #expect(limited.questions.map(\.id) == ["q-tr"])
        #expect(limited.sessions == dataset.sessions)
        #expect(dataset.limited(toTypes: nil, ids: ["q-ab"]).questions.map(\.id) == ["q-ab"])
    }

    // MARK: - Validation

    @Test(arguments: Invalid.allCases)
    func invalidDatasetsAreRejected(_ invalid: Invalid) throws {
        let small = try Dataset.small()
        var manifest = small.manifest
        var entities = small.entities
        var sessions = small.sessions
        var documents = small.documents
        var facts = small.facts
        var questions = small.questions
        switch invalid {
        case .noConsent: manifest.consent = " "
        case .unknownTimeZone: manifest.timeZone = "Mars/Olympus"
        case .duplicateRecord: documents[0].id = "t1"
        case .duplicateQuestion: questions[1].id = questions[0].id
        case .emptySession: sessions[0].turns = []
        case .blankTurn: sessions[0].turns[0].assistant = " "
        case .unknownSubject: facts[0].subject = "nobody"
        case .unknownSource: facts[1].source = "t9"
        case .invalidValidity: facts[0].invalidatedAt = facts[0].validFrom
        case .afterNow: documents[0].updatedAt = manifest.now.addingTimeInterval(1)
        case .noEvidence: questions[0].evidence = []
        case .abstentionWithEvidence: questions[4].evidence = [.init(["d1"])]
        case .unknownEvidence: questions[0].evidence = [.init(["nope"])]
        case .staleOutsideUpdates: questions[0].stale = ["f1"]
        case .staleIsEvidence: questions[2].stale = ["f2"]
        case .duplicateEntity: entities.append(entities[0])
        }
        #expect(throws: Dataset.LoadError.self) {
            try Dataset(
                manifest: manifest, entities: entities, sessions: sessions, documents: documents, facts: facts,
                questions: questions)
        }
    }

    enum Invalid: CaseIterable, Sendable {
        case noConsent, unknownTimeZone, duplicateRecord, duplicateQuestion, emptySession, blankTurn
        case unknownSubject, unknownSource, invalidValidity, afterNow, noEvidence, abstentionWithEvidence
        case unknownEvidence, staleOutsideUpdates, staleIsEvidence, duplicateEntity
    }

    private func write(_ text: String, to directory: URL, _ name: String) throws {
        try Data(text.utf8).write(to: directory.appending(path: name))
    }
}
