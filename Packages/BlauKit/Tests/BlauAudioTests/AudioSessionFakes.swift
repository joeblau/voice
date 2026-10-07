import AVFAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization

@testable import BlauAudio

/// Bridges to an `NSError` with this code, like AVFoundation's errors.
struct FakeAudioError: Error, Equatable, CustomNSError {
    static let errorDomain = "FakeAudioError"

    var code = -50

    var errorCode: Int { code }
}

extension AudioRoute {
    static let speaker = AudioRoute(
        inputs: [AudioPort(kind: .builtInMic, name: "iPhone Microphone", uid: "mic")],
        outputs: [AudioPort(kind: .builtInSpeaker, name: "Speaker", uid: "spk")]
    )

    static let airPods = AudioRoute(
        inputs: [AudioPort(kind: .bluetoothHFP, name: "AirPods Pro", uid: "pods-hfp")],
        outputs: [AudioPort(kind: .bluetoothHFP, name: "AirPods Pro", uid: "pods-hfp")]
    )
}

// MARK: - Session

/// A scriptable `AVAudioSession`.
final class FakeAudioSession: AudioSessionBackend {
    enum Call: Equatable {
        case configure(AudioSessionConfiguration)
        case activate
        case deactivate
    }

    private struct State {
        var calls: [Call] = []
        var route: AudioRoute = .speaker
        var isConfigured = true
        var configureFailures = 0
        var activationFailures = 0
    }

    private let state = Mutex(State())
    let events: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var activations: Int { calls.count { $0 == .activate } }
    var deactivations: Int { calls.count { $0 == .deactivate } }

    var route: AudioRoute {
        get { state.withLock { $0.route } }
        set { state.withLock { $0.route = newValue } }
    }

    var reportsConfigured: Bool {
        get { state.withLock { $0.isConfigured } }
        set { state.withLock { $0.isConfigured = newValue } }
    }

    /// The next `count` calls to `activate()` throw.
    func failActivations(_ count: Int) {
        state.withLock { $0.activationFailures = count }
    }

    func failConfigurations(_ count: Int) {
        state.withLock { $0.configureFailures = count }
    }

    /// Posts an event as the system would.
    func send(_ event: AudioSessionEvent) {
        continuation.yield(event)
    }

    func configure(_ configuration: AudioSessionConfiguration) throws {
        try state.withLock { state in
            state.calls.append(.configure(configuration))
            if state.configureFailures > 0 {
                state.configureFailures -= 1
                throw FakeAudioError()
            }
        }
    }

    func isConfigured(for configuration: AudioSessionConfiguration) -> Bool {
        state.withLock { $0.isConfigured }
    }

    func activate() throws {
        try state.withLock { state in
            state.calls.append(.activate)
            if state.activationFailures > 0 {
                state.activationFailures -= 1
                throw FakeAudioError(code: 561_017_449)  // '!pri': insufficient priority
            }
        }
    }

    func deactivate() throws {
        state.withLock { $0.calls.append(.deactivate) }
    }

    var currentRoute: AudioRoute { route }
}

// MARK: - Engine

/// A scriptable voice-processing engine.
final class FakeAudioEngine: AudioEngineBackend, Sendable {
    enum Call: Equatable {
        case prepare(voiceProcessing: VoiceProcessingConfiguration, components: Int)
        case start
        case stop
        case teardown
    }

    private struct State {
        var calls: [Call] = []
        var isRunning = false
        var startFailures = 0
        var prepareFailures = 0
        var installedComponents: [ObjectIdentifier] = []
    }

    private let state = Mutex(State())
    let configurationChanges: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (configurationChanges, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var starts: Int { calls.count { $0 == .start } }
    var prepares: Int {
        calls.count { call in
            if case .prepare = call { true } else { false }
        }
    }
    var installedComponents: [ObjectIdentifier] { state.withLock { $0.installedComponents } }

    var isRunning: Bool { state.withLock { $0.isRunning } }

    func failStarts(_ count: Int) {
        state.withLock { $0.startFailures = count }
    }

    func failPrepares(_ count: Int) {
        state.withLock { $0.prepareFailures = count }
    }

    /// What iOS does on a hardware format change: the engine stops itself
    /// and posts AVAudioEngineConfigurationChange.
    func simulateConfigurationChange() {
        state.withLock { $0.isRunning = false }
        continuation.yield()
    }

    /// The engine stops without a configuration-change notification.
    func simulateUnexpectedStop() {
        state.withLock { $0.isRunning = false }
    }

    func prepare(voiceProcessing: VoiceProcessingConfiguration, components: [any AudioGraphComponent]) throws {
        try state.withLock { state in
            state.calls.append(.prepare(voiceProcessing: voiceProcessing, components: components.count))
            if state.prepareFailures > 0 {
                state.prepareFailures -= 1
                throw FakeAudioError()
            }
            state.installedComponents = components.map(ObjectIdentifier.init)
        }
    }

    func start() throws {
        try state.withLock { state in
            state.calls.append(.start)
            if state.startFailures > 0 {
                state.startFailures -= 1
                throw FakeAudioError(code: -10_875)  // kAudioUnitErr_FailedInitialization
            }
            state.isRunning = true
        }
    }

    func stop() {
        state.withLock { state in
            state.calls.append(.stop)
            state.isRunning = false
        }
    }

    func teardown() {
        state.withLock { state in
            state.calls.append(.teardown)
            state.installedComponents = []
        }
    }
}

/// Makes engines and remembers them, so tests can reach the engine created
/// after a media-services reset.
final class FakeEngineFactory: Sendable {
    private let engines = Mutex<[FakeAudioEngine]>([])

    func make() -> FakeAudioEngine {
        let engine = FakeAudioEngine()
        engines.withLock { $0.append(engine) }
        return engine
    }

    var all: [FakeAudioEngine] { engines.withLock { $0 } }

    /// The engine the controller is using now.
    var current: FakeAudioEngine { all.last! }
}

// MARK: - Permission

/// Microphone permission with a prompt the test answers.
final class FakeMicrophonePermission: MicrophonePermissionProvider {
    private struct State {
        var status: MicrophonePermission
        var requests = 0
        var pending: CheckedContinuation<Bool, Never>?
        /// Answer the prompt immediately with this, or wait for `answer(_:)`
        /// when nil.
        var autoAnswer: Bool?
    }

    private let state: Mutex<State>

    init(_ status: MicrophonePermission = .granted, autoAnswer: Bool? = true) {
        state = Mutex(State(status: status, autoAnswer: autoAnswer))
    }

    var status: MicrophonePermission { state.withLock { $0.status } }
    var requests: Int { state.withLock { $0.requests } }
    var isPrompting: Bool { state.withLock { $0.pending != nil } }

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            let answer: Bool? = state.withLock { state in
                state.requests += 1
                if let answer = state.autoAnswer {
                    state.status = answer ? .granted : .denied
                    return answer
                }
                state.pending = continuation
                return nil
            }
            if let answer {
                continuation.resume(returning: answer)
            }
        }
    }

    /// Answers a pending prompt.
    func answer(_ granted: Bool) {
        let continuation = state.withLock { state in
            state.status = granted ? .granted : .denied
            let pending = state.pending
            state.pending = nil
            return pending
        }
        continuation?.resume(returning: granted)
    }

    func waitForPrompt() async {
        while !isPrompting {
            await Task.yield()
        }
    }
}

// MARK: - Graph component

final class RecordingComponent: AudioGraphComponent {
    func install(on engine: AVAudioEngine) throws {}
    func uninstall(from engine: AVAudioEngine) {}
}

// MARK: - Harness

/// A controller wired to fakes.
struct Harness {
    let controller: AudioSessionController
    let session: FakeAudioSession
    let engines: FakeEngineFactory
    let permission: FakeMicrophonePermission
    let clock: ManualClock
    let signposts: RecordingSignpostBackend

    var engine: FakeAudioEngine { engines.current }

    init(
        permission: FakeMicrophonePermission = FakeMicrophonePermission(),
        configuration: AudioSessionConfiguration = .voiceChat,
        retryDelays: [Duration] = [.zero, .milliseconds(100), .milliseconds(250)]
    ) {
        let session = FakeAudioSession()
        let engines = FakeEngineFactory()
        let clock = ManualClock()
        let signposts = RecordingSignpostBackend()
        self.session = session
        self.engines = engines
        self.permission = permission
        self.clock = clock
        self.signposts = signposts
        controller = AudioSessionController(
            session: session,
            permission: permission,
            configuration: configuration,
            clock: clock,
            recoveryPolicy: .init(retryDelays: retryDelays),
            signposter: Signposter(category: .audio, backend: signposts),
            makeEngine: { engines.make() }
        )
    }

    /// Starts the controller and checks that it is running.
    func startRunning() async {
        let state = await controller.start()
        precondition(state == .running, "Expected running, got \(state)")
    }

    /// Waits until the current engine has been started `count` times and is
    /// running, for rebuilds triggered through the event streams.
    func waitForEngineStarts(_ count: Int) async {
        while engine.starts < count || !engine.isRunning {
            await Task.yield()
        }
    }

    /// Waits until `predicate` holds for a published snapshot.
    func waitForSnapshot(where predicate: (AudioSessionSnapshot) -> Bool) async -> AudioSessionSnapshot? {
        for await snapshot in await controller.updates() where predicate(snapshot) {
            return snapshot
        }
        return nil
    }
}
