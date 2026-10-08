import Foundation
import Synchronization

/// How far the user got through onboarding (#44). Saved after every step,
/// so onboarding interrupted by a crash, a force quit or iOS ending the app
/// (which it does when the user changes a privacy setting in the Settings
/// app) resumes on the step where it stopped.
public struct OnboardingProgress: Sendable, Hashable, Codable {
    /// Steps the user moved past, done or skipped.
    public var visited: Set<OnboardingStep>
    /// The step on screen when the progress was saved; `nil` before the
    /// first launch and after setup finished.
    public var current: OnboardingStep?
    /// When the user finished setup. From then on onboarding only comes
    /// back for a missing requirement.
    public var finishedAt: Date?

    public init(visited: Set<OnboardingStep> = [], current: OnboardingStep? = nil, finishedAt: Date? = nil) {
        self.visited = visited
        self.current = current
        self.finishedAt = finishedAt
    }

    /// A first launch.
    public static let fresh = OnboardingProgress()

    /// Whether setup finished.
    public var isFinished: Bool { finishedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case visited, current, finishedAt
    }

    /// Steps are decoded from their raw values, skipping ones this version
    /// doesn't know (written by a newer version), so a downgrade never
    /// throws away the whole progress.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let visited = try container.decodeIfPresent([String].self, forKey: .visited) ?? []
        self.visited = Set(visited.compactMap(OnboardingStep.init(rawValue:)))
        self.current = try container.decodeIfPresent(String.self, forKey: .current).flatMap(
            OnboardingStep.init(rawValue:))
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Sorted, so the stored JSON is stable.
        try container.encode(visited.map(\.rawValue).sorted(), forKey: .visited)
        try container.encodeIfPresent(current?.rawValue, forKey: .current)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
    }
}

/// Persists ``OnboardingProgress``. Implementations must be safe to call
/// from any thread.
public protocol OnboardingProgressStore: Sendable {
    func load() -> OnboardingProgress
    func save(_ progress: OnboardingProgress)
}

/// Keeps the progress in `UserDefaults` as JSON under one key.
///
/// Per device on purpose: every device needs its own microphone permission
/// and speech models, so a second device runs onboarding too (its key and
/// voiceprint arrive through iCloud, so those steps are skipped there).
public struct UserDefaultsOnboardingProgressStore: OnboardingProgressStore {
    public static let defaultKey = "blau.onboarding.progress"

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

    public func load() -> OnboardingProgress {
        guard let data = defaults.data(forKey: key),
            let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data)
        else { return .fresh }
        return progress
    }

    public func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key)
    }

    /// Forgets the progress: the next launch is a first run.
    public func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// Keeps the progress in memory. For tests and previews.
public final class InMemoryOnboardingProgressStore: OnboardingProgressStore {
    private let value: Mutex<OnboardingProgress>

    public init(_ progress: OnboardingProgress = .fresh) {
        value = Mutex(progress)
    }

    public func load() -> OnboardingProgress { value.withLock { $0 } }

    public func save(_ progress: OnboardingProgress) { value.withLock { $0 = progress } }
}
