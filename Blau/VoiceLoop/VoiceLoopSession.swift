import BlauAudio
import BlauCore
import BlauRealtime
import BlauTelemetry
import Foundation
import Observation

/// The live conversation behind the record button (#41): `VoiceLoop` (the
/// audio pipeline feeding the turn orchestrator, #36) and its
/// `ConversationAudio`, adapted to `ConversationSession`.
///
/// - **Status** combines the voice loop's phase and turn snapshot (followed
///   with `Observations`) with the `AudioSessionKeeper`'s status (its
///   `updates()`), so the button sees changes nobody asked it for: the Live
///   Activity's Stop, an interruption, a dropped connection, the debug Voice
///   Loop screen.
/// - **Pause listening** mutes the microphone inside voice processing
///   (`MicrophoneMute`); the conversation, the Live Activity and playback
///   carry on. Every new conversation starts unmuted.
/// - **Levels** are the capture hub's input levels and the player's output
///   level, both on the same decibel scale (`Self.meterFloorDecibels`).
@MainActor
final class VoiceLoopSession: ConversationSession {
    /// Quieter than this reads as an empty ring. Speech at a normal distance
    /// sits around -35 to -20 dBFS after voice processing.
    static let meterFloorDecibels: Float = -50
    /// How often Grok's reply level is sampled while it changes.
    static let outputLevelInterval: Duration = .milliseconds(33)

    let voiceLoop: VoiceLoop
    let audio: ConversationAudio

    private(set) var status: ConversationStatus = .idle

    private var audioStatus: AudioSessionKeeper.Status = .inactive
    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<ConversationStatus>.Continuation] = [:]
    private var observers: [Task<Void, Never>] = []

    init(voiceLoop: VoiceLoop, audio: ConversationAudio) {
        self.voiceLoop = voiceLoop
        self.audio = audio
        refresh()
        let keeper = audio.keeper
        observers.append(
            Task { [weak self] in
                for await snapshot in await keeper.updates() {
                    guard let self else { return }
                    audioStatus = snapshot.status
                    refresh()
                }
            })
        let changes = Observations { [voiceLoop] in
            LoopObservation(
                phase: voiceLoop.phase, turn: voiceLoop.snapshot.state, connection: voiceLoop.snapshot.connection)
        }
        observers.append(
            Task { [weak self] in
                for await _ in changes {
                    self?.refresh()
                }
            })
    }

    isolated deinit {
        for observer in observers {
            observer.cancel()
        }
        for subscriber in subscribers.values {
            subscriber.finish()
        }
    }

    // MARK: ConversationSession

    func statusUpdates() -> AsyncStream<ConversationStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationStatus.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(status)
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    func inputLevels() -> AsyncStream<Float> {
        let floor = Self.meterFloorDecibels
        return Self.relay(audio.capture.hub.levels()) { $0.normalized(floor: floor) }
    }

    func outputLevels() -> AsyncStream<Float> {
        let floor = Self.meterFloorDecibels
        return Self.relay(audio.player.updates(every: Self.outputLevelInterval)) { $0.level.normalized(floor: floor) }
    }

    func mutedSpeechActivity() -> AsyncStream<MutedSpeechActivity> {
        audio.microphoneMute.speechActivity()
    }

    func start(continuing topic: RealtimeContinuedTopic?) async throws {
        audio.microphoneMute.setMuted(false)
        await voiceLoop.start(continuing: topic)
        audioStatus = await audio.keeper.status
        refresh()
        switch voiceLoop.phase {
        case .running:
            return
        case .failed:
            let error = voiceLoop.startError ?? VoiceLoop.StartError.unavailable
            throw ConversationStartFailure(error, audio: audioStatus)
        case .idle, .starting:
            // Stopped (the Live Activity's Stop) while starting: not a
            // failure, so the record button goes back to idle quietly.
            throw CancellationError()
        }
    }

    func continueTopic(_ topic: RealtimeContinuedTopic) async throws {
        try await voiceLoop.continueTopic(topic)
    }

    func stop() async {
        await voiceLoop.stop()
        audio.microphoneMute.setMuted(false)
        audioStatus = await audio.keeper.status
        refresh()
    }

    func setListeningPaused(_ paused: Bool) async {
        guard voiceLoop.phase.isActive else { return }
        audio.microphoneMute.setMuted(paused)
        refresh()
    }

    // MARK: Status

    private func refresh() {
        let isRunning = voiceLoop.phase.isActive
        if !isRunning, audio.microphoneMute.isMuted {
            // Ended without the button (the Live Activity's Stop): the next
            // conversation starts listening.
            audio.microphoneMute.setMuted(false)
        }
        let snapshot = voiceLoop.snapshot
        let new = ConversationStatus(
            isRunning: isRunning,
            turn: snapshot.state,
            connection: snapshot.connection,
            audio: audioStatus,
            isListeningPaused: isRunning && audio.microphoneMute.isMuted
        )
        guard new != status else { return }
        status = new
        for subscriber in subscribers.values {
            subscriber.yield(new)
        }
    }

    /// Maps `source` on a task of its own (not the main actor), ending when
    /// the returned stream's consumer goes away.
    private static func relay<Input: Sendable, Output: Sendable>(
        _ source: AsyncStream<Input>, _ transform: @escaping @Sendable (Input) -> Output
    ) -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached {
            for await value in source {
                continuation.yield(transform(value))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// What `VoiceLoopSession` follows on the voice loop.
private struct LoopObservation: Equatable, Sendable {
    var phase: VoiceLoop.Phase
    var turn: TurnState
    var connection: RealtimeClient.ConnectionState
}

/// Why a conversation couldn't start, in words for the user.
struct ConversationStartFailure: LocalizedError, CustomStringConvertible {
    let underlying: any Error
    let audio: AudioSessionKeeper.Status

    init(_ underlying: any Error, audio: AudioSessionKeeper.Status) {
        self.underlying = underlying
        self.audio = audio
    }

    var errorDescription: String? {
        if case .failed(.microphonePermissionDenied) = audio {
            return String(localized: "Blau can't use the microphone. Turn on microphone access for Blau in Settings.")
        }
        switch underlying {
        case VoiceLoop.StartError.modelsNotInstalled:
            return String(localized: "The speech models are still downloading. Try again when they're ready.")
        case VoiceLoop.StartError.unavailable:
            return String(localized: "Conversations aren't available in this build of Blau.")
        case VoiceLoop.StartError.audio:
            return String(localized: "The microphone couldn't start. Try again in a moment.")
        case is CancellationError:
            return String(localized: "The conversation was stopped before it started.")
        default:
            return String(localized: "Something went wrong starting the conversation. Try again.")
        }
    }

    var description: String { "ConversationStartFailure(\(underlying), audio: \(audio))" }
}
