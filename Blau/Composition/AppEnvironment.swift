import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
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

    /// Delivers scene phase changes to the services (see `ScenePhaseHandling`).
    let lifecycle: AppLifecycleCoordinator

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
        xai: XAIServices
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
        self.lifecycle = AppLifecycleCoordinator(
            participants: Self.lifecycleOrder(
                persistence: persistence, audio: audio, transcriber: transcriber, voiceGate: voiceGate,
                realtime: realtime, topics: topics, memory: memory)
        )
    }

    /// The store views read and write through `@Query` and `modelContext`,
    /// or `nil` until the stores are open. Read it again rather than keeping
    /// it: the container is replaced when the iCloud account changes
    /// (`persistence.generation`).
    var modelContainer: ModelContainer? { persistence.stack?.container }

    /// Launch-time work, run once from the app's root `.task`: seeds the
    /// DEBUG developer xAI key, then loads the stored key.
    func start() async {
        await xai.start()
    }

    /// The services in the order they are told the app became active, lowest
    /// BlauKit layer first (see docs/architecture.md). Leaving the foreground
    /// goes in reverse, so persistence saves last.
    private static func lifecycleOrder(
        persistence: PersistenceController,
        audio: any AudioService,
        transcriber: any Transcriber,
        voiceGate: any VoiceGate,
        realtime: any RealtimeService,
        topics: any TopicService,
        memory: any MemoryService
    ) -> [any AppLifecycleParticipant] {
        [persistence, audio, transcriber, voiceGate, realtime, topics, memory]
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
    /// overrides, the Keychain-backed xAI services, and an
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
        xai: XAIServices? = nil
    ) -> AppEnvironment {
        AppEnvironment(
            kind: .live,
            config: config,
            flags: FeatureFlags(
                storage: UserDefaultsFeatureFlagStorage(defaults: defaults),
                allowsOverrides: AppConfig.isDebugBuild
            ),
            clock: SystemClock(),
            // #24 wires in the capture engine together with the
            // AudioSessionController from #23.
            audio: UnavailableService(subsystem: "audio"),
            // #29: ParakeetStreamingTranscriber.
            transcriber: UnavailableService(subsystem: "transcription"),
            // #47: the voice ID verification gate.
            voiceGate: UnavailableService(subsystem: "voice ID"),
            // #34 - #36: the Grok realtime session.
            realtime: UnavailableService(subsystem: "realtime"),
            // The SwiftData stores with CloudKit sync (#20).
            persistence: persistence ?? .live(isDebugBuild: AppConfig.isDebugBuild),
            // #52 - #54: the topic segmenter.
            topics: UnavailableService(subsystem: "topics"),
            // #62 - #68: memory and its tools.
            memory: UnavailableService(subsystem: "memory"),
            xai: xai ?? XAIServices.make(config: config)
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
        xai: XAIServices? = nil
    ) -> AppEnvironment {
        let flags = flags ?? .inMemory(kind == .uiTest ? launchArgumentFlagOverrides() : [:])
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
            xai: xai ?? XAIServices.hermetic(config: config)
        )
    }

    /// What the preview `FakeMemoryService` knows.
    static let sampleMemories = [
        "Joe is building Blau, a long-form voice app for talking with Grok",
        "The YC interview practice set has 20 questions",
        "Joe prefers short answers when practicing interview questions",
    ]

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
