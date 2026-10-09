import Foundation
import Observation
import Synchronization

/// How strictly the voice ID gate matches speech against the enrolled
/// voiceprint: Settings → Voice ID → Sensitivity.
///
/// The calibrated thresholds (``VoiceIDConfig/calibrated``) sit in the
/// middle (`level` 0.5). Toward **strict** (1) both thresholds rise, so
/// another voice is less likely to get through but the user's own speech in
/// a noisy room is rejected or held as uncertain more often. Toward
/// **relaxed** (0) both fall, for the opposite trade.
public struct VoiceIDSensitivity: Hashable, Codable, Sendable {
    /// The slider's range.
    public static let range: ClosedRange<Double> = 0...1
    /// The slider's step.
    public static let step = 0.25
    /// The calibrated thresholds.
    public static let `default` = VoiceIDSensitivity(level: 0.5)
    /// How far the thresholds move at either end, in score units (raw
    /// cosine for the shipping config). Revisit it with the thresholds when
    /// the owner's recordings recalibrate them (docs/voice-id-eval.md).
    public static let maximumThresholdShift: Float = 0.06

    /// 0 relaxed, 0.5 calibrated, 1 strict. Kept in ``range`` and on
    /// ``step``.
    public var level: Double {
        didSet { level = Self.clamped(level) }
    }

    public init(level: Double) {
        self.level = Self.clamped(level)
    }

    /// How much the thresholds move: negative relaxes, positive tightens.
    public var thresholdShift: Float {
        Float((level - 0.5) * 2) * Self.maximumThresholdShift
    }

    static func clamped(_ level: Double) -> Double {
        guard level.isFinite else { return Self.default.level }
        let stepped = (level / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey { case level }

    /// Lenient: an unreadable value falls back to the calibrated level.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(level: (try? container.decode(Double.self, forKey: .level)) ?? Self.default.level)
    }
}

extension VoiceIDThresholds {
    /// Both thresholds moved by `shift`, kept within the cosine range.
    public func shifted(by shift: Float) -> VoiceIDThresholds {
        VoiceIDThresholds(accept: min(max(accept + shift, -1), 1), reject: min(max(reject + shift, -1), 1))
    }
}

extension VoiceIDConfig {
    /// This configuration with both windows' thresholds moved for
    /// `sensitivity`. The calibrated level returns `self` unchanged.
    ///
    /// The shift is in raw score units, so it means the same for every
    /// cosine scoring method. AS-norm scores are in standard deviations;
    /// the shift is then smaller than it looks but still moves the right
    /// way.
    public func adjusted(for sensitivity: VoiceIDSensitivity) -> VoiceIDConfig {
        let shift = sensitivity.thresholdShift
        guard shift != 0 else { return self }
        return VoiceIDConfig(
            modelIdentifier: modelIdentifier, scoring: scoring, short: short.shifted(by: shift),
            long: long.shifted(by: shift), longWindow: longWindow, calibration: calibration)
    }
}

// MARK: - Persistence

/// Persists the ``VoiceIDSensitivity``.
public protocol VoiceIDSensitivityStore: Sendable {
    func load() -> VoiceIDSensitivity
    func save(_ sensitivity: VoiceIDSensitivity)
}

/// Keeps the sensitivity in `UserDefaults`. Per device on purpose: how well
/// the voiceprint matches depends on the device's microphones.
public struct UserDefaultsVoiceIDSensitivityStore: VoiceIDSensitivityStore {
    public static let defaultKey = "blau.voiceID.sensitivity"

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

    public func load() -> VoiceIDSensitivity {
        guard defaults.object(forKey: key) != nil else { return .default }
        return VoiceIDSensitivity(level: defaults.double(forKey: key))
    }

    public func save(_ sensitivity: VoiceIDSensitivity) {
        if sensitivity == .default {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(sensitivity.level, forKey: key)
        }
    }
}

/// Keeps the sensitivity in memory. For tests and previews.
public final class InMemoryVoiceIDSensitivityStore: VoiceIDSensitivityStore {
    private let value: Mutex<VoiceIDSensitivity>

    public init(_ sensitivity: VoiceIDSensitivity = .default) {
        value = Mutex(sensitivity)
    }

    public func load() -> VoiceIDSensitivity { value.withLock { $0 } }

    public func save(_ sensitivity: VoiceIDSensitivity) { value.withLock { $0 = sensitivity } }
}

// MARK: - Settings model

/// Settings → Voice ID's sensitivity slider binds to this. A change is saved
/// at once and the verification gate (#47) reads it for the next segment it
/// scores through ``currentConfig(base:)``, which any thread may call.
@MainActor
@Observable
public final class VoiceIDSettings {
    /// The saved sensitivity.
    public private(set) var sensitivity: VoiceIDSensitivity

    /// Settings → Voice ID → Languages: which languages Blau answers (#50).
    @ObservationIgnored public let languageFilter: LanguageFilterSettings

    @ObservationIgnored private let store: any VoiceIDSensitivityStore
    @ObservationIgnored private nonisolated let current: Snapshot

    /// - Parameters:
    ///   - store: Where the sensitivity lives.
    ///   - languageFilter: The language filter's settings; in memory, with
    ///     the device's languages, by default.
    public init(store: any VoiceIDSensitivityStore, languageFilter: LanguageFilterSettings? = nil) {
        self.store = store
        self.languageFilter =
            languageFilter ?? LanguageFilterSettings(store: InMemoryLanguageFilterPreferencesStore())
        let loaded = store.load()
        sensitivity = loaded
        current = Snapshot(loaded)
    }

    /// The slider's value (see ``VoiceIDSensitivity/level``).
    public var level: Double {
        get { sensitivity.level }
        set {
            let updated = VoiceIDSensitivity(level: newValue)
            guard updated != sensitivity else { return }
            sensitivity = updated
            current.set(updated)
            store.save(updated)
        }
    }

    /// Back to the calibrated thresholds.
    public func resetToDefault() {
        level = VoiceIDSensitivity.default.level
    }

    /// `base` adjusted for the current sensitivity. Safe from any thread,
    /// so the gate can call it for every segment.
    public nonisolated func currentConfig(base: VoiceIDConfig = .calibrated) -> VoiceIDConfig {
        base.adjusted(for: current.value)
    }

    /// The latest sensitivity, readable off the main actor.
    private final class Snapshot: Sendable {
        private let storage: Mutex<VoiceIDSensitivity>
        init(_ value: VoiceIDSensitivity) { storage = Mutex(value) }
        var value: VoiceIDSensitivity { storage.withLock { $0 } }
        func set(_ value: VoiceIDSensitivity) { storage.withLock { $0 = value } }
    }
}
