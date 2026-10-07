import Foundation
import Synchronization

/// The language the user speaks to Blau (Settings → Transcription →
/// Language).
public enum TranscriptionLanguage: Hashable, Codable, Sendable {
    /// Parakeet's English, and the iPhone's language for Apple's engine.
    case automatic
    /// A specific language, by locale identifier (`fr_FR`, `de_DE`...).
    case locale(String)

    /// The locale Apple's engine is asked for.
    public var locale: Locale {
        switch self {
        case .automatic: .current
        case .locale(let identifier): Locale(identifier: identifier)
        }
    }

    /// Whether only Apple's engine can transcribe it. Parakeet's realtime
    /// model understands English only, so any other chosen language goes to
    /// `SpeechTranscriber`.
    public var requiresAppleEngine: Bool {
        switch self {
        case .automatic: false
        case .locale(let identifier): Locale(identifier: identifier).language.languageCode != .english
        }
    }
}

/// The transcription choices beside the engine (Settings → Transcription).
public struct TranscriptionOptions: Hashable, Codable, Sendable {
    /// Re-transcribe each finished utterance with Parakeet TDT v3 for
    /// punctuation and accuracy (#30). On by default.
    public var refinesWithSecondPass: Bool
    /// The language spoken.
    public var language: TranscriptionLanguage

    public init(refinesWithSecondPass: Bool = true, language: TranscriptionLanguage = .automatic) {
        self.refinesWithSecondPass = refinesWithSecondPass
        self.language = language
    }

    public static let `default` = TranscriptionOptions()

    private enum CodingKeys: String, CodingKey {
        case refinesWithSecondPass = "second_pass"
        case language
    }

    /// Lenient: a missing or unreadable field falls back to its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            refinesWithSecondPass: (try? container.decodeIfPresent(Bool.self, forKey: .refinesWithSecondPass))
                ?? Self.default.refinesWithSecondPass,
            language: (try? container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language))
                ?? Self.default.language)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refinesWithSecondPass, forKey: .refinesWithSecondPass)
        try container.encode(language, forKey: .language)
    }
}

/// Persists the ``TranscriptionOptions``.
public protocol TranscriptionOptionsStore: Sendable {
    func load() -> TranscriptionOptions
    func save(_ options: TranscriptionOptions)
}

/// Keeps the options in `UserDefaults` as JSON under one key, per device
/// like the engine preference.
public struct UserDefaultsTranscriptionOptionsStore: TranscriptionOptionsStore {
    public static let defaultKey = "blau.transcription.options"

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

    public func load() -> TranscriptionOptions {
        guard let data = defaults.data(forKey: key),
            let options = try? JSONDecoder().decode(TranscriptionOptions.self, from: data)
        else { return .default }
        return options
    }

    public func save(_ options: TranscriptionOptions) {
        guard options != .default else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps the options in memory. For tests and previews.
public final class InMemoryTranscriptionOptionsStore: TranscriptionOptionsStore {
    private let value: Mutex<TranscriptionOptions>

    public init(_ options: TranscriptionOptions = .default) {
        value = Mutex(options)
    }

    public func load() -> TranscriptionOptions { value.withLock { $0 } }

    public func save(_ options: TranscriptionOptions) { value.withLock { $0 = options } }
}
