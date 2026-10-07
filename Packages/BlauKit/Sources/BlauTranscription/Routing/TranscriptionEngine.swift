import Foundation
import Observation
import Synchronization

/// A speech-to-text engine `TranscriberRouter` can run.
public enum TranscriptionEngine: String, CaseIterable, Codable, Hashable, Sendable {
    /// NVIDIA Parakeet realtime EOU through FluidAudio
    /// (`ParakeetStreamingTranscriber`): the primary engine.
    case parakeet
    /// Apple's `SpeechAnalyzer` / `SpeechTranscriber` (`AppleTranscriber`):
    /// the fallback.
    case apple

    public var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .apple: "Apple Speech"
        }
    }
}

/// Which engine the user wants (Settings → Speech Recognition).
public enum TranscriptionEnginePreference: String, CaseIterable, Codable, Hashable, Sendable {
    /// Parakeet whenever it can run; Apple's engine when it can't.
    case automatic
    /// Always Apple's engine (when the device and language support it).
    case apple
}

// MARK: - Persistence

/// Persists the `TranscriptionEnginePreference`.
public protocol TranscriptionPreferencesStore: Sendable {
    func load() -> TranscriptionEnginePreference
    func save(_ preference: TranscriptionEnginePreference)
}

/// Keeps the preference in `UserDefaults`. Per device on purpose: whether
/// Apple's engine suits the user depends on the device's language and
/// models.
public struct UserDefaultsTranscriptionPreferencesStore: TranscriptionPreferencesStore {
    public static let defaultKey = "blau.transcription.engine"

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

    public func load() -> TranscriptionEnginePreference {
        defaults.string(forKey: key).flatMap(TranscriptionEnginePreference.init(rawValue:)) ?? .automatic
    }

    public func save(_ preference: TranscriptionEnginePreference) {
        if preference == .automatic {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(preference.rawValue, forKey: key)
        }
    }
}

/// Keeps the preference in memory. For tests and previews.
public final class InMemoryTranscriptionPreferencesStore: TranscriptionPreferencesStore {
    private let value: Mutex<TranscriptionEnginePreference>

    public init(_ preference: TranscriptionEnginePreference = .automatic) {
        value = Mutex(preference)
    }

    public func load() -> TranscriptionEnginePreference { value.withLock { $0 } }

    public func save(_ preference: TranscriptionEnginePreference) { value.withLock { $0 = preference } }
}

// MARK: - Settings model

/// Settings → Speech Recognition binds to this: the "Use Apple Speech
/// Recognition" toggle and whether Apple's engine supports the user's
/// language. Changes are saved at once and reach the running
/// `TranscriberRouter` through `preferenceChanges()`, which switches engines
/// at the next utterance boundary.
@MainActor
@Observable
public final class TranscriptionSettings {
    /// The saved preference.
    public private(set) var enginePreference: TranscriptionEnginePreference

    /// Whether Apple's engine can run for the user's language, once
    /// `refreshAvailability()` has checked.
    public private(set) var appleAvailability: AppleSpeechAvailability?

    @ObservationIgnored private let store: any TranscriptionPreferencesStore
    @ObservationIgnored private let availabilityCheck: @Sendable () async -> AppleSpeechAvailability
    @ObservationIgnored private var observers: [UUID: AsyncStream<TranscriptionEnginePreference>.Continuation] = [:]

    /// - Parameters:
    ///   - store: Where the preference is saved.
    ///   - availability: Checks Apple's engine for the user's language;
    ///     `AppleSpeechAssets.availability()` in the app.
    public init(
        store: any TranscriptionPreferencesStore,
        availability: @escaping @Sendable () async -> AppleSpeechAvailability = {
            await AppleSpeechAssets.availability()
        }
    ) {
        self.store = store
        self.availabilityCheck = availability
        enginePreference = store.load()
    }

    /// The Settings toggle: always use Apple's engine.
    public var forcesAppleEngine: Bool {
        get { enginePreference == .apple }
        set { setPreference(newValue ? .apple : .automatic) }
    }

    public func setPreference(_ preference: TranscriptionEnginePreference) {
        guard preference != enginePreference else { return }
        enginePreference = preference
        store.save(preference)
        for observer in observers.values {
            observer.yield(preference)
        }
    }

    /// Re-checks Apple's engine for the user's language.
    public func refreshAvailability() async {
        appleAvailability = await availabilityCheck()
    }

    /// The current preference, then every change. For
    /// `TranscriberRouter.followPreferences(_:)`.
    public func preferenceChanges() -> AsyncStream<TranscriptionEnginePreference> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TranscriptionEnginePreference.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(enginePreference)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }
}
