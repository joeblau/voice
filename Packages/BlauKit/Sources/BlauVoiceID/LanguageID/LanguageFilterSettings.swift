import Foundation
import Observation
import Synchronization

/// The language filter's settings (Settings → Voice ID → Languages, #50).
public struct LanguageFilterPreferences: Hashable, Codable, Sendable {
    /// Whether speech in other languages is ignored. On by default.
    public var isEnabled: Bool
    /// The languages Blau answers, or `nil` for the default: the device's
    /// languages (see ``LanguageFilterSettings``).
    public var allowedLanguages: Set<SpokenLanguage>?

    public init(isEnabled: Bool = true, allowedLanguages: Set<SpokenLanguage>? = nil) {
        self.isEnabled = isEnabled
        self.allowedLanguages = allowedLanguages.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let `default` = LanguageFilterPreferences()

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case allowedLanguages = "allowed"
    }

    /// Lenient: a missing or unreadable field falls back to its default,
    /// and codes the model doesn't know are dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let codes = (try? container.decodeIfPresent([String].self, forKey: .allowedLanguages)) ?? nil
        self.init(
            isEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? Self.default.isEnabled,
            allowedLanguages: codes.map { Set($0.compactMap(SpokenLanguage.init(code:))) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(allowedLanguages.map { $0.map(\.code).sorted() }, forKey: .allowedLanguages)
    }
}

/// Persists the ``LanguageFilterPreferences``.
public protocol LanguageFilterPreferencesStore: Sendable {
    func load() -> LanguageFilterPreferences
    func save(_ preferences: LanguageFilterPreferences)
}

/// Keeps the preferences in `UserDefaults` as JSON under one key. Per
/// device, like the voice ID sensitivity.
public struct UserDefaultsLanguageFilterPreferencesStore: LanguageFilterPreferencesStore {
    public static let defaultKey = "blau.voiceID.languageFilter"

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

    public func load() -> LanguageFilterPreferences {
        guard let data = defaults.data(forKey: key),
            let preferences = try? JSONDecoder().decode(LanguageFilterPreferences.self, from: data)
        else { return .default }
        return preferences
    }

    public func save(_ preferences: LanguageFilterPreferences) {
        if preferences == .default {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Keeps the preferences in memory. For tests and previews.
public final class InMemoryLanguageFilterPreferencesStore: LanguageFilterPreferencesStore {
    private let value: Mutex<LanguageFilterPreferences>

    public init(_ preferences: LanguageFilterPreferences = .default) {
        value = Mutex(preferences)
    }

    public func load() -> LanguageFilterPreferences { value.withLock { $0 } }

    public func save(_ preferences: LanguageFilterPreferences) { value.withLock { $0 = preferences } }
}

/// Settings → Voice ID → Languages binds to this. Changes are saved at
/// once; the gate's ``LanguageFilter`` reads ``currentAllowedLanguages()``
/// for every segment it checks, from any thread.
///
/// **The default** is the device's languages: every language in the
/// iPhone's preferred list (Settings → General → Language & Region) the
/// model knows, plus whatever `defaultLanguages` adds. The app adds the
/// language Blau transcribes (English for Parakeet), so the default never
/// filters out the speech Blau is set up to understand. Choosing languages
/// replaces the default until **Use Device Languages**.
@MainActor
@Observable
public final class LanguageFilterSettings {
    /// The saved preferences.
    public private(set) var preferences: LanguageFilterPreferences

    @ObservationIgnored private let store: any LanguageFilterPreferencesStore
    @ObservationIgnored private nonisolated let defaultLanguages: @Sendable () -> Set<SpokenLanguage>
    @ObservationIgnored private nonisolated let current: Snapshot

    /// - Parameters:
    ///   - store: Where the preferences live.
    ///   - defaultLanguages: The default allowed languages, read whenever
    ///     they are needed (the device's language can change while Blau
    ///     runs). By default the device's preferred languages.
    public init(
        store: any LanguageFilterPreferencesStore,
        defaultLanguages: @escaping @Sendable () -> Set<SpokenLanguage> = {
            Set(SpokenLanguage.preferred())
        }
    ) {
        self.store = store
        self.defaultLanguages = defaultLanguages
        let loaded = store.load()
        preferences = loaded
        current = Snapshot(loaded)
    }

    /// Whether the filter is on.
    public var isEnabled: Bool {
        get { preferences.isEnabled }
        set { update { $0.isEnabled = newValue } }
    }

    /// Whether the allowed languages are the default (the device's).
    public var usesDefaultLanguages: Bool { preferences.allowedLanguages == nil }

    /// The languages Blau answers: the chosen ones, or the default.
    public var allowedLanguages: Set<SpokenLanguage> {
        preferences.allowedLanguages ?? defaultLanguages()
    }

    /// The default languages right now.
    public var defaultAllowedLanguages: Set<SpokenLanguage> { defaultLanguages() }

    /// Allows or disallows `language`. The last allowed language can't be
    /// removed (turn the filter off instead).
    public func setAllowed(_ language: SpokenLanguage, _ isAllowed: Bool) {
        var languages = allowedLanguages
        if isAllowed {
            languages.insert(language)
        } else {
            guard languages.count > 1 else { return }
            languages.remove(language)
        }
        update { $0.allowedLanguages = languages == defaultLanguages() ? nil : languages }
    }

    /// Back to the default languages.
    public func useDefaultLanguages() {
        update { $0.allowedLanguages = nil }
    }

    /// The allowed languages, or `nil` when the filter is off (or nothing
    /// is allowed). Safe from any thread, so the gate can call it for every
    /// segment.
    public nonisolated func currentAllowedLanguages() -> Set<SpokenLanguage>? {
        let preferences = current.value
        guard preferences.isEnabled else { return nil }
        let languages = preferences.allowedLanguages ?? defaultLanguages()
        return languages.isEmpty ? nil : languages
    }

    private func update(_ change: (inout LanguageFilterPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = LanguageFilterPreferences(isEnabled: updated.isEnabled, allowedLanguages: updated.allowedLanguages)
        guard updated != preferences else { return }
        preferences = updated
        current.set(updated)
        store.save(updated)
    }

    /// The latest preferences, readable off the main actor.
    private final class Snapshot: Sendable {
        private let storage: Mutex<LanguageFilterPreferences>
        init(_ value: LanguageFilterPreferences) { storage = Mutex(value) }
        var value: LanguageFilterPreferences { storage.withLock { $0 } }
        func set(_ value: LanguageFilterPreferences) { storage.withLock { $0 = value } }
    }
}
