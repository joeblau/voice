import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Fact extraction: entity resolution")
struct EntityResolverTests {
    typealias Support = ExtractionTestSupport

    private let acme = KnownEntity(
        id: UUID(), name: "Acme", type: .organization, aliases: ["Acme Corp"], createdAt: Support.t0)
    private let paul = KnownEntity(id: UUID(), name: "Paul Graham", type: .person, createdAt: Support.t0)

    private func extraction(_ entities: [FactExtraction.Entity], subjects: [String] = []) -> FactExtraction {
        FactExtraction(
            entities: entities,
            facts: subjects.map { FactExtraction.Statement(subject: $0, predicate: "is", object: "x") })
    }

    @Test func matchesAKnownNameOrAliasIgnoringCaseAndDiacritics() async {
        let resolver = EntityResolver(embedder: { nil })
        let resolution = await resolver.resolve(
            extraction([.init(name: "ACME corp", type: .organization), .init(name: "paul graham", type: .person)]),
            known: [acme, paul])
        #expect(resolution.entityID(for: "acme corp") == acme.id)
        #expect(resolution.entityID(for: "Paul Graham") == paul.id)
        #expect(resolution.newEntities.isEmpty)
        #expect(resolution.updates.isEmpty)
        #expect(resolution.matches["ACME corp"] == .alias(acme.id))
    }

    @Test func anExtractedAliasFindsTheEntityAndItsNewNameBecomesAnAlias() async {
        let resolver = EntityResolver(embedder: { nil })
        let resolution = await resolver.resolve(
            extraction([.init(name: "PG", type: .person, aliases: ["Paul Graham"], summary: "Co-founder of YC")]),
            known: [acme, paul])
        #expect(resolution.entityID(for: "PG") == paul.id)
        #expect(
            resolution.updates == [.init(id: paul.id, addedAliases: ["PG"], summary: "Co-founder of YC")])
    }

    @Test func createsAnEntityWhenNothingMatches() async {
        let resolver = EntityResolver(embedder: { nil })
        let resolution = await resolver.resolve(
            extraction(
                [.init(name: "Sequoia", type: .organization, aliases: ["Sequoia Capital", "sequoia"])],
                subjects: ["Sequoia", "Osaka", "user"]),
            known: [acme])
        #expect(resolution.entityID(for: "Sequoia Capital") == resolution.newEntities.first?.id)
        #expect(resolution.entityID(for: "Sequoia") != resolution.entityID(for: "Osaka"))
        #expect(resolution.newEntities.first?.name == "Sequoia")
        #expect(resolution.newEntities.first?.aliases == ["Sequoia Capital"])
        // A subject the reply didn't list becomes an entity of type other.
        #expect(resolution.newEntities.count == 2)
        #expect(resolution.newEntities.last?.name == "Osaka")
        #expect(resolution.newEntities.last?.type == .other)
    }

    @Test func aNameRepeatedInOneReplyResolvesToOneNewEntity() async {
        let resolver = EntityResolver(embedder: { nil })
        let resolution = await resolver.resolve(
            extraction([.init(name: "Blau", type: .product), .init(name: "blau", type: .product, aliases: ["the app"])]
            ),
            known: [])
        #expect(resolution.newEntities.count == 1)
        #expect(resolution.newEntities[0].aliases == ["the app"])
        #expect(resolution.entityID(for: "the app") == resolution.newEntities[0].id)
    }

    @Test func incompatibleTypesNeverMerge() async {
        let apple = KnownEntity(id: UUID(), name: "Apple", type: .organization, createdAt: Support.t0)
        let resolver = EntityResolver(embedder: { nil })
        let concept = await resolver.resolve(extraction([.init(name: "apple", type: .concept)]), known: [apple])
        #expect(concept.entityID(for: "apple") != apple.id)
        #expect(concept.newEntities.count == 1)
        // `other` is compatible with everything.
        let other = await resolver.resolve(extraction([.init(name: "apple", type: .other)]), known: [apple])
        #expect(other.entityID(for: "apple") == apple.id)
    }

    @Test func similarNamesMatchAboveTheThreshold() async {
        let yc = KnownEntity(id: UUID(), name: "Y Combinator", type: .organization, createdAt: Support.t0)
        let embedder = TableEmbedder(table: [
            "y combinator": [1, 0, 0, 0, 0, 0, 0, 0],
            "yc accelerator": [0.95, 0.31, 0, 0, 0, 0, 0, 0],
            "techstars": [0.6, 0.8, 0, 0, 0, 0, 0, 0],
        ])
        let resolver = EntityResolver(similarityThreshold: 0.9, embedder: { embedder })
        let resolution = await resolver.resolve(
            extraction([
                .init(name: "YC accelerator", type: .organization), .init(name: "Techstars", type: .organization),
            ]),
            known: [yc])
        #expect(resolution.entityID(for: "YC accelerator") == yc.id)
        if case .similar(let id, let similarity) = resolution.matches["YC accelerator"] {
            #expect(id == yc.id)
            #expect(similarity >= 0.9)
        } else {
            Issue.record("Expected a similarity match")
        }
        #expect(resolution.updates == [.init(id: yc.id, addedAliases: ["YC accelerator"], summary: nil)])
        #expect(resolution.entityID(for: "Techstars") != yc.id)
        #expect(resolution.newEntities.map(\.name) == ["Techstars"])
    }

    @Test func anEmbedderFailureFallsBackToNames() async {
        struct Failing: TextEmbedder {
            let modelIdentifier = "failing"
            func embed(_ text: String) async throws -> [Float] { throw FakeGeneratorError() }
        }
        let resolver = EntityResolver(embedder: { Failing() })
        let resolution = await resolver.resolve(extraction([.init(name: "Acme", type: .organization)]), known: [acme])
        #expect(resolution.entityID(for: "Acme") == acme.id)
        let created = await resolver.resolve(extraction([.init(name: "Initech", type: .organization)]), known: [acme])
        #expect(created.newEntities.map(\.name) == ["Initech"])
    }

    @Test func duplicateRecordsOfOneNameMergeIntoTheOldest() async {
        let older = KnownEntity(id: UUID(), name: "Acme", type: .organization, createdAt: Support.t0)
        let newer = KnownEntity(
            id: UUID(), name: "acme", type: .organization, createdAt: Support.t0.addingTimeInterval(60))
        let resolver = EntityResolver(embedder: { nil })
        let resolution = await resolver.resolve(
            extraction([.init(name: "Acme", type: .organization)]), known: [newer, older])
        #expect(resolution.entityID(for: "Acme") == older.id)
        #expect(resolution.merges == [.init(canonicalID: older.id, duplicateIDs: [newer.id])])
    }
}
