import BlauCore
import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

@Suite("MemoryEntityVocabulary")
struct MemoryEntityVocabularyTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func namesAndAliasesComeFirstForPeopleAndCompaniesThenByRecency() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        context.insert(
            MemoryEntity(name: "Demo Day", type: .event, createdAt: t0, updatedAt: t0.addingTimeInterval(50)))
        context.insert(
            MemoryEntity(
                name: "Paul Graham", type: .person, aliases: ["PG"], createdAt: t0, updatedAt: t0.addingTimeInterval(10)
            ))
        context.insert(MemoryEntity(name: "Blau", type: .product, createdAt: t0, updatedAt: t0.addingTimeInterval(20)))
        context.insert(
            MemoryEntity(name: "retrieval", type: .concept, createdAt: t0, updatedAt: t0.addingTimeInterval(99)))
        context.insert(MemoryEntity(name: "blau", type: .project, createdAt: t0, updatedAt: t0))
        try context.save()

        let vocabulary = MemoryEntityVocabulary(container: { container })
        #expect(await vocabulary.recognitionVocabulary() == ["Blau", "Paul Graham", "PG", "Demo Day", "retrieval"])
        let short = MemoryEntityVocabulary(limit: 2, container: { container })
        #expect(await short.recognitionVocabulary() == ["Blau", "Paul Graham"])
    }

    @Test func noStoreMeansNoVocabulary() async {
        let vocabulary = MemoryEntityVocabulary(container: { nil })
        #expect(await vocabulary.recognitionVocabulary().isEmpty)
    }
}
