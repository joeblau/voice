import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

/// Fixtures for the profile consolidation tests: memory in an in-memory
/// container, with the transcript's `ConversationStore` for topics.
struct ProfileFixture {
    typealias Support = ExtractionTestSupport

    let topics: TopicFixture
    let store: SwiftDataProfileMemoryStore

    var container: ModelContainer { topics.container }

    init() throws {
        topics = try TopicFixture()
        store = SwiftDataProfileMemoryStore(modelContainer: topics.container)
    }

    /// Inserts facts with a fresh context. `subject` `nil` is the user.
    @discardableResult
    func addFacts(
        _ facts: [(subject: String?, predicate: String, object: String)],
        origin: FactOrigin = .extracted,
        validFrom: Date = ExtractionTestSupport.t0,
        createdAt: Date? = nil,
        invalidatedAt: Date? = nil
    ) throws -> [UUID] {
        let context = ModelContext(container)
        var entities: [String: MemoryEntity] = [:]
        for entity in try context.fetch(FetchDescriptor<MemoryEntity>()) {
            entities[entity.name] = entity
        }
        var ids: [UUID] = []
        for fact in facts {
            var subject: MemoryEntity?
            if let name = fact.subject {
                if let known = entities[name] {
                    subject = known
                } else {
                    let entity = MemoryEntity(name: name, type: .organization, createdAt: validFrom)
                    context.insert(entity)
                    entities[name] = entity
                    subject = entity
                }
            }
            let record = Fact(
                subject: subject, predicate: fact.predicate, objectText: fact.object, validFrom: validFrom,
                invalidatedAt: invalidatedAt, origin: origin, createdAt: createdAt)
            context.insert(record)
            ids.append(record.id)
        }
        try context.save()
        return ids
    }

    func addProfileDocument(title: String, body: String, at date: Date = ExtractionTestSupport.t0) throws {
        let context = ModelContext(container)
        context.insert(MemoryDocument(kind: .profile, title: title, body: body, createdAt: date))
        try context.save()
    }

    func addBlock(_ text: String, at date: Date, id: UUID = UUID()) throws {
        let context = ModelContext(container)
        context.insert(ProfileBlock(id: id, text: text, updatedAt: date))
        try context.save()
    }

    func blocks() throws -> [ProfileBlock] {
        try ModelContext(container).fetch(
            FetchDescriptor<ProfileBlock>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    func topicSummary(_ id: UUID) throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<Topic>(predicate: #Predicate { $0.id == id })).first?.summary
    }

    /// A consolidation reply.
    static func reply(profile: String, topics: [String: String] = [:]) -> String {
        let object: [String: Any] = [
            "profile": profile,
            "topics": topics.sorted { $0.key < $1.key }.map { ["topic": $0.key, "summary": $0.value] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `count` distinct sentences, about `count * 60` bytes.
    static func prose(_ count: Int, prefix: String = "Work") -> String {
        (1...max(1, count)).map { "\(prefix): The user mentioned detail number \($0) about their startup." }
            .joined(separator: " ")
    }
}
