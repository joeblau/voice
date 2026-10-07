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

/// Settings → Transcription binds to this: the "Use Apple Speech
/// Recognition" toggle, the second pass, the language, and whether Apple's
/// engine supports that language. Changes are saved at once. The engine
/// choice reaches the running `TranscriberRouter` through
/// `preferenceChanges()`, which switches engines at the next utterance
/// boundary; the second pass is read for every utterance
/// (`isSecondPassEnabled()`).
@MainActor
@Observable
public final class TranscriptionSettings {
    /// The saved preference.
    public private(set) var enginePreference: TranscriptionEnginePreference

    /// The saved second-pass and language choices.
    public private(set) var options: TranscriptionOptions

    /// Whether Apple's engine can run for the user's language, once
    /// `refreshAvailability()` has checked.
    public private(set) var appleAvailability: AppleSpeechAvailability?

    @ObservationIgnored private let store: any TranscriptionPreferencesStore
    @ObservationIgnored private let optionsStore: any TranscriptionOptionsStore
    @ObservationIgnored private let availabilityCheck: @Sendable () async -> AppleSpeechAvailability
    @ObservationIgnored private var observers: [UUID: AsyncStream<TranscriptionEnginePreference>.Continuation] = [:]
    @ObservationIgnored private nonisolated let secondPass: SecondPassSwitch

    /// - Parameters:
    ///   - store: Where the engine preference is saved.
    ///   - options: Where the second-pass and language choices are saved.
    ///     The app passes a `UserDefaultsTranscriptionOptionsStore`.
    ///   - availability: Checks Apple's engine for the user's language;
    ///     `AppleSpeechAssets.availability(for:)` with the chosen language's
    ///     locale in the app.
    public init(
        store: any TranscriptionPreferencesStore,
        options: any TranscriptionOptionsStore = InMemoryTranscriptionOptionsStore(),
        availability: @escaping @Sendable () async -> AppleSpeechAvailability = {
            await AppleSpeechAssets.availability()
        }
    ) {
        self.store = store
        self.optionsStore = options
        self.availabilityCheck = availability
        enginePreference = store.load()
        let loaded = options.load()
        self.options = loaded
        secondPass = SecondPassSwitch(loaded.refinesWithSecondPass)
    }

    /// The Settings toggle: always use Apple's engine.
    public var forcesAppleEngine: Bool {
        get { enginePreference == .apple }
        set { setPreference(newValue ? .apple : .automatic) }
    }

    /// The engine the router should follow: the user's preference, or
    /// Apple's when the chosen language is one Parakeet can't transcribe.
    public var effectiveEnginePreference: TranscriptionEnginePreference {
        options.language.requiresAppleEngine ? .apple : enginePreference
    }

    public func setPreference(_ preference: TranscriptionEnginePreference) {
        guard preference != enginePreference else { return }
        let before = effectiveEnginePreference
        enginePreference = preference
        store.save(preference)
        notifyIfEffectiveChanged(from: before)
    }

    /// The Settings toggle: re-transcribe finished utterances with the
    /// second pass.
    public var refinesWithSecondPass: Bool {
        get { options.refinesWithSecondPass }
        set { updateOptions { $0.refinesWithSecondPass = newValue } }
    }

    /// The Settings picker: the language spoken. Choosing a language other
    /// than English switches the router to Apple's engine.
    public var language: TranscriptionLanguage {
        get { options.language }
        set { updateOptions { $0.language = newValue } }
    }

    /// Whether the second pass should refine the next utterance. Safe from
    /// any thread: `SecondPassTranscriber`'s `isEnabled` reads it, together
    /// with the `secondPassASR` flag, for every utterance.
    public nonisolated func isSecondPassEnabled() -> Bool {
        secondPass.isOn
    }

    private func updateOptions(_ change: (inout TranscriptionOptions) -> Void) {
        var updated = options
        change(&updated)
        guard updated != options else { return }
        let before = effectiveEnginePreference
        let languageChanged = updated.language != options.language
        options = updated
        secondPass.set(updated.refinesWithSecondPass)
        optionsStore.save(updated)
        if languageChanged {
            // The old language's availability no longer applies.
            appleAvailability = nil
        }
        notifyIfEffectiveChanged(from: before)
    }

    private func notifyIfEffectiveChanged(from before: TranscriptionEnginePreference) {
        let effective = effectiveEnginePreference
        guard effective != before else { return }
        for observer in observers.values {
            observer.yield(effective)
        }
    }

    /// Re-checks Apple's engine for the user's language.
    ///
    /// A check that finishes after the language changed (or after its task
    /// was cancelled) is dropped, so a slow check for the old language can't
    /// overwrite the new language's result.
    public func refreshAvailability() async {
        let language = options.language
        let availability = await availabilityCheck()
        guard !Task.isCancelled, options.language == language else { return }
        appleAvailability = availability
    }

    /// The current effective preference (`effectiveEnginePreference`),
    /// then every change. For `TranscriberRouter.followPreferences(_:)`.
    public func preferenceChanges() -> AsyncStream<TranscriptionEnginePreference> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TranscriptionEnginePreference.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(effectiveEnginePreference)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    /// The second-pass choice, readable off the main actor.
    private final class SecondPassSwitch: Sendable {
        private let storage: Mutex<Bool>
        init(_ isOn: Bool) { storage = Mutex(isOn) }
        var isOn: Bool { storage.withLock { $0 } }
        func set(_ isOn: Bool) { storage.withLock { $0 = isOn } }
    }
}
