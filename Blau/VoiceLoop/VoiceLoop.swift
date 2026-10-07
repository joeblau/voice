import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTranscription
import Foundation
import Observation

/// Runs a spoken conversation with Grok (#36): the live audio pipeline
/// (voice-processing capture, Silero VAD, streaming Parakeet ASR) feeding the
/// `TurnOrchestrator`, whose replies play through the `StreamingAudioPlayer`
/// on the same audio engine.
///
/// The conversation audio (#26: the voice-processing engine with capture and
/// playback, kept alive off screen by its `AudioSessionKeeper`) and the
/// orchestrator are built once at launch (`ConversationAudio.live`,
/// `makeOrchestrator`) and live in `AppEnvironment`; the VAD and ASR are
/// built on each `start()`, because they need the downloaded speech models. Views read `snapshot` (state, live text,
/// latency, usage) and `phase`. The record button (#41) starts and stops it
/// through `VoiceLoopSession`; the DEBUG menu's Voice Loop screen can too.
@MainActor
@Observable
final class VoiceLoop {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case failed(String)

        var isActive: Bool { self == .starting || self == .running }
    }

    enum StartError: Error, CustomStringConvertible {
        case unavailable
        case modelsNotInstalled
        case audio(String)

        var description: String {
            switch self {
            case .unavailable: "The voice loop isn't available in this environment"
            case .modelsNotInstalled: "The speech models aren't installed yet"
            case .audio(let state): "The microphone couldn't start (\(state))"
            }
        }
    }

    /// Builds the on-device half of one conversation: `LiveVoicePipeline`
    /// in the app, a fake in tests.
    typealias PipelineStarter = @MainActor () async throws -> any VoiceLoopPipeline

    private(set) var phase: Phase = .idle
    /// Why the latest `start()` failed, while `phase` is `.failed`.
    private(set) var startError: (any Error)?
    /// The orchestrator's latest snapshot.
    private(set) var snapshot = TurnSnapshot()

    /// The realtime half: the `TurnOrchestrator`. `nil` when this
    /// environment can't run a conversation (previews and tests run on a
    /// `FakeRealtimeService`).
    private let conversation: (any VoiceLoopConversation)?
    private let startPipeline: PipelineStarter?
    /// Turns the microphone off: what `stop()` does when it ends a start
    /// before the pipeline exists.
    private let releaseAudio: @MainActor () async -> Void
    /// The conversation audio the orchestrator's player belongs to; `nil`
    /// outside the live environment.
    private let audio: ConversationAudio?
    /// The thermal and power policy (#75): the live ASR follows it between
    /// utterances, 320 ms chunks at `normal` and 1280 ms below it.
    let performance: any PerformanceLevelProviding

    @ObservationIgnored private var pipeline: (any VoiceLoopPipeline)?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// Bumped by every `start()` and `stop()`. A start that finds it changed
    /// after an `await` was ended by `stop()` meanwhile, and unwinds.
    @ObservationIgnored private var startGeneration: UInt64 = 0
    /// The start in flight, including one `stop()` cut short that is still
    /// releasing what it built. Cleared when it returns.
    @ObservationIgnored private var startInFlight: (generation: UInt64, task: Task<Void, Never>)?

    /// The live voice loop: `realtime` is the `TurnOrchestrator` playing
    /// through `audio`'s player, and each conversation's pipeline is
    /// `LiveVoicePipeline` over `audio` with the installed `speechModels`.
    /// Anything else can't run a conversation (`isAvailable` is `false`).
    convenience init(
        realtime: any RealtimeService,
        speechModels: ModelManager,
        audio: ConversationAudio? = nil,
        backgroundInference: BackgroundInferenceMonitor? = nil,
        performance: any PerformanceLevelProviding
    ) {
        let orchestrator = realtime as? TurnOrchestrator
        guard let orchestrator, let audio, orchestrator.audio as? StreamingAudioPlayer === audio.player else {
            self.init(
                conversation: nil, snapshots: orchestrator?.updates(), startPipeline: nil, audio: audio,
                performance: performance)
            return
        }
        let keeper = audio.keeper
        self.init(
            conversation: orchestrator,
            snapshots: orchestrator.updates(),
            startPipeline: {
                try await LiveVoicePipeline.start(
                    audio: audio, models: speechModels, backgroundInference: backgroundInference,
                    performance: performance, bargeInTarget: orchestrator)
            },
            releaseAudio: { await keeper.stopCapture() },
            audio: audio,
            performance: performance)
    }

    /// The seam behind the live initializer; tests drive the start and stop
    /// sequence with fakes.
    init(
        conversation: (any VoiceLoopConversation)?,
        snapshots: AsyncStream<TurnSnapshot>?,
        startPipeline: PipelineStarter?,
        releaseAudio: @escaping @MainActor () async -> Void = {},
        audio: ConversationAudio? = nil,
        performance: any PerformanceLevelProviding
    ) {
        self.conversation = conversation
        self.startPipeline = startPipeline
        self.releaseAudio = releaseAudio
        self.audio = audio
        self.performance = performance
        if let snapshots {
            observation = Task { [weak self] in
                for await snapshot in snapshots {
                    self?.snapshot = snapshot
                }
            }
        }
    }

    isolated deinit {
        observation?.cancel()
        transcriptTask?.cancel()
    }

    /// Whether this environment can run a conversation.
    var isAvailable: Bool { conversation != nil && startPipeline != nil }

    /// The HUD rows for the current snapshot.
    var hudReadout: TurnHUDReadout { TurnHUDReadout(snapshot) }

    /// The voice pipeline's part of the performance HUD (#71): capture
    /// drops, the VAD's state and load, the ASR chunk counters, and the
    /// orchestrator's turn state, latencies, tokens and cost. Every read is a
    /// lock-protected snapshot, cheap enough for the HUD's 1 Hz refresh.
    func hudReadings() -> PipelineReadings {
        var readings = PipelineReadings()
        snapshot.fill(&readings)
        if let audio {
            let capture = audio.capture.hub.statistics
            readings.capture = .init(
                droppedBuffers: capture.droppedBuffers, subscriberDroppedFrames: capture.subscriberDroppedFrames,
                conversionFailures: capture.conversionFailures)
        }
        if let pipeline = pipeline as? LiveVoicePipeline {
            let vad = pipeline.voiceActivity.statistics
            readings.voiceActivity = .init(
                isSpeech: pipeline.voiceActivity.isSpeechActive, modelLoad: vad.modelLoad,
                skippedFraction: vad.skippedFraction)
            let asr = pipeline.transcriber.statistics
            readings.transcriber = .init(
                chunks: asr.chunksProcessed, meanChunkMilliseconds: asr.meanChunkTime.milliseconds,
                slowestChunkMilliseconds: asr.slowestChunk.milliseconds)
        }
        return readings
    }

    /// Builds the audio pipeline and starts a conversation. The realtime
    /// session connects in the background; what the user says meanwhile is
    /// queued.
    ///
    /// `stop()` can arrive while this is in flight (the Live Activity, with
    /// its Stop button, is up from the moment the audio starts, while the
    /// models still load). The start then unwinds instead of going on to
    /// open the realtime session: it releases what it built and leaves
    /// `phase` `.idle`. A new start waits for one that is still unwinding,
    /// so its release can't turn off the new conversation's microphone.
    func start() async {
        guard !phase.isActive else { return }
        while let unwinding = startInFlight {
            await unwinding.task.value
            guard !phase.isActive else { return }
        }
        guard let conversation, let startPipeline else {
            startError = StartError.unavailable
            phase = .failed(StartError.unavailable.description)
            return
        }
        startError = nil
        startGeneration &+= 1
        let generation = startGeneration
        phase = .starting
        let task = Task {
            await self.performStart(generation: generation, conversation: conversation, startPipeline: startPipeline)
        }
        startInFlight = (generation, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Whether the start numbered `generation` is still wanted: no `stop()`
    /// (or newer start) came since.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == startGeneration && phase == .starting
    }

    private func performStart(
        generation: UInt64, conversation: any VoiceLoopConversation, startPipeline: PipelineStarter
    ) async {
        defer {
            if startInFlight?.generation == generation { startInFlight = nil }
        }
        let pipeline: any VoiceLoopPipeline
        do {
            pipeline = try await startPipeline()
        } catch {
            guard isCurrent(generation) else {
                Log.ui.notice("Voice loop stopped while its audio started")
                return
            }
            fail(error)
            return
        }
        guard isCurrent(generation) else {
            // Stopped while the pipeline came up: it is this start's alone
            // to release (it also turns the microphone off).
            Log.ui.notice("Voice loop stopped while its pipeline started")
            await pipeline.stop()
            return
        }
        self.pipeline = pipeline
        do {
            try await conversation.open()
        } catch {
            // Stopped meanwhile: `stop()` released the pipeline.
            guard isCurrent(generation) else { return }
            await pipeline.stop()
            self.pipeline = nil
            fail(error)
            return
        }
        guard isCurrent(generation) else {
            // Stopped while the conversation opened. `stop()` released the
            // pipeline, but may have closed the conversation before it was
            // open, so close it again.
            Log.ui.notice("Voice loop stopped while its conversation opened")
            await conversation.close()
            return
        }
        let events = pipeline.transcript
        transcriptTask = Task { await conversation.run(transcript: events) }
        phase = .running
        Log.ui.notice("Voice loop started")
    }

    private func fail(_ error: any Error) {
        Log.ui.error("Voice loop failed to start: \(String(describing: error), privacy: .public)")
        startError = error
        phase = .failed(String(describing: error))
    }

    /// Commits what is being said, ends the conversation and releases the
    /// microphone. During a start it also ends that start (see `start()`).
    func stop() async {
        guard phase.isActive else { return }
        let wasStarting = phase == .starting
        // A start in flight sees this and unwinds.
        startGeneration &+= 1
        // The transcriber commits the utterance in progress on stop; the
        // orchestrator stops once that has arrived.
        await pipeline?.stopListening()
        await transcriptTask?.value
        transcriptTask = nil
        await conversation?.close()
        await pipeline?.stop()
        pipeline = nil
        if wasStarting {
            // Before the pipeline exists, the microphone may already be
            // coming up (and with it the Live Activity).
            await releaseAudio()
        }
        phase = .idle
        Log.ui.notice("Voice loop stopped")
    }

    /// The live orchestrator: a realtime client minting its secrets on
    /// device, Blau's session configuration, the conversation's 24 kHz
    /// `player` and the SwiftData transcript (with the topic lifecycle
    /// listening, #54), whose writes `feed` reports to the chat transcript
    /// (#42) as they happen. Sessions are resumed after a drop and renewed
    /// before xAI's 120-minute limit (#39), reseeded with the current topic
    /// from `reseedContext`.
    static func makeOrchestrator(
        config: AppConfig,
        xai: XAIServices,
        realtimeSession: RealtimeSessionServices,
        transcript: any TurnTranscriptRecording,
        reseedContext: any RealtimeReseedContextProviding,
        player: StreamingAudioPlayer,
        feed: TranscriptFeed = TranscriptFeed()
    ) -> TurnOrchestrator {
        TurnOrchestrator(
            client: RealtimeClient(endpoint: config.xaiRealtimeURL, tokenProvider: xai.tokenProvider),
            configurator: realtimeSession.configurator,
            audio: player,
            transcript: FeedingTranscriptRecorder(transcript, feed: feed),
            reseedContext: reseedContext,
            // #68: the memory tools Grok calls; DEBUG keeps their payloads
            // for the chat's tool chips.
            tools: realtimeSession.toolRegistry,
            configuration: TurnOrchestrator.Configuration(keepsToolPayloads: AppConfig.isDebugBuild)
        )
    }
}

/// The realtime half of a conversation `VoiceLoop` runs: the
/// `TurnOrchestrator` in the app, a fake in tests.
protocol VoiceLoopConversation: AnyObject, Sendable {
    /// Opens a conversation; the realtime session connects in the
    /// background.
    func open() async throws
    /// Ends the conversation. Does nothing when none is open.
    func close() async
    /// Takes the transcriber's events until they end.
    func run(transcript events: AsyncStream<TranscriptEvent>) async
}

extension TurnOrchestrator: VoiceLoopConversation {
    func open() async throws {
        try await start(waitsForConnection: false)
    }

    func close() async {
        await stop()
    }
}

/// The on-device half of a conversation `VoiceLoop` runs:
/// `LiveVoicePipeline` in the app, a fake in tests.
@MainActor
protocol VoiceLoopPipeline: AnyObject {
    /// What the user says; ends once the pipeline stops listening.
    var transcript: AsyncStream<TranscriptEvent> { get }
    /// Commits the utterance in progress and ends `transcript`.
    func stopListening() async
    /// Stops everything, the microphone too.
    func stop() async
}

/// The on-device half of the voice loop for one conversation: the VAD and
/// streaming ASR over the conversation audio's capture, with the microphone
/// started through its `AudioSessionKeeper` (#26) so the conversation keeps
/// running off screen, and barge-in (#37) watching VAD for the user talking
/// over Grok.
@MainActor
final class LiveVoicePipeline: VoiceLoopPipeline {
    let transcriber: ParakeetStreamingTranscriber
    /// The VAD, for the performance HUD.
    let voiceActivity: VoiceActivitySegmenter
    private let stopAudio: @Sendable () async -> Void
    private var vadTask: Task<Void, Never>?
    private var bargeInTask: Task<Void, Never>?

    private init(
        transcriber: ParakeetStreamingTranscriber, voiceActivity: VoiceActivitySegmenter,
        vadTask: Task<Void, Never>?, bargeInTask: Task<Void, Never>?,
        stopAudio: @escaping @Sendable () async -> Void
    ) {
        self.transcriber = transcriber
        self.voiceActivity = voiceActivity
        self.vadTask = vadTask
        self.bargeInTask = bargeInTask
        self.stopAudio = stopAudio
    }

    /// Loads the models while the conversation audio (capture and playback
    /// on its engine) comes up, then starts the transcriber and VAD. The
    /// Silero stage is registered with `backgroundInference`, which moves it
    /// off the Neural Engine while Blau is off screen. The transcriber follows
    /// `performance` (#75): between utterances it switches to the 1280 ms
    /// export below `normal` and back to 320 ms, while that export is
    /// installed (`ParakeetEouRecognizer.provider(modelManager:)`). A
    /// `BargeInMonitor` cuts `bargeInTarget` off when VAD hears the user over
    /// the agent's audio, its echo guard reading the player and the capture
    /// history.
    ///
    /// Loading and the audio session are independent, so they overlap: the
    /// record button's tap-to-listening time (#41, `session.start`) is the
    /// slower of the two rather than their sum. Audio captured before the
    /// transcriber subscribes isn't transcribed; the button only shows
    /// listening once this returns.
    static func start(
        audio: ConversationAudio,
        models: ModelManager,
        backgroundInference: BackgroundInferenceMonitor?,
        performance: any PerformanceLevelProviding,
        bargeInTarget: (any BargeInTarget)? = nil
    ) async throws -> LiveVoicePipeline {
        #if os(iOS)
            guard let vadDirectory = models.directory(for: .sileroVAD),
                let asrDirectory = models.directory(for: .parakeetRealtimeEOU)
            else { throw VoiceLoop.StartError.modelsNotInstalled }

            let keeper = audio.keeper
            let audioStart = Task { try await keeper.startCapture() }

            let silero: SileroSpeechProbabilityModel
            let vad: VoiceActivitySegmenter
            let transcriber: ParakeetStreamingTranscriber
            let hub = audio.capture.hub
            do {
                silero = try await SileroSpeechProbabilityModel(modelDirectory: vadDirectory)
                vad = VoiceActivitySegmenter(model: silero, inferenceObserver: backgroundInference)
                transcriber = try await ParakeetStreamingTranscriber.load(
                    modelDirectory: asrDirectory, audio: hub, voiceActivity: vad,
                    chunkSizePolicy: PerformanceASRChunkSizePolicy(performance),
                    recognizerProvider: ParakeetEouRecognizer.provider(modelManager: models))
            } catch {
                // Let the audio finish coming up, then release it.
                _ = try? await audioStart.value
                await keeper.stopCapture()
                throw error
            }

            // An audio failure (say, microphone permission denied) surfaces
            // here, after the models have loaded: loading isn't cancellable
            // part way, so racing it wouldn't release anything sooner. The
            // loaded transcriber hasn't started (nothing subscribed to VAD or
            // the hub yet); finishing it ends its event stream, and the
            // models are released with it.
            do {
                try await audioStart.value
            } catch {
                await transcriber.finish()
                throw VoiceLoop.StartError.audio(String(describing: error))
            }
            // `stopCapture()` (the Live Activity's Stop) while the audio came
            // up or the models loaded: `startCapture()` returns without
            // throwing then, but the conversation was ended before it began.
            guard await keeper.status != .inactive else {
                await transcriber.finish()
                throw CancellationError()
            }
            let stage = silero.inferenceStage
            await backgroundInference?.register(silero, budget: .milliseconds(256))
            let stopAudio: @Sendable () async -> Void = {
                await backgroundInference?.unregister(stage: stage)
                await keeper.stopCapture()
            }
            do {
                // The transcriber subscribes to VAD before VAD sees any audio.
                try await transcriber.start()
            } catch {
                await stopAudio()
                throw error
            }
            // Barge-in subscribes to VAD before VAD sees any audio, too.
            var bargeInTask: Task<Void, Never>?
            if let bargeInTarget {
                let monitor = BargeInMonitor(target: bargeInTarget, playback: audio.player, microphone: hub)
                let onsets = vad.events()
                bargeInTask = Task { await monitor.run(onsets) }
            }
            let vadTask = Task { await vad.run(on: hub) }
            return LiveVoicePipeline(
                transcriber: transcriber, voiceActivity: vad, vadTask: vadTask, bargeInTask: bargeInTask,
                stopAudio: stopAudio)
        #else
            throw VoiceLoop.StartError.unavailable
        #endif
    }

    /// The transcriber's events, until it finishes.
    var transcript: AsyncStream<TranscriptEvent> { transcriber.events }

    /// Stops the transcriber, which commits the utterance in progress and
    /// ends `transcript` (so the conversation stops reading it).
    func stopListening() async {
        await transcriber.finish()
    }

    /// Stops ASR, VAD, barge-in and the audio session.
    func stop() async {
        await transcriber.finish()
        vadTask?.cancel()
        vadTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        await stopAudio()
    }
}
