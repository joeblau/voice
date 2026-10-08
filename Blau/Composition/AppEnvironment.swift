import BlauAudio
import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import BlauTranscription
import BlauVoiceID
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

    /// Opens, titles and refines topics, and applies the user's rename,
    /// merge and split (#54). In the live app it is also `topics`, fed by
    /// the orchestrator's transcript; elsewhere it runs on keyword titles
    /// over the in-memory store, so topic edits work in previews.
    let topicLifecycle: TopicLifecycle

    /// Learning from conversations (#66): each topic the lifecycle closes is
    /// sent for fact and entity extraction, and Settings → Knowledge binds to
    /// its toggle and "What Blau Learned". Only the live app calls xAI;
    /// every other kind runs on a text model that is never available.
    let memoryLearning: MemoryLearning

    /// The pinned profile (#67): sleep-time consolidation of the
    /// `ProfileBlock` from facts and recent topics, what each realtime
    /// session is told about the user, and Settings → Memory → Profile with
    /// the diff of every change. Only the live app consolidates (with xAI)
    /// or schedules the background task.
    let profileMemory: ProfileMemory

    /// The knowledge base's write path (#65): About Me, Company, Notes and
    /// Collections save through it, off the main thread, into whichever
    /// store is open (`KnowledgeBaseStore`, docs/knowledge-base.md).
    let knowledgeBase: any KnowledgeBaseEditing

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

    /// How strictly the voice ID gate matches the voiceprint (Settings →
    /// Voice ID → Sensitivity). The verification gate (#47) reads
    /// `currentConfig()` for each segment. Live launches keep it in
    /// `UserDefaults`; every other kind keeps it in memory.
    let voiceIDSettings: VoiceIDSettings

    /// What the guided voice enrollment (#46) records and embeds with: the
    /// conversation's voice-processing capture and the WeSpeaker model in
    /// the live app, synthetic speech everywhere else.
    let voiceEnrollment: VoiceEnrollmentServices

    /// The Markdown export to iCloud Drive → Blau (#78, docs/export.md).
    /// Settings → iCloud → Markdown Export binds to it; `start()` lets it follow the
    /// store for automatic export, and leaving the foreground flushes it.
    /// Live launches write to iCloud Drive; every other kind writes to a
    /// temporary folder with in-memory settings.
    let markdownExport: MarkdownExportController

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

    /// Keeps the on-device memory search index in step with the synced
    /// store (#63): one incremental indexer per store generation, throttled
    /// by `performance`, with a background processing task for rebuilds
    /// (`MemoryIndexBackgroundTask`). Only an on-disk store is indexed, so
    /// previews and tests (in-memory stores) never build one.
    let memoryIndexing: MemoryIndexingController

    /// Applies the performance level to the inference backends.
    @ObservationIgnored private var performanceFollower: Task<Void, Never>?

    /// Runs the automatic Markdown export (`MarkdownExportController.run()`).
    @ObservationIgnored private var markdownExportFollower: Task<Void, Never>?

    /// Reports device lock and unlock to the keeper and the monitor (live
    /// app only).
    @ObservationIgnored private var deviceLock: DeviceLockObserver?

    /// The spoken conversation loop (#36): the live audio pipeline feeding
    /// the turn orchestrator in `realtime`. Only the live environment can
    /// start it.
    let voiceLoop: VoiceLoop

    /// Every transcript write the turn orchestrator makes, as it happens
    /// (the live app wraps its SwiftData transcript in it).
    let transcriptFeed: TranscriptFeed

    /// What the chat transcript (#42) shows on top of the store: the
    /// speech in progress, Grok's reply as it plays, and the utterances
    /// just written. Lives as long as the app, so a rebuilt main screen
    /// keeps the running conversation's rows.
    let chat: ChatTranscriptModel

    /// The debug performance HUD (#71): shown from Settings → Developer, a
    /// DEBUG triple-tap or the `perfHUD` flag; reads the voice loop.
    let performanceHUD: PerformanceHUDController

    /// What the main screen's issue banner shows (#80, docs/errors.md): the
    /// conversation's, the audio's and iCloud's current problems, with
    /// their recovery actions. In the live app it also feeds the network
    /// path to the turn orchestrator (offline mode).
    let issues: IssueCenter

    /// What the record button (#41) starts, pauses and ends: the live
    /// `voiceLoop` with its conversation audio (`VoiceLoopSession`), or a
    /// `FakeConversationSession` over the fake `audio` everywhere else.
    let conversation: any ConversationSession

    /// Onboarding (#44, docs/onboarding.md): the first-run setup and its
    /// return when the key, the microphone or the speech models go missing.
    /// `RootView` shows it instead of the main screen while it is presented.
    /// Only the live app (and UI tests that ask with
    /// `BLAU_UI_TEST_ONBOARDING`) show it; see `OnboardingLaunch`.
    let onboarding: OnboardingController

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
        voiceIDSettings: VoiceIDSettings = VoiceIDSettings(store: InMemoryVoiceIDSensitivityStore()),
        voiceEnrollment: VoiceEnrollmentServices? = nil,
        conversationAudio: ConversationAudio? = nil,
        backgroundInference: BackgroundInferenceMonitor = BackgroundInferenceMonitor(),
        textEmbeddings: TextEmbeddingService = TextEmbeddings.unavailable(),
        performance: PerformancePolicy = PerformancePolicy(source: ManualDeviceConditionsSource()),
        topicLifecycle: TopicLifecycle? = nil,
        transcriptFeed: TranscriptFeed = TranscriptFeed(),
        markdownExport: MarkdownExportController? = nil,
        networkMonitor: (any NetworkMonitor)? = nil,
        memoryLearning: MemoryLearning? = nil,
        memoryIndexing: MemoryIndexingController? = nil,
        profileMemory: ProfileMemory? = nil,
        microphonePermission: any MicrophonePermissionProvider = StubMicrophonePermission(.granted),
        onboardingProgress: (any OnboardingProgressStore)? = nil
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
        let offlineTranscript = PersistenceTranscriptRecorder(persistence: persistence)
        self.topicLifecycle =
            topicLifecycle ?? (topics as? TopicLifecycle)
            ?? .offline(transcript: offlineTranscript)
        self.memoryLearning =
            memoryLearning ?? .offline(persistence: persistence, transcript: offlineTranscript)
        self.profileMemory = profileMemory ?? .offline(persistence: persistence)
        self.knowledgeBase = DeferredKnowledgeBaseStore(clock: clock) { @MainActor [weak persistence] in
            persistence?.stack?.container
        }
        self.xai = xai
        self.speechModels = speechModels
        self.textEmbeddings = textEmbeddings
        self.realtimeSession = realtimeSession
        self.transcriptionSettings = transcriptionSettings
        self.voiceIDSettings = voiceIDSettings
        self.voiceEnrollment = voiceEnrollment ?? .scripted(speed: Self.scriptedEnrollmentSpeed(kind))
        self.conversationAudio = conversationAudio
        self.backgroundInference = backgroundInference
        self.performance = performance
        self.performanceStatus = PerformanceStatus(policy: performance)
        self.markdownExport = markdownExport ?? .local(persistence: persistence)
        self.memoryIndexing =
            memoryIndexing
            ?? MemoryIndexingController(persistence: persistence, embedder: textEmbeddings, performance: performance)
        let voiceLoop = VoiceLoop(
            realtime: realtime, speechModels: speechModels, audio: conversationAudio,
            backgroundInference: backgroundInference, performance: performance,
            // #47: only the enrolled speaker's utterances reach Grok.
            voiceID: .live(persistence: persistence, models: speechModels, flags: flags, settings: voiceIDSettings))
        self.voiceLoop = voiceLoop
        self.transcriptFeed = transcriptFeed
        self.chat = ChatTranscriptModel(
            realtime: realtime, feed: transcriptFeed, player: conversationAudio?.player)
        self.performanceHUD = PerformanceHUDController(
            flags: flags, preferences: kind == .live ? .userDefaults() : .inMemory(),
            pipeline: {
                var readings = voiceLoop.hudReadings()
                readings.performance = performance.snapshot
                return readings
            })
        self.issues = IssueCenter(
            realtime: realtime, keeper: conversationAudio?.keeper, persistence: persistence, network: networkMonitor)
        let conversation: any ConversationSession =
            if let conversationAudio {
                VoiceLoopSession(voiceLoop: voiceLoop, audio: conversationAudio)
            } else {
                FakeConversationSession(audio: audio, startDelay: kind == .preview ? .milliseconds(400) : .zero)
            }
        self.conversation = conversation
        self.onboarding = OnboardingController(
            store: onboardingProgress, permission: microphonePermission, account: xai.account, models: speechModels,
            persistence: persistence, isConversationRunning: { conversation.status.isRunning })
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
        // #80: the issue banner's sources; UI tests can show a catalog entry.
        issues.start(fixture: kind == .live ? nil : IssueCenter.fixtureCode())
        // #63: indexes the store once `PersistenceGate` has opened it.
        memoryIndexing.start()
        memoryLearning.start(following: topicLifecycle)
        // #67: extraction notes and fresh facts for the pinned profile.
        profileMemory.start(learning: memoryLearning)
        // Previews and UI tests only: a canned conversation (#42).
        async let fixture: Void = ChatTranscriptFixture.seedIfRequested(in: self)
        startMarkdownExport()
        // Previews and UI tests only: a canned topic history (#56).
        async let timelineFixture: Void = TopicTimelineFixture.seedIfRequested(in: self)
        async let models: Void = speechModels.start()
        await xai.start()
        await models
        // #44: the key and the installed models are known now, so a
        // requirement that went missing since setup brings onboarding back.
        onboarding.checkPrerequisites()
        await fixture
        await timelineFixture
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

    /// Starts following the store for the automatic Markdown export (#78).
    /// It only exports while Settings → Export Automatically is on.
    private func startMarkdownExport() {
        guard markdownExportFollower == nil else { return }
        let export = markdownExport
        markdownExportFollower = Task { await export.run() }
    }

    /// Ends the conversation: what the Live Activity's Stop button does.
    /// Stops the voice loop, which closes the realtime session (#36), and
    /// turns the microphone off.
    func stopConversation() async {
        Log.ui.notice("Stopping the conversation from the Live Activity")
        // The record button's session first (it also unmutes the
        // microphone; the fake one in previews and UI tests follows too),
        // then the loop and capture in case anything else started them.
        await conversation.stop()
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
        let flags = FeatureFlags(
            storage: UserDefaultsFeatureFlagStorage(defaults: defaults),
            allowsOverrides: AppConfig.isDebugBuild
        )
        // #67: the pinned profile and top facts in every session's
        // instructions.
        let pinnedMemory = ProfileMemory.pinnedMemory(persistence: persistence)
        let textEmbeddings = TextEmbeddings.make(models: models)
        // The device's thermal state, Low Power Mode and battery (#75).
        // One policy, shared by the indexer (#63) and fact extraction (#66).
        let performance = PerformancePolicy()
        // #63: the incremental memory indexer; #68: the memory tools Grok
        // calls search its index and write facts to the store.
        let memoryIndexing = MemoryIndexingController(
            persistence: persistence, embedder: textEmbeddings, performance: performance)
        let memory = MemoryTools.service(indexing: memoryIndexing, textEmbeddings: textEmbeddings)
        // #54: the topic lifecycle writes through the transcript's store.
        let transcript = PersistenceTranscriptRecorder(persistence: persistence)
        // #66: facts and entities extracted from every closed topic.
        let memoryLearning = MemoryLearning.live(
            xai: xai, transcript: transcript, persistence: persistence, textEmbeddings: textEmbeddings,
            performance: performance)
        // #67: sleep-time consolidation of the profile block.
        let profileMemory = ProfileMemory.live(
            pinned: pinnedMemory, xai: xai, transcript: transcript, persistence: persistence,
            learning: memoryLearning, performance: performance)
        // A fact the `forget` tool forgets leaves the pinned profile too (#67).
        let realtimeSession = RealtimeSessionServices.make(
            memory: ProfileMemory.realtimeContext(pinnedMemory),
            tools: MemoryTools.registry(
                backend: profileMemory.reportingRemovals(of: memory), enabled: flags.isEnabled(.memoryTools)))
        let topics = TopicLifecycle.app(
            transcript: transcript, labeling: .app(xai: xai), textEmbeddings: textEmbeddings)
        let transcriptFeed = TranscriptFeed()
        return AppEnvironment(
            kind: .live,
            config: config,
            flags: flags,
            clock: SystemClock(),
            audio: conversationAudio.keeper,
            // ParakeetStreamingTranscriber (#29) reads the capture hub and
            // the VAD segmenter, so it is wired in together with the live
            // audio pipeline (see docs/asr.md).
            transcriber: UnavailableService(subsystem: "transcription"),
            // The voice ID verification gate (#47) is built per conversation
            // by `VoiceLoop`, like the transcriber (see docs/voice-id.md).
            voiceGate: UnavailableService(subsystem: "voice ID"),
            // The Grok realtime session and the turn orchestrator (#34 - #36).
            realtime: VoiceLoop.makeOrchestrator(
                config: config, xai: xai, realtimeSession: realtimeSession,
                transcript: TopicTrackingTranscript(base: transcript, topics: topics),
                // The transcript also supplies the current topic when a new
                // realtime session has to be given the conversation again (#39).
                reseedContext: transcript,
                player: conversationAudio.player, feed: transcriptFeed),
            // The SwiftData stores with CloudKit sync (#20).
            persistence: persistence,
            // #52 - #54: topic segmentation, labels and the topic lifecycle.
            topics: topics,
            // #62 - #68: memory and its tools.
            memory: memory,
            xai: xai,
            speechModels: models,
            realtimeSession: realtimeSession,
            // #31: the Settings toggle that forces Apple's speech engine.
            transcriptionSettings: TranscriptionSettings.make(),
            // Settings → Voice ID → Sensitivity, read by the gate (#47).
            voiceIDSettings: VoiceIDSettings.make(),
            // #46: enrollment records through the conversation's capture.
            voiceEnrollment: .live(audio: conversationAudio, models: models),
            conversationAudio: conversationAudio,
            textEmbeddings: textEmbeddings,
            // Also drives `memoryIndexing` and `memoryLearning`.
            performance: performance,
            topicLifecycle: topics,
            transcriptFeed: transcriptFeed,
            // #78: Markdown files in iCloud Drive → Blau.
            markdownExport: .live(persistence: persistence),
            // #80: offline mode follows the network path.
            networkMonitor: SystemNetworkMonitor(),
            memoryLearning: memoryLearning,
            memoryIndexing: memoryIndexing,
            profileMemory: profileMemory,
            // #44: the system prompt, unless a DEBUG UI test picks a stub.
            microphonePermission: OnboardingLaunch.microphonePermission(live: true),
            onboardingProgress: OnboardingLaunch.progressStore(kind: .live)
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
            performance: performance,
            // #44: off unless a UI test asks with BLAU_UI_TEST_ONBOARDING.
            microphonePermission: OnboardingLaunch.microphonePermission(live: false),
            onboardingProgress: kind == .uiTest ? OnboardingLaunch.progressStore(kind: kind) : nil
        )
    }

    /// How fast a non-live environment's synthetic enrollment speech plays:
    /// real time in previews, 8× in UI tests, unpaced in unit tests.
    static func scriptedEnrollmentSpeed(_ kind: Kind) -> Double? {
        switch kind {
        case .live, .preview: 1
        case .uiTest: 8
        case .unitTest: nil
        }
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
