import BlauTelemetry
import Foundation
import Synchronization
import os

/// Where ``RealtimeVoiceSettingsStore`` keeps the settings between launches.
public protocol RealtimeVoiceSettingsPersisting: Sendable {
    /// The saved settings, or `nil` if none were saved (or they can't be
    /// read).
    func loadVoiceSettings() -> RealtimeVoiceSettings?
    func saveVoiceSettings(_ settings: RealtimeVoiceSettings)
}

/// Keeps nothing: settings last as long as the store. For tests and
/// previews.
public final class InMemoryVoiceSettingsPersistence: RealtimeVoiceSettingsPersisting {
    private let saved: Mutex<RealtimeVoiceSettings?>

    public init(_ settings: RealtimeVoiceSettings? = nil) {
        saved = Mutex(settings)
    }

    public func loadVoiceSettings() -> RealtimeVoiceSettings? { saved.withLock { $0 } }
    public func saveVoiceSettings(_ settings: RealtimeVoiceSettings) { saved.withLock { $0 = settings } }
}

/// Saves the settings as JSON under one `UserDefaults` key.
///
/// These are device preferences, not conversation data, so they stay in
/// `UserDefaults` rather than SwiftData / CloudKit.
public struct UserDefaultsVoiceSettingsPersistence: RealtimeVoiceSettingsPersisting {
    public static let defaultKey = "blau.realtime.voiceSettings"

    /// `nil` for `UserDefaults.standard`.
    public let suiteName: String?
    public let key: String

    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func loadVoiceSettings() -> RealtimeVoiceSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(RealtimeVoiceSettings.self, from: data)
        } catch {
            Log.realtime.error("Unreadable voice settings; using defaults")
            return nil
        }
    }

    public func saveVoiceSettings(_ settings: RealtimeVoiceSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The one source of truth for the voice settings: Settings writes them,
/// ``RealtimeSessionConfigurator`` reads them for every `session.update` and
/// follows ``changes()`` to push a change to a live session.
///
/// Thread-safe and synchronous, so a SwiftUI binding can write it directly.
public final class RealtimeVoiceSettingsStore: Sendable {
    private struct State {
        var settings: RealtimeVoiceSettings
        /// Bumped on every change; see ``revision``.
        var revision: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<RealtimeVoiceSettings>.Continuation] = [:]
        var nextSubscriberID: UInt64 = 0
    }

    private let state: Mutex<State>
    private let persistence: any RealtimeVoiceSettingsPersisting

    /// Loads the saved settings, or ``RealtimeVoiceSettings/default``.
    public init(persistence: any RealtimeVoiceSettingsPersisting = InMemoryVoiceSettingsPersistence()) {
        self.persistence = persistence
        state = Mutex(State(settings: persistence.loadVoiceSettings() ?? .default))
    }

    /// The current settings.
    public var settings: RealtimeVoiceSettings {
        state.withLock { $0.settings }
    }

    /// How many times the settings have changed since the store was made.
    /// Goes up by one with every change, so a reader can tell whether the
    /// settings changed between two reads (``RealtimeSessionConfigurator``
    /// uses it to wait until a dragged slider has been let go).
    public var revision: UInt64 {
        state.withLock { $0.revision }
    }

    /// Replaces the settings, saves them and tells every ``changes()``
    /// subscriber. Does nothing if they didn't change.
    public func set(_ settings: RealtimeVoiceSettings) {
        apply { $0 = settings }
    }

    /// Changes some of the settings, atomically: concurrent updates each see
    /// the other's change, so none is lost.
    ///
    /// `change` runs while the store is locked, so it must not read or write
    /// the store itself.
    public func update(_ change: (inout RealtimeVoiceSettings) -> Void) {
        apply(change)
    }

    private func apply(_ change: (inout RealtimeVoiceSettings) -> Void) {
        let changed: (RealtimeVoiceSettings, [AsyncStream<RealtimeVoiceSettings>.Continuation])? =
            state.withLock { state in
                var settings = state.settings
                change(&settings)
                guard settings != state.settings else { return nil }
                state.settings = settings
                state.revision &+= 1
                return (settings, Array(state.subscribers.values))
            }
        guard let (settings, subscribers) = changed else { return }
        saveLatest()
        Log.realtime.info(
            "Voice settings changed: voice \(settings.voice.rawValue, privacy: .public), speed \(settings.speed, privacy: .public), reasoning \(settings.reasoningEffort.rawValue, privacy: .public)"
        )
        for subscriber in subscribers {
            subscriber.yield(settings)
        }
    }

    /// Saves the current settings.
    ///
    /// Runs outside the lock: `UserDefaults` posts its change notification
    /// synchronously, and an observer that reads the store from it must not
    /// deadlock. Writers racing here could save out of order, so after each
    /// save the writer checks the revision and saves again if a newer change
    /// landed meanwhile. Every save is followed by such a check, so the last
    /// value saved is always the latest settings.
    private func saveLatest() {
        var (settings, revision) = state.withLock { ($0.settings, $0.revision) }
        while true {
            persistence.saveVoiceSettings(settings)
            let latest = state.withLock { ($0.settings, $0.revision) }
            if latest.1 == revision { return }
            (settings, revision) = latest
        }
    }

    /// Every later change of the settings. Only the newest unread value is
    /// buffered, so a slow reader skips straight to the latest settings.
    /// Each call returns an independent stream.
    public func changes() -> AsyncStream<RealtimeVoiceSettings> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RealtimeVoiceSettings.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.subscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// The number of live ``changes()`` streams (for tests).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    deinit {
        for subscriber in state.withLock({ Array($0.subscribers.values) }) {
            subscriber.finish()
        }
    }
}
