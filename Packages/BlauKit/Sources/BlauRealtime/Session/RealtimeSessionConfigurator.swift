import BlauCore
import BlauTelemetry
import Foundation
import os

/// Something that sends realtime client events: ``RealtimeClient``, or a
/// fake in tests.
public protocol RealtimeEventSending: Sendable {
    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError)
}

extension RealtimeClient: RealtimeEventSending {}

/// Keeps a realtime session configured the way Blau wants it.
///
/// - **On every connection.** The server starts a fresh session on each
///   connection, so whoever owns the client (the turn orchestrator, #36)
///   calls ``configure(_:)`` after each `.connected` state, before the
///   first `conversation.item.create`.
/// - **When Settings change.** ``followSettingsChanges(sending:)`` watches
///   the ``RealtimeVoiceSettingsStore`` and sends a new `session.update` as
///   soon as the voice, speed or reasoning effort changes, so the change
///   applies from the next response. Changes are debounced (a speed slider
///   being dragged sends one update, not dozens). While disconnected
///   nothing is sent; the next ``configure(_:)`` carries the new settings.
///
/// Every `session.update` is complete (instructions, voice, audio, turn
/// detection), built from the settings and memory as they are at that
/// moment, so an update never depends on an earlier one having arrived.
///
/// ```swift
/// let configurator = RealtimeSessionConfigurator(settings: store, memory: memoryContext)
/// for await state in client.states where state == .connected {
///     try await configurator.configure(client)
/// }
/// // elsewhere, for the session's lifetime:
/// await configurator.followSettingsChanges(sending: client)
/// ```
public actor RealtimeSessionConfigurator {
    public nonisolated let settings: RealtimeVoiceSettingsStore
    public nonisolated let configuration: RealtimeSessionConfiguration
    /// How long Settings must be still before a change is sent.
    public nonisolated let settingsDebounce: Duration

    private let memory: any RealtimeMemoryContextProviding
    private let clock: any BlauClock
    private let timeZone: @Sendable () -> TimeZone

    /// Tools to declare in the session (#38). Empty sends none.
    public private(set) var tools: [RealtimeTool] = []
    /// The last session sent successfully, if any.
    public private(set) var appliedSession: RealtimeSession?
    /// The settings in ``appliedSession``.
    public private(set) var appliedSettings: RealtimeVoiceSettings?
    /// How many `session.update`s were sent successfully.
    public private(set) var updatesSent = 0

    /// - Parameters:
    ///   - settings: The voice settings Settings writes.
    ///   - memory: Supplies the ProfileBlock and facts (M3).
    ///   - configuration: Formats and instructions; Blau's by default.
    ///   - clock: Dates the instructions and times the debounce.
    ///   - timeZone: The user's time zone, read at each update.
    ///   - settingsDebounce: Quiet period before a settings change is sent.
    public init(
        settings: RealtimeVoiceSettingsStore,
        memory: any RealtimeMemoryContextProviding = NoRealtimeMemoryContext(),
        configuration: RealtimeSessionConfiguration = .blau,
        clock: any BlauClock = SystemClock(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        settingsDebounce: Duration = .milliseconds(400)
    ) {
        self.settings = settings
        self.memory = memory
        self.configuration = configuration
        self.clock = clock
        self.timeZone = timeZone
        self.settingsDebounce = settingsDebounce
    }

    /// Sets the tools later updates declare. Doesn't send anything.
    public func setTools(_ tools: [RealtimeTool]) {
        self.tools = tools
    }

    /// The session a `session.update` sent now would carry.
    public func currentSession() async -> RealtimeSession {
        await session(for: settings.settings)
    }

    /// Sends a complete `session.update` built from the current settings.
    ///
    /// If the settings change while the update is being built or sent (the
    /// actor is reentrant, so another `configure` may also be under way),
    /// it sends again, so the last update on the wire always carries the
    /// latest settings.
    ///
    /// - Returns: The session sent last.
    /// - Throws: The client's error, e.g.
    ///   ``RealtimeClientError/notConnected``.
    @discardableResult
    public func configure(_ sender: some RealtimeEventSending) async throws(RealtimeClientError) -> RealtimeSession {
        var attempts = 0
        while true {
            attempts += 1
            let current = settings.settings
            let session = await session(for: current)
            try await sender.send(.sessionUpdate(session))
            appliedSession = session
            appliedSettings = current
            updatesSent += 1
            Log.realtime.notice(
                "Sent session.update: voice \(current.voice.rawValue, privacy: .public), speed \(current.speed, privacy: .public), reasoning \(current.reasoningEffort.rawValue, privacy: .public), instructions \(session.instructions?.count ?? 0, privacy: .public) chars, \(session.tools?.count ?? 0, privacy: .public) tools"
            )
            // Bounded: a user can't change Settings faster than this resends.
            if settings.settings == current || attempts >= 3 {
                return session
            }
        }
    }

    /// Sends a `session.update` whenever the settings change, until the
    /// task is cancelled. Run it alongside the session.
    ///
    /// A change is sent once the settings have been still for
    /// ``settingsDebounce``. Changes made while disconnected are not sent
    /// (``RealtimeClientError/notConnected`` is expected then); the next
    /// ``configure(_:)`` picks them up.
    public func followSettingsChanges(sending sender: some RealtimeEventSending) async {
        let changes = settings.changes()
        for await _ in changes {
            do {
                try await clock.sleep(for: settingsDebounce)
            } catch {
                return
            }
            // Whatever arrived during the wait is in `settings` now; the
            // buffered change wakes the loop once more and is skipped below.
            guard !Task.isCancelled else { return }
            guard settings.settings != appliedSettings else { continue }
            do {
                try await configure(sender)
            } catch .notConnected {
                Log.realtime.info("Voice settings changed while disconnected; applying on the next connection")
            } catch {
                Log.realtime.error(
                    "Couldn't send updated voice settings: \(error.description, privacy: .public)")
            }
        }
    }

    private func session(for settings: RealtimeVoiceSettings) async -> RealtimeSession {
        let memory = await memory.memoryContext()
        return configuration.session(
            settings: settings, memory: memory, tools: tools, now: clock.now, timeZone: timeZone())
    }
}
