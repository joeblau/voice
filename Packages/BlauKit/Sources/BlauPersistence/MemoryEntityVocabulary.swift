import BlauCore
import Foundation
import SwiftData

/// The names memory knows (people, companies, products, projects, places)
/// as a speech recognition vocabulary, so Apple's transcriber spells
/// "Paul Graham" or "Blau" the way the user does (#31).
///
/// Reads `MemoryEntity` names and aliases from the store, the kinds people
/// say by name first, then the most recently updated. Each call reads the
/// store afresh in a context of its own, so it can run on any task.
public struct MemoryEntityVocabulary: RecognitionVocabularySource {
    /// The most terms returned.
    public let limit: Int
    private let container: @Sendable () async -> ModelContainer?

    /// - Parameters:
    ///   - limit: The most terms returned.
    ///   - container: The current store (`PersistenceController`'s
    ///     container is replaced when the iCloud account changes, so it is
    ///     read on every call), or `nil` while the store isn't open.
    public init(
        limit: Int = RecognitionVocabulary.defaultLimit,
        container: @escaping @Sendable () async -> ModelContainer?
    ) {
        self.limit = limit
        self.container = container
    }

    public func recognitionVocabulary() async -> [String] {
        guard let container = await container() else { return [] }
        return Self.terms(in: container, limit: limit)
    }

    /// The vocabulary in `container`.
    static func terms(in container: ModelContainer, limit: Int) -> [String] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<MemoryEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.name)])
        guard let entities = try? context.fetch(descriptor) else { return [] }
        let ordered = entities.enumerated().sorted { lhs, rhs in
            let left = priority(of: lhs.element.type)
            let right = priority(of: rhs.element.type)
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        let names = ordered.flatMap { [$0.element.name] + $0.element.aliasNames }
        return RecognitionVocabulary.normalized(names, limit: limit)
    }

    /// Names people say aloud and a recognizer can't guess come first.
    private static func priority(of type: MemoryEntityType?) -> Int {
        switch type {
        case .person, .organization, .product, .project: 0
        case .place, .event: 1
        case .concept, .other, nil: 2
        }
    }
}
