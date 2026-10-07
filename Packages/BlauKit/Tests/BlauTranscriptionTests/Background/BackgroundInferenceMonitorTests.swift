import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// A model stage whose backend switches are scripted. As a VAD model it
/// throws on the Neural Engine while `restrictNeuralEngine` is set: what
/// iOS 27 might do to Core ML off screen.
actor FakeSwitchableStage: InferenceBackendSwitchable, SpeechProbabilityModel {
    nonisolated let inferenceStage: String
    nonisolated let supportedBackends: [InferenceBackend]
    nonisolated let chunkLength = 4_096

    private(set) var backend: InferenceBackend
    private(set) var switches: [InferenceBackend] = []
    private var failingSwitches: Set<InferenceBackend> = []
    var restrictNeuralEngine = false
    private(set) var calls: [InferenceBackend] = []

    struct NeuralEngineUnavailable: Error {}
    struct LoadFailed: Error {}

    init(
        _ stage: String, backends: [InferenceBackend] = [.neuralEngine, .cpu], current: InferenceBackend = .neuralEngine
    ) {
        inferenceStage = stage
        supportedBackends = backends
        backend = current
    }

    var inferenceBackend: InferenceBackend { backend }

    func failSwitches(to backend: InferenceBackend) {
        failingSwitches.insert(backend)
    }

    func setRestricted(_ restricted: Bool) {
        restrictNeuralEngine = restricted
    }

    func switchInferenceBackend(to backend: InferenceBackend) async throws {
        switches.append(backend)
        if failingSwitches.contains(backend) { throw LoadFailed() }
        self.backend = backend
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) throws -> Float {
        calls.append(backend)
        if backend == .neuralEngine, restrictNeuralEngine { throw NeuralEngineUnavailable() }
        return 0.02
    }

    func reset() {}
}

@Suite("Background inference monitor", .timeLimit(.minutes(1)))
struct BackgroundInferenceMonitorTests {
    let signposts = RecordingSignpostBackend()

    func monitor(_ mitigation: BackgroundInferenceMitigation = .keepNeuralEngine) -> BackgroundInferenceMonitor {
        BackgroundInferenceMonitor(
            configuration: .init(mitigation: mitigation),
            clock: ManualClock(),
            signposter: Signposter(category: .asr, backend: signposts)
        )
    }

    @Test func movesStagesOffTheNeuralEngineOffScreenAndBack() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        let vad = FakeSwitchableStage("vad")
        let asr = FakeSwitchableStage("asr", backends: [.neuralEngine, .cpu, .systemSpeech])
        await monitor.register(vad, budget: .milliseconds(256))
        await monitor.register(asr, budget: .milliseconds(320))
        #expect(await vad.switches.isEmpty)

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .active, to: .inactive))
        #expect(await vad.switches.isEmpty, "inactive (Control Center, the app switcher) changes nothing")

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        #expect(await vad.backend == .cpu)
        #expect(await asr.backend == .cpu)
        #expect(await monitor.snapshot.phase == .background)

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        #expect(await vad.backend == .neuralEngine)
        #expect(await asr.backend == .neuralEngine)
        #expect(await vad.switches == [.cpu, .neuralEngine])

        let snapshot = await monitor.snapshot
        #expect(snapshot.switches.map(\.to) == [.cpu, .cpu, .neuralEngine, .neuralEngine])
        #expect(snapshot.switches.allSatisfy { $0.error == nil })
        #expect(snapshot.switches.first?.reason == "left the foreground (reloadOnCPUWhenBackgrounded)")
        #expect(signposts.completedIntervals.filter { $0 == "inference.backendSwitch" }.count == 4)
    }

    @Test func lockingRefinesTheBackgroundPhase() async {
        let monitor = monitor()
        await monitor.setDeviceLocked(true)
        #expect(await monitor.snapshot.phase == .foreground, "locking on screen changes nothing")
        await monitor.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        #expect(await monitor.snapshot.phase == .locked)
        await monitor.setDeviceLocked(false)
        #expect(await monitor.snapshot.phase == .background)
    }

    @Test func recordedErrorsOffScreenMoveTheStage() async {
        let monitor = monitor()
        let asr = FakeSwitchableStage("asr", backends: [.neuralEngine, .cpu, .systemSpeech])
        await monitor.register(asr, budget: .milliseconds(320))
        await monitor.setPhase(.locked)
        #expect(await asr.switches.isEmpty)

        monitor.record(.failed("asr", error: FakeSwitchableStage.NeuralEngineUnavailable()))
        monitor.record(.failed("asr", error: FakeSwitchableStage.NeuralEngineUnavailable()))
        await monitor.waitUntilIdle()
        #expect(await asr.backend == .cpu)

        let status = await monitor.snapshot.stages.first
        #expect(status?.current == .cpu)
        #expect(status?.failedInferences == 2)
    }

    @Test func aSwitchThatFailsFallsThroughToTheNextBackend() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        let asr = FakeSwitchableStage("asr", backends: [.neuralEngine, .cpu, .systemSpeech])
        await asr.failSwitches(to: .cpu)
        await monitor.register(asr, budget: .milliseconds(320))
        await monitor.setPhase(.background)

        #expect(await asr.switches == [.cpu, .systemSpeech])
        #expect(await asr.backend == .systemSpeech)
        let records = await monitor.snapshot.switches
        #expect(records.map(\.error).map { $0 != nil } == [true, false])
        #expect(records.last?.reason.hasPrefix("switching to cpu failed") == true)
    }

    @Test func aStageWithNothingLeftStaysWhereItIs() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        let vad = FakeSwitchableStage("vad")
        await vad.failSwitches(to: .cpu)
        await monitor.register(vad, budget: .milliseconds(256))
        await monitor.setPhase(.background)
        #expect(await vad.switches == [.cpu])
        #expect(await vad.backend == .neuralEngine)
        #expect(await monitor.snapshot.stages.first?.isExhausted == true)
    }

    @Test func aQuickBounceEndsOnTheRightBackend() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        let vad = FakeSwitchableStage("vad")
        await monitor.register(vad, budget: .milliseconds(256))
        // Both changes race; whatever order the switches run in, the last
        // phase wins.
        async let leave: Void = monitor.setPhase(.background)
        async let back: Void = monitor.setPhase(.foreground)
        _ = await (leave, back)
        await monitor.waitUntilIdle()
        let phase = await monitor.snapshot.phase
        #expect(await vad.backend == (phase.isBackground ? .cpu : .neuralEngine))
    }

    @Test func registeringOffScreenSwitchesAtOnce() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        await monitor.setPhase(.locked)
        let vad = FakeSwitchableStage("vad")
        await monitor.register(vad, budget: .milliseconds(256))
        #expect(await vad.backend == .cpu)
        await monitor.unregister(stage: "vad")
        await monitor.setPhase(.foreground)
        #expect(await vad.backend == .cpu, "an unregistered stage is left alone")
    }

    @Test func publishesSnapshots() async {
        let monitor = monitor(.reloadOnCPUWhenBackgrounded)
        let vad = FakeSwitchableStage("vad")
        await monitor.register(vad, budget: .milliseconds(256))
        var updates = await monitor.updates().makeAsyncIterator()
        #expect(await updates.next()?.stages.first?.current == .neuralEngine)
        await monitor.setPhase(.background)
        var latest = await updates.next()
        while latest?.stages.first?.current != .cpu {
            latest = await updates.next()
        }
        #expect(latest?.phase == .background)
        #expect(latest?.mitigation == .reloadOnCPUWhenBackgrounded)
    }

    /// End to end with the VAD: Core ML starts throwing on the Neural
    /// Engine once the device locks; the monitor moves the model to the CPU
    /// and the segmenter keeps analysing; back on screen it returns to the
    /// Neural Engine.
    @Test func theVADSurvivesARestrictedNeuralEngine() async {
        let monitor = monitor()
        let model = FakeSwitchableStage("vad")
        await monitor.register(model, budget: .milliseconds(256))
        let segmenter = VoiceActivitySegmenter(
            model: model, configuration: Self.alwaysRunTheModel, signposter: .disabled(.asr),
            inferenceObserver: monitor)

        let frames = VoiceActivitySegmenterTests.frames(seconds: 12)
        let (first, rest) = (frames[..<150], frames[150...])  // 3 s on screen
        for frame in first { await segmenter.process(frame) }

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        await monitor.setDeviceLocked(true)
        await model.setRestricted(true)
        for frame in rest {
            await segmenter.process(frame)
            // Let the monitor act on each report before the next chunk, as
            // it would in real time (a chunk is 256 ms).
            await monitor.waitUntilIdle()
        }

        #expect(await model.backend == .cpu)
        let calls = await model.calls
        let failedOnNeuralEngine = calls.dropFirst(11).prefix { $0 == .neuralEngine }.count
        #expect(failedOnNeuralEngine == 2, "two errors in a row move the model")
        #expect(calls.last == .cpu)
        #expect(segmenter.statistics.modelFailures == 2)

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        #expect(await model.backend == .neuralEngine)
        #expect(await monitor.snapshot.stages.first?.nextBackgroundBackend == .cpu)
        await segmenter.finish()
    }

    static var alwaysRunTheModel: VoiceActivityConfiguration {
        var configuration = VoiceActivityConfiguration.standard
        configuration.modelSkipLevelDecibels = nil
        return configuration
    }
}
