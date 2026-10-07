import BlauAudio
import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTranscription
import Foundation
import Observation
import SwiftData
import os

/// The composition root: every service the app runs on, built once at launch
/// and injected into SwiftUI.
///
/// Views read it with `@Environment(AppEnvironment.self)`. Each subsystem is
/// held behind its BlauCore protocol, so the same views
/// run on live services, on the fakes in previews and UI tests, and on
/// whatever a unit test passes in. Build one with `make(kind:)`, or with
/// `live()`, `preview(...)` and `fake(kind:...)` directly.
///
/// Until a subsystem is built, its live slot holds an `UnavailableService`;
/// the issue that builds it swaps in the real implementation in `live()`.
@MainActor
@Observable
final class AppEnvironment {
    /// What the environment was built for.
    enum Kind: String, CaseIterable, Sendable {
        /// The real app.
        case live
        /// SwiftUI previews: fakes and an in-memory store.
        case preview
        /// The host app of the `BlauTests` unit tests: fakes and an in-memory
        /// store, so tests never touch the device's data.
        case unitTest = "unit-test"
        /// A `BlauUITests` launch: like `preview`, with flag overrides read
        /// from the launch arguments into memory so runs don't leak state.
        case uiTest = "ui-test"
    }

    let kind: Kind
    let config: AppConfig
    let flags: FeatureFlags
    let clock: any BlauClock

    let audio: any AudioService
    let transcriber: any Transcriber
    let voiceGate: any VoiceGate
    let realtime: any RealtimeService
    /// The SwiftData stores, mirrored to iCloud when the account allows it
    /// (#20, see docs/sync.md). `PersistenceGate` opens them and hands the
    /// current container to the views; the controller saves pending edits
    /// when the app leaves the foreground.
    let persistence: PersistenceController
    let topics: any TopicService
    let memory: any MemoryService

    /// xAI access (#33): the key store, the REST client, on-device realtime
    /// token minting and the `XAIAccount` the key entry views bind to. The
    /// live app uses the Keychain and the network; every other kind runs on
    /// an in-memory key store and a stub transport.
    let xai: XAIServices

    /// The on-device speech models (#27): downloads, verifies and warms up
    /// the FluidAudio models. The live app uses the pinned manifest (or
    /// fixture models when a test runner asks for them, see
    /// `SpeechModels.makeManager`); every other kind runs on fixture models,
    /// so no preview or test ever starts a real download.
    let speechModels: ModelManager

    /// The shared text embedding service (#60) behind memory search and
    /// topic segmentation, over the model `speechModels` installs as
    /// `.textEmbedding` (see `TextEmbeddings`). Never installed on fakes.
    let textEmbeddings: TextEmbeddingService

    /// The realtime session configuration (#35): the voice settings Settings
    /// edits and the configurator that builds each `session.update`. Live
    /// launches keep the settings in `UserDefaults`; every other kind keeps
    /// them in memory.
    let realtimeSession: RealtimeSessionServices

    /// Which speech-to-text engine to run (#31): Settings → Speech
    /// Recognition binds to it, and the `TranscriberRouter` follows its
    /// `preferenceChanges()` once the live audio pipeline is composed. Live
    /// launches keep the choice in `UserDefaults`; every other kind keeps it
    /// in memory.
    let transcriptionSettings: TranscriptionSettings

    /// Delivers scene phase changes to the services (see `ScenePhaseHandling`).
    let lifecycle: AppLifecycleCoordinator

    /// The conversation's audio (#26): capture and playback on one
    /// voice-processing engine, kept alive off screen by the
    /// `AudioSessionKeeper` that is `audio` in the live app. `nil` on fakes.
    let conversationAudio: ConversationAudio?

    /// Moves on-device model stages off the Neural Engine while Blau is off
    /// screen, and back (#26, docs/background.md). Stages register with it
    /// as they are built (the VAD, ASR #29, voice ID #47).
    let backgroundInference: BackgroundInferenceMonitor

    /// The thermal and power policy (#75): watches the thermal state, Low
    /// Power Mode and the battery and publishes the `PerformanceLevel` the
    /// pipeline adapts to (docs/performance.md). Live launches read the
    /// device; every other kind runs on fixed nominal conditions, which a
    /// UI test can override with `-BlauPerformanceLevel <level>`.
    let performance: PerformancePolicy

    /// The policy's state for the views (the degraded-mode indicator).
    let performanceStatus: PerformanceStatus

    /// Applies the performance level to the inference backends.
    @ObservationIgnored private var performanceFollower: Task<Void, Never>?

    /// Reports device lock and unlock to the keeper and the monitor (live
    /// app only).
    @ObservationIgnored private var deviceLock: DeviceLockObserver?

    /// The spoken conversation loop (#36): the live audio pipeline feeding
    /// the turn orchestrator in `realtime`. Only the live environment can
    /// start it.
    let voiceLoop: VoiceLoop

    /// The xAI key refresh started by the latest return to `active`, so tests
    /// can wait for it.
    @ObservationIgnored var xaiRefresh: Task<Void, Never>?

    /// The iCloud account and history refresh started by the latest return to
    /// `active`, so tests can wait for it.
    @ObservationIgnored var persistenceRefresh: Task<Void, Never>?

    init(
        kind: Kind,
        config: AppConfig,
        flags: FeatureFlags,
        clock: any BlauClock,
        audio: any AudioService,
        transcriber: any Transcriber,
        voiceGate: any VoiceGate,
        realtime: any RealtimeService,
        persistence: PersistenceController,
        topics: any TopicService,
        memory: any MemoryService,
        xai: XAIServices,
        speechModels: ModelManager,
        realtimeSession: RealtimeSessionServices,
        transcriptionSettings: TranscriptionSettings,
        conversationAudio: ConversationAudio? = nil,
        backgroundInference: BackgroundInferenceMonitor = BackgroundInferenceMonitor(),
        textEmbeddings: TextEmbeddingService = TextEmbeddings.unavailable(),
        performance: PerformancePolicy = PerformancePolicy(source: ManualDeviceConditionsSource())
    ) {
        self.kind = kind
        self.config = config
        self.flags = flags
        self.clock = clock
        self.audio = audio
        self.transcriber = transcriber
        self.voiceGate = voiceGate
        self.realtime = realtime
        self.persistence = persistence
        self.topics = topics
        self.memory = memory
        self.xai = xai
        self.speechModels = speechModels
        self.textEmbeddings = textEmbeddings
        self.realtimeSession = realtimeSession
        self.transcriptionSettings = transcriptionSettings
        self.conversationAudio = conversationAudio
        self.backgroundInference = backgroundInference
        self.performance = performance
        self.performanceStatus = PerformanceStatus(policy: performance)
        self.voiceLoop = VoiceLoop(
            realtime: realtime, speechModels: speechModels, audio: conversationAudio,
            backgroundInference: backgroundInference, performance: performance)
        self.lifecycle = AppLifecycleCoordinator(
            participants: Self.lifecycleOrder(
                persistence: persistence, audio: audio, transcriber: transcriber,
                backgroundInference: backgroundInference, voiceGate: voiceGate, realtime: realtime, topics: topics,
                memory: memory)
        )
    }

    /// The store views read and write through `@Query` and `modelContext`,
    /// or `nil` until the stores are open. Read it again rather than keeping
    /// it: the container is replaced when the iCloud account changes
    /// (`persistence.generation`).
    var modelContainer: ModelContainer? { persistence.stack?.container }

    /// Launch-time work, run once from the app's root `.task`: seeds the
    /// DEBUG developer xAI key, then loads the stored key; alongside, checks
    /// the installed speech models and starts any downloads they need.
    func start() async {
        startBackgroundServices()
        startPerformancePolicy()
        async let models: Void = speechModels.start()
        await xai.start()
        await models
    }

    /// Wires what keeps a conversation going off screen (#26): the Live
    /// Activity's Stop button, and (live app only) device lock reports and
    /// clearing a recording Live Activity left behind by a previous run.
    private func startBackgroundServices() {
        ConversationControl.stopHandler = { [weak self] in await self?.stopConversation() }
        guard kind == .live, deviceLock == nil else { return }
        let keeper = conversationAudio?.keeper
        let inference = backgroundInference
        deviceLock = DeviceLockObserver { locked in
            Task {
                await keeper?.setDeviceLocked(locked)
                await inference.setDeviceLocked(locked)
            }
        }
        deviceLock?.start()
        Task { await LiveActivityRecordingIndicator.endAll() }
    }

    /// Starts the thermal and power policy (#75) and applies its level to
    /// the inference backends. The pipeline's other stages read the level
    /// themselves as they are built (see docs/performance.md).
    private func startPerformancePolicy() {
        guard performanceFollower == nil else { return }
        performance.start()
        performanceStatus.start()
        let inference = backgroundInference
        let levels = performance.performanceLevels()
        performanceFollower = Task { await inference.follow(levels) }
    }

    /// Ends the conversation: what the Live Activity's Stop button does.
    /// Stops the voice loop, which closes the realtime session (#36), and
    /// turns the microphone off.
    func stopConversation() async {
        Log.ui.notice("Stopping the conversation from the Live Activity")
        await voiceLoop.stop()
        await audio.stopCapture()
    }

    /// The services in the order they are told the app became active, lowest
    /// BlauKit layer first (see docs/architecture.md). Leaving the foreground
    /// goes in reverse, so persistence saves last.
    private static func lifecycleOrder(
        persistence: PersistenceController,
        audio: any AudioService,
        transcriber: any Transcriber,
        backgroundInference: BackgroundInferenceMonitor,
        voiceGate: any VoiceGate,
        realtime: any RealtimeService,
        topics: any TopicService,
        memory: any MemoryService
    ) -> [any AppLifecycleParticipant] {
        [persistence, audio, transcriber, backgroundInference, voiceGate, realtime, topics, memory]
    }
}

// MARK: - Factories

extension AppEnvironment {
    /// Builds the environment for `kind`.
    static func make(kind: Kind) -> AppEnvironment {
        let environment =
            switch kind {
            case .live: live()
            case .preview: preview()
            case .unitTest, .uiTest: fake(kind: kind)
            }
        Log.ui.notice(
            "Built the \(kind.rawValue, privacy: .public) environment (\(environment.config.environment.rawValue, privacy: .public) build)"
        )
        return environment
    }

    /// The real app: the on-disk store mirrored to iCloud
    /// (`PersistenceController.live`), `UserDefaults` flags with DEBUG
    /// overrides, the Keychain-backed xAI services, the conversation audio
    /// with its keeper and Live Activity (#26), and an
    /// `UnavailableService` for each subsystem not built yet.
    ///
    /// A DEBUG launch with `BLAU_UI_TEST_XAI` set still gets the hermetic xAI
    /// stub (see `XAIServices.make(config:)`), so `XAIKeyEntryUITests` never
    /// touch the Keychain or the network.
    ///
    /// The parameters exist for tests; the app uses the defaults.
    static func live(
        config: AppConfig = .current,
        defaults: UserDefaults = .standard,
        persistence: PersistenceController? = nil,
        xai: XAIServices? = nil,
        speechModels: ModelManager? = nil
    ) -> AppEnvironment {
        // Capture (#24) and playback (#25) on the AudioSessionController
        // (#23), kept alive off screen with a lock-screen indicator (#26).
        // Nothing touches the microphone until `audio.startCapture()`.
        let conversationAudio = ConversationAudio.live(indicator: LiveActivityRecordingIndicator())
        // #27: the on-device model download manager, which also installs the
        // shared text embedding model (#60).
        let models = speechModels ?? SpeechModels.makeManager()
        let persistence = persistence ?? .live(isDebugBuild: AppConfig.isDebugBuild)
        let xai = xai ?? XAIServices.make(config: config)
        let realtimeSession = RealtimeSessionServices.make()
        return AppEnvironment(
            kind: .live,
            config: config,
            flags: FeatureFlags(
                storage: UserDefaultsFeatureFlagStorage(defaults: defaults),
                allowsOverrides: AppConfig.isDebugBuild
            ),
            clock: SystemClock(),
            audio: conversationAudio.keeper,
            // ParakeetStreamingTranscriber (#29) reads the capture hub and
            // the VAD segmenter, so it is wired in together with the live
            // audio pipeline (see docs/asr.md).
            transcriber: UnavailableService(subsystem: "transcription"),
            // #47: the voice ID verification gate.
            voiceGate: UnavailableService(subsystem: "voice ID"),
            // The Grok realtime session and the turn orchestrator (#34 - #36).
            realtime: VoiceLoop.makeOrchestrator(
                config: config, xai: xai, realtimeSession: realtimeSession, persistence: persistence,
                player: conversationAudio.player),
            // The SwiftData stores with CloudKit sync (#20).
            persistence: persistence,
            // #52 - #54: the topic segmenter.
            topics: UnavailableService(subsystem: "topics"),
            // #62 - #68: memory and its tools.
            memory: UnavailableService(subsystem: "memory"),
            xai: xai,
            speechModels: models,
            realtimeSession: realtimeSession,
            // #31: the Settings toggle that forces Apple's speech engine.
            transcriptionSettings: TranscriptionSettings.make(),
            conversationAudio: conversationAudio,
            textEmbeddings: TextEmbeddings.make(models: models),
            // The device's thermal state, Low Power Mode and battery (#75).
            performance: PerformancePolicy()
        )
    }

    /// Fakes over an in-memory store, for SwiftUI previews.
    ///
    /// - Parameters:
    ///   - flags: Flag overrides, for previewing a flag's effect.
    ///   - script: What the `FakeTranscriber` replays once started.
    ///   - memories: What the `FakeMemoryService` can find.
    ///   - isEnrolled: Whether the `FakeVoiceGate` has a voiceprint.
    static func preview(
        flags: [FeatureFlag: Bool] = [:],
        script: TranscriptScript = .sample,
        memories: [String] = sampleMemories,
        isEnrolled: Bool = true
    ) -> AppEnvironment {
        fake(kind: .preview, flags: .inMemory(flags), script: script, memories: memories, isEnrolled: isEnrolled)
    }

    /// Fakes over an in-memory store, for tests and UI-test launches.
    ///
    /// A `uiTest` environment seeds its in-memory flags from the
    /// `-blau.featureFlag.<name> YES` launch arguments, so a UI test can
    /// start with a flag set without persisting it on the simulator.
    ///
    /// Unless `xai` is passed, the xAI services run on an in-memory key store
    /// and a stub transport (`XAIServices.hermetic(config:)`), so hosted unit
    /// tests and previews never read or write the device's Keychain.
    static func fake(
        kind: Kind,
        flags: FeatureFlags? = nil,
        config: AppConfig = .fallback,
        script: TranscriptScript = .sample,
        memories: [String] = sampleMemories,
        isEnrolled: Bool = true,
        clock: any BlauClock = SystemClock(),
        xai: XAIServices? = nil,
        speechModels: ModelManager? = nil
    ) -> AppEnvironment {
        let flags = flags ?? .inMemory(kind == .uiTest ? launchArgumentFlagOverrides() : [:])
        let performance = PerformancePolicy(source: ManualDeviceConditionsSource(), clock: clock)
        if kind == .uiTest, let level = launchArgumentPerformanceLevel() {
            performance.setOverride(level)
        }
        return AppEnvironment(
            kind: kind,
            config: config,
            flags: flags,
            clock: clock,
            audio: FakeAudioService(),
            transcriber: FakeTranscriber(script: script, clock: clock),
            voiceGate: FakeVoiceGate(isEnrolled: isEnrolled),
            realtime: FakeRealtimeService(),
            persistence: .inMemory(),
            topics: FakeTopicService(),
            memory: FakeMemoryService(memories: memories),
            xai: xai ?? XAIServices.hermetic(config: config),
            speechModels: speechModels ?? fakeSpeechModels(kind: kind),
            realtimeSession: RealtimeSessionServices(persistence: InMemoryVoiceSettingsPersistence()),
            transcriptionSettings: TranscriptionSettings(
                store: InMemoryTranscriptionPreferencesStore(), availability: { .installed(locale: "en_US") }),
            performance: performance
        )
    }

    /// What the preview `FakeMemoryService` knows.
    static let sampleMemories = [
        "Joe is building Blau, a long-form voice app for talking with Grok",
        "The YC interview practice set has 20 questions",
        "Joe prefers short answers when practicing interview questions",
    ]

    /// Fixture speech models for a non-live environment. Unit tests build
    /// many environments while the test host app runs its own, so each gets
    /// a store of its own instead of resetting the shared fixture store.
    private static func fakeSpeechModels(kind: Kind) -> ModelManager {
        guard kind == .unitTest else { return SpeechModels.fixtureManager() }
        let root = SpeechModels.defaultFixtureRoot.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        return SpeechModels.fixtureManager(root: root)
    }

    /// Launch argument that holds a UI test's performance level, e.g.
    /// `-BlauPerformanceLevel reduced`.
    static let performanceLevelArgument = "BlauPerformanceLevel"

    private static func launchArgumentPerformanceLevel() -> PerformanceLevel? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return (arguments[performanceLevelArgument] as? String).flatMap(PerformanceLevel.init(rawValue:))
    }

    private static func launchArgumentFlagOverrides() -> [FeatureFlag: Bool] {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return UserDefaultsFeatureFlagStorage.overrides(in: arguments)
    }
}

// MARK: - Choosing the environment at launch

extension AppEnvironment.Kind {
    /// Process environment variable that picks the environment explicitly,
    /// for example `BLAU_APP_ENVIRONMENT=ui-test` from a UI test.
    static let environmentVariable = "BLAU_APP_ENVIRONMENT"

    /// The environment for a process with `environment` variables:
    ///
    /// 1. `BLAU_APP_ENVIRONMENT`, when it names a kind;
    /// 2. `preview` when Xcode is rendering SwiftUI previews;
    /// 3. `unitTest` when the process hosts XCTest / Swift Testing bundles;
    /// 4. otherwise `live`.
    static func detect(environment: [String: String]) -> Self {
        if let raw = environment[environmentVariable], let kind = Self(rawValue: raw) {
            return kind
        }
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .preview
        }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        {
            return .unitTest
        }
        return .live
    }

    /// The environment for the running process.
    static var current: Self {
        detect(environment: ProcessInfo.processInfo.environment)
    }
}
