import Foundation
import Observation
import Synchronization

/// Persists whether Blau learns from conversations (Settings → Memory).
/// `Sendable` so the extraction pipeline can read it off the main actor
/// before every topic.
public protocol MemoryLearningPreferenceStore: Sendable {
    func load() -> Bool
    func save(_ learnsFromConversations: Bool)
}

/// Keeps the preference in `UserDefaults`. On by default: remembering what
/// the user says is what memory is for. The transcript that extraction
/// sends to xAI has already gone to xAI as the conversation itself.
public struct UserDefaultsMemoryLearningPreferenceStore: MemoryLearningPreferenceStore {
    public static let defaultKey = "blau.memory.learnsFromConversations"

    private let suiteName: String?
    private let key: String

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public func save(_ learnsFromConversations: Bool) {
        if learnsFromConversations {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(false, forKey: key)
        }
    }
}

/// Keeps the preference in memory. For tests and previews.
public final class InMemoryMemoryLearningPreferenceStore: MemoryLearningPreferenceStore {
    private let value: Mutex<Bool>

    public init(_ learnsFromConversations: Bool = true) {
        value = Mutex(learnsFromConversations)
    }

    public func load() -> Bool { value.withLock { $0 } }

    public func save(_ learnsFromConversations: Bool) { value.withLock { $0 = learnsFromConversations } }
}

/// Settings → Memory binds to this: the "Learn From Conversations" toggle
/// (#66). Saved at once. Turning it off stops extraction before the next
/// topic and drops the topics still waiting (`changes()` tells the
/// pipeline); what was already learned stays until the user deletes it.
@MainActor
@Observable
public final class MemoryLearningSettings {
    /// Whether closed topics are sent for fact extraction.
    public var learnsFromConversations: Bool {
        didSet {
            guard learnsFromConversations != oldValue else { return }
            store.save(learnsFromConversations)
            for observer in observers.values {
                observer.yield(learnsFromConversations)
            }
        }
    }

    /// Where the preference is saved; the pipeline reads it from here too.
    @ObservationIgnored public let store: any MemoryLearningPreferenceStore
    @ObservationIgnored private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(store: any MemoryLearningPreferenceStore) {
        self.store = store
        learnsFromConversations = store.load()
    }

    /// Every change from now on.
    public func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }
}
