import BlauPersistence
import Foundation
import SwiftData
import Testing

/// A fixed reference date so tests never read the wall clock.
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func makeContext() throws -> ModelContext {
    ModelContext(try BlauModelContainer.makeInMemory())
}

private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
    try context.fetchCount(FetchDescriptor<T>())
}

@Suite("SchemaV2 memory models: create, fetch and delete")
struct MemoryModelCRUDTests {
    @Test func aCollectionDocumentRoundTripsWithItsItemsInOrder() throws {
        let context = try makeContext()
        let document = MemoryDocument(
            kind: .collection, title: "YC interview", body: "Questions partners ask.", createdAt: t0)
        context.insert(document)
        let prompts = ["Why now?", "What are you building?", "Who are your users?"]
        for (ordinal, prompt) in [(2, prompts[2]), (0, prompts[1]), (1, prompts[0])] {
            context.insert(
                CollectionItem(
                    document: document, ordinal: ordinal, prompt: prompt,
                    referenceAnswer: ordinal == 0 ? "A voice app that remembers." : nil, createdAt: t0))
        }
        try context.save()

        let fetched = try #require(try ModelContext(context.container).fetch(FetchDescriptor<MemoryDocument>()).first)
        #expect(fetched.kind == .collection)
        #expect(fetched.title == "YC interview")
        #expect(fetched.body == "Questions partners ask.")
        #expect(fetched.createdAt == t0)
        #expect(fetched.updatedAt == t0)
        #expect(
            fetched.contentHash == MemoryDocument.contentHash(title: "YC interview", body: "Questions partners ask."))
        #expect(fetched.isContentHashCurrent)
        #expect(
            fetched.orderedCollectionItems.map(\.prompt) == [
                "What are you building?", "Why now?", "Who are your users?",
            ])
        let first = try #require(fetched.orderedCollectionItems.first)
        #expect(first.referenceAnswer == "A voice app that remembers.")
        #expect(first.document?.id == document.id)
        #expect(first.practiceCount == 0)
        #expect(first.lastPracticedAt == nil)
        #expect(first.score == nil)
    }

    @Test func deletingADocumentDeletesItsItems() throws {
        let context = try makeContext()
        let kept = MemoryDocument(kind: .collection, title: "Kept", createdAt: t0)
        let deleted = MemoryDocument(kind: .collection, title: "Deleted", createdAt: t0)
        for document in [kept, deleted] {
            context.insert(document)
            context.insert(CollectionItem(document: document, ordinal: 0, prompt: "Q", createdAt: t0))
        }
        try context.save()

        context.delete(deleted)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<MemoryDocument>()).map(\.title) == ["Kept"])
        #expect(try context.fetch(FetchDescriptor<CollectionItem>()).map(\.document?.title) == ["Kept"])
    }

    @Test func deletingAnItemKeepsItsDocument() throws {
        let context = try makeContext()
        let document = MemoryDocument(kind: .collection, title: "List", createdAt: t0)
        context.insert(document)
        let item = CollectionItem(document: document, ordinal: 0, prompt: "Q", createdAt: t0)
        context.insert(item)
        try context.save()

        context.delete(item)
        try context.save()
        #expect(try count(MemoryDocument.self, in: context) == 1)
        #expect(document.collectionItems?.isEmpty == true)
    }

    @Test func anEntityRoundTripsWithItsFacts() throws {
        let context = try makeContext()
        let acme = MemoryEntity(
            name: "Acme", type: .organization, aliases: ["Acme Inc", "ACME"], summary: "The user's startup",
            createdAt: t0)
        context.insert(acme)
        let utteranceID = UUID()
        context.insert(
            Fact(
                subject: acme, predicate: "raised", objectText: "a $2M seed round", sourceUtteranceID: utteranceID,
                validFrom: t0 + 86_400, confidence: 0.8, origin: .extracted, createdAt: t0 + 90_000))
        context.insert(
            Fact(subject: acme, predicate: "is based in", objectText: "Berlin", validFrom: t0, origin: .user))
        try context.save()

        let fetched = try #require(try ModelContext(context.container).fetch(FetchDescriptor<MemoryEntity>()).first)
        #expect(fetched.name == "Acme")
        #expect(fetched.type == .organization)
        #expect(fetched.aliasNames == ["Acme Inc"])
        #expect(fetched.summary == "The user's startup")
        #expect(fetched.orderedFacts.map(\.objectText) == ["Berlin", "a $2M seed round"])
        let raised = try #require(fetched.orderedFacts.last)
        #expect(raised.subject?.id == acme.id)
        #expect(raised.sourceUtteranceID == utteranceID)
        #expect(raised.validFrom == t0 + 86_400)
        #expect(raised.createdAt == t0 + 90_000)
        #expect(raised.confidence == 0.8)
        #expect(raised.origin == .extracted)
        #expect(raised.isCurrent)
        #expect(fetched.orderedFacts.first?.origin == .user)
        #expect(fetched.orderedFacts.first?.createdAt == t0)
    }

    @Test func deletingAnEntityDeletesItsFactsButNotFactsAboutTheUser() throws {
        let context = try makeContext()
        let entity = MemoryEntity(name: "Old job", type: .organization, createdAt: t0)
        context.insert(entity)
        context.insert(
            Fact(subject: entity, predicate: "employed", objectText: "the user", validFrom: t0, origin: .user))
        context.insert(Fact(predicate: "prefers", objectText: "morning meetings", validFrom: t0, origin: .extracted))
        try context.save()

        context.delete(entity)
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<Fact>())
        #expect(remaining.map(\.objectText) == ["morning meetings"])
        #expect(remaining.first?.subject == nil)
    }

    @Test func deletingAFactKeepsItsEntity() throws {
        let context = try makeContext()
        let entity = MemoryEntity(name: "Ada", type: .person, createdAt: t0)
        context.insert(entity)
        let fact = Fact(subject: entity, predicate: "is", objectText: "an advisor", validFrom: t0, origin: .extracted)
        context.insert(fact)
        try context.save()

        context.delete(fact)
        try context.save()
        #expect(try count(MemoryEntity.self, in: context) == 1)
        #expect(entity.facts?.isEmpty == true)
    }

    @Test func currentFactsAreQueryableByTheirValidityFields() throws {
        let context = try makeContext()
        let old = Fact(predicate: "works at", objectText: "Stripe", validFrom: t0, origin: .extracted)
        old.invalidate(at: t0 + 1_000)
        context.insert(old)
        context.insert(Fact(predicate: "works at", objectText: "Acme", validFrom: t0 + 1_000, origin: .extracted))
        try context.save()

        let current = FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil })
        #expect(try context.fetch(current).map(\.objectText) == ["Acme"])

        let date = t0 + 500
        let asOf = FetchDescriptor<Fact>(
            predicate: #Predicate { fact in
                fact.validFrom <= date && (fact.invalidatedAt == nil || fact.invalidatedAt! > date)
            })
        #expect(try context.fetch(asOf).map(\.objectText) == ["Stripe"])
    }

    @Test func theLatestProfileBlockWinsWhenSyncLeavesDuplicates() throws {
        let context = try makeContext()
        let older = ProfileBlock(text: "Founder.", updatedAt: t0)
        let newer = ProfileBlock(text: "Founder of Acme, raising a seed round.", updatedAt: t0 + 60)
        let other = ProfileBlock(key: "persona", text: "Be brief.", updatedAt: t0 + 120)
        for block in [older, newer, other] { context.insert(block) }
        try context.save()

        #expect(try context.fetch(ProfileBlock.latest()).map(\.text) == ["Founder of Acme, raising a seed round."])
        #expect(try context.fetch(ProfileBlock.latest(key: "persona")).map(\.text) == ["Be brief."])
        #expect(try context.fetch(ProfileBlock.latest(key: "missing")).isEmpty)

        older.update(text: "Founder of Acme.", at: t0 + 600)
        try context.save()
        #expect(try context.fetch(ProfileBlock.latest()).map(\.id) == [older.id])
    }

    @Test func profileBlockTiesBreakTheSameWayEverywhere() throws {
        let context = try makeContext()
        let ids = (0..<16).map { _ in UUID() }
        for id in ids { context.insert(ProfileBlock(id: id, text: "same time", updatedAt: t0)) }
        try context.save()
        let picked = try context.fetch(ProfileBlock.latest()).map(\.id)
        #expect(picked == [ids.min()].compactMap { $0 })
    }
}

@Suite("SchemaV2 memory models: behavior")
struct MemoryModelBehaviorTests {
    @Test func rawValuesMatchTheDocumentedStrings() {
        #expect(DocumentKind.allCases.map(\.rawValue) == ["note", "company", "profile", "collection"])
        #expect(
            MemoryEntityType.allCases.map(\.rawValue)
                == ["person", "organization", "place", "product", "project", "event", "concept", "other"])
        #expect(FactOrigin.allCases.map(\.rawValue) == ["extracted", "user"])
    }

    @Test func unknownRawValuesFromNewerVersionsReadAsNil() {
        let document = MemoryDocument(kind: .note, title: "", createdAt: t0)
        document.kindRaw = "spreadsheet"
        #expect(document.kind == nil)
        let entity = MemoryEntity(name: "X", type: .other, createdAt: t0)
        entity.typeRaw = "animal"
        #expect(entity.type == nil)
        let fact = Fact(predicate: "p", objectText: "o", validFrom: t0, origin: .user)
        fact.originRaw = "imported"
        #expect(fact.origin == nil)
    }

    @Test func updatingADocumentRefreshesTheHashOnlyWhenTheTextChanges() {
        let document = MemoryDocument(kind: .company, title: "Acme", body: "Voice notes.", createdAt: t0)
        let original = document.contentHash
        #expect(original.count == 64)
        #expect(original.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        #expect(!document.update(title: "Acme", body: "Voice notes.", at: t0 + 10))
        #expect(document.updatedAt == t0)
        #expect(document.contentHash == original)

        #expect(document.update(body: "Voice notes that remember.", at: t0 + 20))
        #expect(document.title == "Acme")
        #expect(document.body == "Voice notes that remember.")
        #expect(document.updatedAt == t0 + 20)
        #expect(document.contentHash != original)
        #expect(document.isContentHashCurrent)

        #expect(document.update(title: "Acme Inc", at: t0 + 30))
        #expect(document.body == "Voice notes that remember.")
        #expect(
            document.contentHash == MemoryDocument.contentHash(title: "Acme Inc", body: "Voice notes that remember."))
    }

    @Test func theContentHashIsStableAndUnambiguous() {
        // Pinned: every device and app version must compute the same hash, or
        // the indexer re-embeds everything.
        // SHA-256 of "0:" and of "4:AcmeVoice notes." (`shasum -a 256`).
        #expect(
            MemoryDocument.contentHash(title: "", body: "")
                == "ba768b331fd86cec803be04e56ab2b3d4c0e98ef4ee4fcd4e72ad7cce61a1d1f")
        #expect(
            MemoryDocument.contentHash(title: "Acme", body: "Voice notes.")
                == "6bc1d9e37e21b39bcfb5f57af4dd28392877f7b2b441ac50f65939704858c04b")
        #expect(
            MemoryDocument.contentHash(title: "ab", body: "c") != MemoryDocument.contentHash(title: "a", body: "bc"))
        #expect(MemoryDocument.contentHash(title: "a", body: "b") == MemoryDocument.contentHash(title: "a", body: "b"))
        #expect(MemoryDocument.contentHash(title: "é", body: "") != MemoryDocument.contentHash(title: "e", body: ""))
    }

    @Test func recordingPracticeCountsAttemptsAndKeepsTheLatestScore() {
        let item = CollectionItem(ordinal: 0, prompt: "What are you building?", createdAt: t0)
        item.recordPractice(at: t0 + 60, score: 0.4)
        item.recordPractice(at: t0 + 120)
        #expect(item.practiceCount == 2)
        #expect(item.lastPracticedAt == t0 + 120)
        #expect(item.score == 0.4)
        item.recordPractice(at: t0 + 180, score: 1.7)
        #expect(item.score == 1)
        item.recordPractice(at: t0 + 240, score: -.infinity)
        #expect(item.score == 1)
        #expect(item.practiceCount == 4)
    }

    @Test func aliasesAreStoredAsAJSONArrayAndNormalized() {
        let entity = MemoryEntity(
            name: "Paul Graham", type: .person, aliases: [" PG ", "pg", "", "paul graham", "Paul/G"], createdAt: t0)
        #expect(entity.aliasNames == ["PG", "Paul/G"])
        #expect(entity.aliases == #"["PG","Paul/G"]"#)

        entity.aliasNames = ["Graham", "GRAHAM", "Pàul Graham"]
        #expect(entity.aliasNames == ["Graham"])

        entity.aliases = "not json"
        #expect(entity.aliasNames == [])
        #expect(MemoryEntity(name: "X", type: .other, createdAt: t0).aliases == "[]")
    }

    @Test func entitiesMatchTheirNameAndAliasesLoosely() {
        let entity = MemoryEntity(name: "Zoë Chen", type: .person, aliases: ["ZC"], createdAt: t0)
        #expect(entity.matches("zoe chen"))
        #expect(entity.matches("  ZOË CHEN "))
        #expect(entity.matches("zc"))
        #expect(!entity.matches("Zoe"))
        #expect(!entity.matches("   "))
    }

    @Test func factsAreValidForAHalfOpenInterval() {
        let fact = Fact(predicate: "works at", objectText: "Stripe", validFrom: t0, origin: .extracted)
        #expect(fact.isCurrent)
        #expect(!fact.isValid(at: t0 - 1))
        #expect(fact.isValid(at: t0))
        #expect(fact.isValid(at: .distantFuture))

        fact.invalidate(at: t0 + 100)
        #expect(!fact.isCurrent)
        #expect(fact.isValid(at: t0 + 99))
        #expect(!fact.isValid(at: t0 + 100))

        // Invalidation converges on the earliest date.
        fact.invalidate(at: t0 + 200)
        #expect(fact.invalidatedAt == t0 + 100)
        fact.invalidate(at: t0 + 50)
        #expect(fact.invalidatedAt == t0 + 50)
    }

    @Test func confidenceIsClampedToTheUnitInterval() {
        #expect(Fact(predicate: "p", objectText: "o", validFrom: t0, origin: .user).confidence == 1)
        #expect(Fact(predicate: "p", objectText: "o", validFrom: t0, confidence: 1.4, origin: .user).confidence == 1)
        #expect(Fact(predicate: "p", objectText: "o", validFrom: t0, confidence: -2, origin: .user).confidence == 0)
        #expect(Fact(predicate: "p", objectText: "o", validFrom: t0, confidence: .nan, origin: .user).confidence == 1)
    }

    @Test func factsReadAsOneLine() {
        let acme = MemoryEntity(name: "Acme", type: .organization, createdAt: t0)
        #expect(
            Fact(subject: acme, predicate: " raised ", objectText: "a seed round", validFrom: t0, origin: .user)
                .statement() == "Acme raised a seed round")
        #expect(
            Fact(predicate: "prefers", objectText: "short answers", validFrom: t0, origin: .user)
                .statement(userName: "Joe") == "Joe prefers short answers")
        #expect(Fact(predicate: "", objectText: "x", validFrom: t0, origin: .user).statement() == "User x")
    }

    @Test func profileBlocksTrackTheirBudget() {
        let block = ProfileBlock(text: "", updatedAt: t0)
        #expect(block.key == ProfileBlock.userKey)
        #expect(block.key == "user")
        #expect(ProfileBlock.tokenBudget == 1_500)
        #expect(block.approximateTokenCount == 0)
        #expect(!block.update(text: "", at: t0 + 1))
        #expect(block.updatedAt == t0)

        #expect(block.update(text: String(repeating: "a", count: 6_000), at: t0 + 2))
        #expect(block.updatedAt == t0 + 2)
        #expect(block.approximateTokenCount == 1_500)
        #expect(!block.isOverBudget)
        block.update(text: String(repeating: "a", count: 6_001), at: t0 + 3)
        #expect(block.approximateTokenCount == 1_501)
        #expect(block.isOverBudget)
    }

    @Test func defaultsMatchTheSchemaContract() {
        let document = MemoryDocument(kind: .note, title: "Note", createdAt: t0)
        #expect(document.body == "")
        #expect(document.updatedAt == t0)
        #expect(document.collectionItems?.isEmpty == true)
        let entity = MemoryEntity(name: "X", type: .concept, createdAt: t0)
        #expect(entity.updatedAt == t0)
        #expect(entity.summary == nil)
        #expect(entity.facts?.isEmpty == true)
        let fact = Fact(predicate: "p", objectText: "o", validFrom: t0 + 5, origin: .extracted)
        #expect(fact.createdAt == t0 + 5)
        #expect(fact.subject == nil)
        #expect(fact.sourceUtteranceID == nil)
        #expect(fact.invalidatedAt == nil)
    }
}
