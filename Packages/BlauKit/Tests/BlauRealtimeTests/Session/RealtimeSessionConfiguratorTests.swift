import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// Records what it is asked to send; can be told to fail like a client
/// that isn't connected.
final class RecordingSender: RealtimeEventSending {
    private struct State {
        var sent: [RealtimeClientEvent] = []
        var failure: RealtimeClientError?
        var attempts = 0
    }

    private let state = Mutex(State())

    var sent: [RealtimeClientEvent] { state.withLock { $0.sent } }
    /// Sends asked for, including failed ones.
    var attempts: Int { state.withLock { $0.attempts } }
    var sessions: [RealtimeSession] {
        sent.compactMap { event in
            guard case .sessionUpdate(let session) = event else { return nil }
            return session
        }
    }

    func fail(with error: RealtimeClientError?) {
        state.withLock { $0.failure = error }
    }

    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        let failure: RealtimeClientError? = state.withLock { state in
            state.attempts += 1
            if let failure = state.failure { return failure }
            state.sent.append(event)
            return nil
        }
        if let failure { throw failure }
    }
}

extension RealtimeSession {
    fileprivate var speed: Double? { audio?.output?.speed }
}

@Suite("Session configurator")
struct RealtimeSessionConfiguratorTests {
    private let clock = ManualClock(now: SessionFixtures.now)
    private let store = RealtimeVoiceSettingsStore()

    private func makeConfigurator(
        memory: any RealtimeMemoryContextProviding = NoRealtimeMemoryContext()
    ) -> RealtimeSessionConfigurator {
        RealtimeSessionConfigurator(
            settings: store, memory: memory, clock: clock, timeZone: { SessionFixtures.timeZone },
            settingsDebounce: .milliseconds(400))
    }

    @Test func configureSendsTheCompleteSessionUpdate() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()

        let session = try await configurator.configure(sender)

        let expected = RealtimeSessionConfiguration.blau.session(
            settings: .default, now: SessionFixtures.now, timeZone: SessionFixtures.timeZone)
        #expect(session == expected)
        #expect(sender.sent == [.sessionUpdate(expected)])
        #expect(session.turnDetection == .manual)
        #expect(session.voice == "eve")
        #expect(session.audio?.output?.format == .pcm24kHz)
        #expect(await configurator.appliedSession == expected)
        #expect(await configurator.appliedSettings == .default)
        #expect(await configurator.updatesSent == 1)
    }

    /// Acceptance criterion: changing voice/speed in Settings applies to the
    /// next session.update.
    @Test @MainActor func settingsChangesApplyToTheNextSessionUpdate() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()
        let settingsScreen = RealtimeVoiceSettingsModel(store: store)

        try await configurator.configure(sender)
        settingsScreen.voice = .rex
        settingsScreen.speed = 1.3
        settingsScreen.thinksBeforeAnswering = false
        try await configurator.configure(sender)

        let sessions = sender.sessions
        #expect(sessions.count == 2)
        #expect(sessions[0].voice == "eve")
        #expect(sessions[0].speed == 1.0)
        #expect(sessions[0].reasoning?.effort == .high)
        #expect(sessions[1].voice == "rex")
        #expect(sessions[1].speed == 1.3)
        #expect(sessions[1].reasoning?.effort == .disabled)
        // Everything else is unchanged and still sent in full.
        #expect(sessions[1].instructions == sessions[0].instructions)
        #expect(sessions[1].turnDetection == .manual)
        #expect(sessions[1].audio?.output?.format == .pcm24kHz)
    }

    @Test func includesMemoryAndToolsInEveryUpdate() async throws {
        let configurator = makeConfigurator(memory: StaticRealtimeMemoryContext(SessionFixtures.memory))
        await configurator.setTools(SessionFixtures.tools)
        let sender = RecordingSender()

        let session = try await configurator.configure(sender)
        #expect(session.tools == SessionFixtures.tools)
        #expect(session.instructions?.contains("Training for the Berkeley half marathon") == true)
        #expect(session.instructions?.contains("search_memory, web_search") == true)
        #expect(await configurator.currentSession() == session)
    }

    @Test func aFailedSendIsReportedAndNotRecordedAsApplied() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()
        sender.fail(with: .notConnected)

        await #expect(throws: RealtimeClientError.notConnected) {
            try await configurator.configure(sender)
        }
        #expect(await configurator.appliedSession == nil)
        #expect(await configurator.updatesSent == 0)
    }

    // MARK: Following Settings

    @Test func followsSettingsChangesAfterTheDebounce() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()
        try await configurator.configure(sender)

        let follower = Task { await configurator.followSettingsChanges(sending: sender) }
        defer { follower.cancel() }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }

        store.update { $0.voice = .ara }
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(399))
        try await settle()
        #expect(sender.sessions.count == 1, "sent before the debounce elapsed")

        clock.advance(by: .milliseconds(1))
        try await waitUntil("second update") { sender.sessions.count == 2 }
        #expect(sender.sessions.last?.voice == "ara")
    }

    @Test func aDraggedSliderSendsOneUpdateWithTheFinalValue() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()
        try await configurator.configure(sender)

        let follower = Task { await configurator.followSettingsChanges(sending: sender) }
        defer { follower.cancel() }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }

        store.update { $0.speed = 1.05 }
        await clock.waitForSleepers()
        for speed in [1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4] {
            store.update { $0.speed = speed }
        }
        clock.advance(by: .milliseconds(400))
        try await waitUntil("update sent") { sender.sessions.count == 2 }

        // The buffered change wakes the loop once more; nothing new is sent.
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(400))
        try await settle()
        #expect(sender.sessions.count == 2)
        #expect(sender.sessions.last?.speed == 1.4)
    }

    @Test func changesWhileDisconnectedWaitForTheNextConnection() async throws {
        let configurator = makeConfigurator()
        let sender = RecordingSender()
        sender.fail(with: .notConnected)

        let follower = Task { await configurator.followSettingsChanges(sending: sender) }
        defer { follower.cancel() }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }

        store.update { $0.voice = .leo }
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(400))
        try await waitUntil("tried to send") { sender.attempts == 1 }
        try await settle()
        #expect(sender.sent.isEmpty)
        #expect(sender.attempts == 1)

        // Reconnected: the owner configures the new session, with Leo.
        sender.fail(with: nil)
        try await configurator.configure(sender)
        #expect(sender.sessions.map(\.voice) == ["leo"])
    }

    @Test func stopsFollowingWhenCancelled() async throws {
        let configurator = makeConfigurator()
        let follower = Task { await configurator.followSettingsChanges(sending: RecordingSender()) }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }
        follower.cancel()
        await follower.value
        try await waitUntil("unsubscribed") { store.subscriberCount == 0 }
    }

    /// Lets the follower task run until it settles.
    private func settle() async throws {
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// The configurator against a real `RealtimeClient` over a fake socket: what
/// goes on the wire.
@Suite("Session configurator with RealtimeClient")
struct RealtimeSessionConfiguratorClientTests {
    @Test func configuresEachNewConnectionWithTheLatestSettings() async throws {
        let harness = ClientHarness()
        let store = RealtimeVoiceSettingsStore()
        let configurator = RealtimeSessionConfigurator(
            settings: store, clock: harness.clock, timeZone: { SessionFixtures.timeZone })

        try await harness.client.connect()
        try await configurator.configure(harness.client)
        let first = try await harness.connector.socket(0)

        // Settings change, then the connection drops and comes back: the new
        // server session gets the new voice and speed.
        store.update {
            $0.voice = .sal
            $0.speed = 0.9
        }
        first.fail()
        try await harness.waitForState(.connected)
        let second = try await harness.connector.socket(1)
        try await configurator.configure(harness.client)

        let firstUpdates = first.sentEvents.compactMap(\.sessionUpdate)
        let secondUpdates = second.sentEvents.compactMap(\.sessionUpdate)
        #expect(firstUpdates.map(\.voice) == ["eve"])
        #expect(secondUpdates.map(\.voice) == ["sal"])
        #expect(secondUpdates.first?.audio?.output?.speed == 0.9)
        #expect(secondUpdates.first?.turnDetection == .manual)

        // The frame on the wire is exactly the encoded event.
        guard case .text(let text) = second.sent.first else {
            Issue.record("Expected a text frame")
            return
        }
        let expected = try RealtimeEventCoding.encode(.sessionUpdate(try #require(secondUpdates.first)))
        #expect(Data(text.utf8) == expected)
    }

    @Test func followsSettingsOnALiveConnection() async throws {
        let harness = ClientHarness()
        let store = RealtimeVoiceSettingsStore()
        let configurator = RealtimeSessionConfigurator(
            settings: store, clock: harness.clock, timeZone: { SessionFixtures.timeZone },
            settingsDebounce: .milliseconds(250))
        try await harness.client.connect()
        try await configurator.configure(harness.client)
        let socket = try await harness.connector.socket(0)

        let follower = Task { await configurator.followSettingsChanges(sending: harness.client) }
        defer { follower.cancel() }
        try await waitUntil("subscribed") { store.subscriberCount == 1 }

        store.update { $0.voice = .ara }
        try await waitUntil("debouncing") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .milliseconds(250))
        try await waitUntil("update on the wire") { socket.sentEvents.count == 2 }
        #expect(socket.sentEvents.compactMap(\.sessionUpdate).map(\.voice) == ["eve", "ara"])
    }
}

extension RealtimeClientEvent {
    fileprivate var sessionUpdate: RealtimeSession? {
        guard case .sessionUpdate(let session) = self else { return nil }
        return session
    }
}
