import BlauCore
import BlauPersistence
import BlauRealtime
import Foundation
import SwiftData
import SwiftUI
import Synchronization
import Testing
import UIKit

@testable import Blau

@Suite("AppEnvironment kind detection")
struct AppEnvironmentKindTests {
    @Test func defaultsToLive() {
        #expect(AppEnvironment.Kind.detect(environment: [:]) == .live)
    }

    @Test(arguments: AppEnvironment.Kind.allCases)
    func explicitVariableWins(kind: AppEnvironment.Kind) {
        let environment = [
            "BLAU_APP_ENVIRONMENT": kind.rawValue,
            "XCODE_RUNNING_FOR_PREVIEWS": "1",
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
        ]
        #expect(AppEnvironment.Kind.detect(environment: environment) == kind)
    }

    @Test func unknownExplicitValueFallsThrough() {
        #expect(AppEnvironment.Kind.detect(environment: ["BLAU_APP_ENVIRONMENT": "staging"]) == .live)
    }

    @Test func detectsPreviews() {
        #expect(AppEnvironment.Kind.detect(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]) == .preview)
        #expect(AppEnvironment.Kind.detect(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "0"]) == .live)
    }

    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"])
    func detectsATestHost(variable: String) {
        #expect(AppEnvironment.Kind.detect(environment: [variable: "x"]) == .unitTest)
    }

    /// These tests run hosted in the app, so the app itself must have picked
    /// the fake, in-memory environment and never opened the device's store.
    @Test func theTestHostRunsOnFakes() {
        #expect(AppEnvironment.Kind.current == .unitTest)
    }
}

@Suite("AppEnvironment factories")
@MainActor
struct AppEnvironmentFactoryTests {
    @Test func previewUsesFakesAndAnInMemoryStore() {
        let environment = AppEnvironment.preview(flags: [.perfHUD: true])
        #expect(environment.kind == .preview)
        #expect(environment.audio is FakeAudioService)
        #expect(environment.transcriber is FakeTranscriber)
        #expect(environment.voiceGate is FakeVoiceGate)
        #expect(environment.realtime is FakeRealtimeService)
        #expect(environment.topics is FakeTopicService)
        #expect(environment.memory is FakeMemoryService)
        #expect(environment.persistence.storeKind == .inMemory)
        #expect(environment.flags.allowsOverrides)
        #expect(environment.flags.isEnabled(.perfHUD))
        #expect(environment.lifecycle.phase == nil)
    }

    @Test func eachEnvironmentGetsItsOwnStoreAndFlags() throws {
        let first = AppEnvironment.preview()
        let second = AppEnvironment.preview()
        first.modelContainer.mainContext.insert(Conversation(startedAt: .distantPast))
        try first.modelContainer.mainContext.save()
        #expect(try second.modelContainer.mainContext.fetchCount(FetchDescriptor<Conversation>()) == 0)

        first.flags.setOverride(true, for: .perfHUD)
        #expect(!second.flags.isEnabled(.perfHUD))
    }

    @Test func previewTranscriberReplaysTheScript() async throws {
        let clock = ManualClock()
        let script = TranscriptScript.speaking(["hello Blau"], wordDuration: .seconds(1))
        let environment = AppEnvironment.fake(kind: .unitTest, script: script, clock: clock)
        try await environment.transcriber.start()
        var events = environment.transcriber.events.makeAsyncIterator()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        #expect(await events.next() == script.steps[0].event)
        await environment.transcriber.stop()
    }

    @Test func liveUsesUserDefaultsFlagsAndUnavailableServices() async throws {
        let suiteName = "com.joeblau.blau.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: FeatureFlag.perfHUD.defaultsKey)

        let environment = AppEnvironment.live(
            config: .fallback,
            defaults: defaults,
            persistence: try SwiftDataPersistence.inMemory()
        )
        #expect(environment.kind == .live)
        #expect(environment.config == .fallback)
        // Tests run the Debug build, where overrides are honoured.
        #expect(environment.flags.allowsOverrides == AppConfig.isDebugBuild)
        #expect(environment.flags.isEnabled(.perfHUD) == AppConfig.isDebugBuild)

        environment.flags.setOverride(false, for: .memoryTools)
        #expect(defaults.object(forKey: FeatureFlag.memoryTools.defaultsKey) as? Bool == false)

        for service in [
            environment.audio as Any, environment.transcriber, environment.voiceGate, environment.realtime,
            environment.topics, environment.memory,
        ] {
            #expect(service is UnavailableService)
        }
        await #expect(throws: ServiceUnavailableError.self) { try await environment.realtime.connect() }
    }

    @Test func uiTestEnvironmentKeepsFlagsInMemory() {
        let environment = AppEnvironment.make(kind: .uiTest)
        #expect(environment.kind == .uiTest)
        #expect(environment.persistence.storeKind == .inMemory)
        // Compare with what was there before rather than with `nil`: a live
        // run on this simulator may have set the flag from the debug menu.
        let key = FeatureFlag.perfHUD.defaultsKey
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        environment.flags.setOverride(!(before ?? false), for: .perfHUD)
        #expect(environment.flags.isEnabled(.perfHUD) == !(before ?? false))
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == before)
    }

    @Test func liveUsesTheXAIServicesItIsGiven() throws {
        let xai = XAIServices.hermetic(config: .fallback)
        let environment = AppEnvironment.live(
            config: .fallback,
            defaults: try #require(UserDefaults(suiteName: "com.joeblau.blau.tests.\(UUID().uuidString)")),
            persistence: try SwiftDataPersistence.inMemory(),
            xai: xai
        )
        #expect(environment.xai === xai)
    }
}

/// The xAI services (#33) are part of the composition root.
@Suite("AppEnvironment xAI services")
@MainActor
struct AppEnvironmentXAITests {
    private let fakeKeyRaw = "xai-" + String(repeating: "EnvTest0Key", count: 5) + "a1b2"

    @Test(arguments: [AppEnvironment.Kind.preview, .unitTest, .uiTest])
    func fakeEnvironmentsStartWithoutAKeyAndNeverTouchTheKeychain(kind: AppEnvironment.Kind) async {
        let environment = AppEnvironment.make(kind: kind)
        await environment.start()
        #expect(environment.xai.account.status == .noKey)
        #expect(environment.xai.account.needsKeyEntry)

        // The in-memory store and the accepting stub let previews and tests
        // connect a key without the Keychain or the network.
        #expect(await environment.xai.account.connect(apiKey: fakeKeyRaw))
        #expect(environment.xai.account.hasKey)
        #expect(!AppEnvironment.make(kind: kind).xai.account.hasKey)
    }

    @Test func developmentKeySeedingStaysInMemory() async throws {
        // Debug builds seed the developer key on start; the fake environment
        // must seed (if at all) into memory, never into the Keychain.
        let config = AppConfig(
            environment: .debug, xaiAPIHost: "api.x.ai", xaiRealtimeModel: "grok-voice-think-fast-2.0",
            developmentAPIKey: fakeKeyRaw)
        let environment = AppEnvironment.fake(kind: .unitTest, config: config)
        await environment.start()
        #expect(environment.xai.account.hasKey == AppConfig.isDebugBuild)

        // Seeding is per environment: a second one seeds its own in-memory
        // store, and removing the key there leaves the first one's key alone.
        let other = AppEnvironment.fake(kind: .unitTest, config: config)
        await other.start()
        #expect(other.xai.account.hasKey == AppConfig.isDebugBuild)
        await other.xai.account.removeKey()
        #expect(!other.xai.account.hasKey)
        await environment.xai.refresh()
        #expect(environment.xai.account.hasKey == AppConfig.isDebugBuild)
    }

    /// The real launch order: SwiftUI reports `inactive`, the root `.task`
    /// runs `start()`, and the scene becomes `active` while the DEBUG
    /// developer key is still being written. The refresh that activation
    /// triggers must not read the store before the seed lands.
    @Test(.enabled(if: AppConfig.isDebugBuild, "The developer key is seeded in DEBUG builds only"))
    func launchActivationDoesNotRaceTheDevelopmentKeySeeding() async throws {
        let config = AppConfig(
            environment: .debug, xaiAPIHost: "api.x.ai", xaiRealtimeModel: "grok-voice-think-fast-2.0",
            developmentAPIKey: fakeKeyRaw)
        let store = GatedSaveAPIKeyStore()
        let xai = XAIServices(
            config: config, store: store, transport: XAIUITestStub.accept.transport,
            seedMarker: InMemorySeedMarker())
        let environment = AppEnvironment.fake(kind: .unitTest, config: config, xai: xai)

        environment.handleScenePhase(.inactive)
        let start = Task { await environment.start() }
        await store.waitUntilASaveIsPending()

        environment.handleScenePhase(.active)
        await environment.xaiRefresh?.value
        // The refresh left the account alone instead of reading a store that
        // doesn't hold the seed yet.
        #expect(!xai.hasStarted)
        #expect(environment.xai.account.status == .unknown)
        #expect(environment.xai.account.activity == .idle)

        store.releaseSave()
        await start.value
        #expect(xai.hasStarted)
        #expect(environment.xai.account.hasKey)
        #expect(try await store.load()?.rawValue == fakeKeyRaw)
    }

    @Test func becomingActiveAgainPicksUpAKeyFromAnotherDevice() async throws {
        let store = InMemoryAPIKeyStore()
        let xai = XAIServices(
            config: .fallback, store: store, transport: XAIUITestStub.accept.transport,
            seedMarker: InMemorySeedMarker())
        let environment = AppEnvironment.fake(kind: .unitTest, xai: xai)
        // Launch: `inactive`, then `start()` from the root `.task`, then `active`.
        environment.handleScenePhase(.inactive)
        await environment.start()
        environment.handleScenePhase(.active)
        await environment.xaiRefresh?.value
        #expect(environment.xai.account.status == .noKey)

        // iCloud Keychain delivers a key while the app is in the background.
        environment.handleScenePhase(.inactive)
        environment.handleScenePhase(.background)
        try await store.save(try XAIAPIKey(validating: fakeKeyRaw))
        #expect(!environment.xai.account.hasKey)

        environment.handleScenePhase(.inactive)
        environment.handleScenePhase(.active)
        await environment.xaiRefresh?.value
        #expect(environment.xai.account.hasKey)
    }
}

/// A key store whose `save` waits for `releaseSave()`, to hold the DEBUG
/// developer key seeding in the middle of its Keychain write.
private final class GatedSaveAPIKeyStore: APIKeyStore {
    private struct State {
        var key: XAIAPIKey?
        var pendingSave: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let state = Mutex(State())
    private let savePending: AsyncStream<Void>
    private let savePendingContinuation: AsyncStream<Void>.Continuation

    init() {
        (savePending, savePendingContinuation) = AsyncStream<Void>.makeStream()
    }

    func load() async throws(APIKeyStoreError) -> XAIAPIKey? {
        state.withLock { $0.key }
    }

    func save(_ newKey: XAIAPIKey) async throws(APIKeyStoreError) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.isReleased { return true }
                state.pendingSave = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            } else {
                savePendingContinuation.yield()
            }
        }
        state.withLock { $0.key = newKey }
    }

    func delete() async throws(APIKeyStoreError) {
        state.withLock { $0.key = nil }
    }

    /// Returns once a `save` is waiting to be released.
    func waitUntilASaveIsPending() async {
        var pending = savePending.makeAsyncIterator()
        _ = await pending.next()
    }

    /// Lets the pending `save` (and every later one) finish.
    func releaseSave() {
        let pending = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isReleased = true
            defer { state.pendingSave = nil }
            return state.pendingSave
        }
        pending?.resume()
    }
}

@Suite("Scene phase handling")
@MainActor
struct ScenePhaseHandlingTests {
    @Test func mapsScenePhases() {
        #expect(AppPhase(ScenePhase.active) == .active)
        #expect(AppPhase(ScenePhase.inactive) == .inactive)
        #expect(AppPhase(ScenePhase.background) == .background)
    }

    @Test func phaseChangesReachEveryService() async throws {
        let environment = AppEnvironment.preview()
        environment.handleScenePhase(.active)
        environment.handleScenePhase(.active)
        environment.handleScenePhase(.inactive)
        environment.handleScenePhase(.background)
        await environment.lifecycle.waitUntilDelivered()

        let expected = [
            AppPhaseTransition(from: nil, to: .active),
            AppPhaseTransition(from: .active, to: .inactive),
            AppPhaseTransition(from: .inactive, to: .background),
        ]
        #expect(environment.lifecycle.history == expected)
        #expect(try #require(environment.audio as? FakeAudioService).receivedTransitions == expected)
        #expect(try #require(environment.transcriber as? FakeTranscriber).receivedTransitions == expected)
        #expect(try #require(environment.voiceGate as? FakeVoiceGate).receivedTransitions == expected)
        #expect(try #require(environment.realtime as? FakeRealtimeService).receivedTransitions == expected)
        #expect(try #require(environment.topics as? FakeTopicService).receivedTransitions == expected)
        #expect(try #require(environment.memory as? FakeMemoryService).receivedTransitions == expected)
    }

    @Test func backgroundingSavesPendingEdits() async throws {
        let environment = AppEnvironment.preview()
        let context = environment.modelContainer.mainContext
        environment.handleScenePhase(.active)
        context.insert(Conversation(startedAt: .distantPast))
        #expect(context.hasChanges)

        environment.handleScenePhase(.background)
        await environment.lifecycle.waitUntilDelivered()
        #expect(!context.hasChanges)
    }
}

/// Hosts the app's views with the preview environment, the same way Xcode
/// previews do, to prove they find everything they read in the environment.
@Suite("Views with the preview environment")
@MainActor
struct PreviewEnvironmentRenderingTests {
    private func host(_ view: some View) throws -> UIView {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host app has no window scene"
        )
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller.view
    }

    @Test func rootViewRenders() throws {
        let view = try host(RootView().appEnvironment(.preview()))
        #expect(view.bounds.size == CGSize(width: 393, height: 852))
        #expect(!view.subviews.isEmpty)
    }

    @Test func debugMenuRendersWithOverrides() throws {
        let view = try host(DebugMenuView().appEnvironment(.preview(flags: [.perfHUD: true])))
        #expect(!view.subviews.isEmpty)
    }

    @Test func flagTogglesRenderForAReleaseStyleStore() throws {
        let flags = FeatureFlags(storage: InMemoryFeatureFlagStorage(), allowsOverrides: false)
        let view = try host(Form { FeatureFlagToggles(flags: flags) })
        #expect(!view.subviews.isEmpty)
    }
}
