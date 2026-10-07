import BlauCore
import BlauTelemetry
import Testing

@testable import BlauTranscription

/// The `minimal` performance level moves speech-to-text to Apple's
/// `SpeechTranscriber` (#75), through the background inference policy that
/// already owns backend switches.
@Suite("Performance level and inference backends", .timeLimit(.minutes(1)))
struct PerformanceLevelInferenceTests {
    typealias Policy = BackgroundInferencePolicyTests

    // MARK: Policy

    @Test func minimalMovesOnlyStagesThatCanRunOnSpeechTranscriber() {
        var policy = Policy.policy()
        let changes = policy.setPerformanceLevel(.minimal)
        #expect(changes.map(\.stage) == ["asr"], "the VAD has no system equivalent and stays put")
        #expect(changes.first?.to == .systemSpeech)
        #expect(changes.first?.reason == .performanceLevel(.minimal))
        #expect(changes.first?.reason.description == "the performance level is minimal")
        #expect(policy.pendingSwitch()?.backend == .systemSpeech)
        Policy.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .systemSpeech)
        #expect(policy.status(of: "vad")?.current == .neuralEngine)
    }

    @Test func reducedChangesNoBackend() {
        var policy = Policy.policy()
        #expect(policy.setPerformanceLevel(.reduced).isEmpty)
        #expect(policy.pendingSwitch() == nil)
        #expect(policy.performanceLevel == .reduced)
    }

    @Test func recoveringFromMinimalReturnsToWhereThePhasePutsTheStage() {
        var policy = Policy.policy(.reloadOnCPUWhenBackgrounded)
        _ = policy.setPerformanceLevel(.minimal)
        Policy.settle(&policy)

        // Off screen at minimal: still SpeechTranscriber.
        let offScreen = policy.setPhase(.locked)
        #expect(offScreen.map(\.stage) == ["vad"])
        Policy.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .systemSpeech)

        // The level recovers while locked: back to the mitigation's backend.
        let recovered = policy.setPerformanceLevel(.reduced)
        #expect(recovered.map(\.to) == [.cpu])
        Policy.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .cpu)

        _ = policy.setPhase(.foreground)
        Policy.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .neuralEngine)
    }

    @Test func theLevelStillAppliesWhenTheAppComesBackOnScreen() {
        var policy = Policy.policy()
        _ = policy.setPhase(.background)
        _ = policy.setPerformanceLevel(.minimal)
        Policy.settle(&policy)
        let changes = policy.setPhase(.foreground)
        #expect(changes.isEmpty, "minimal still holds ASR on SpeechTranscriber on screen")
        #expect(policy.status(of: "asr")?.current == .systemSpeech)
    }

    /// A trip off screen spent on SpeechTranscriber only because of the
    /// level isn't something the stage needed: the next trip starts where
    /// the mitigation says.
    @Test func aTripAtMinimalIsNotLearned() {
        var policy = Policy.policy()
        _ = policy.setPerformanceLevel(.minimal)
        _ = policy.setPhase(.locked)
        Policy.settle(&policy)
        _ = policy.setPhase(.foreground)
        _ = policy.setPerformanceLevel(.normal)
        Policy.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .neuralEngine)
        #expect(policy.status(of: "asr")?.nextBackgroundBackend == .neuralEngine)
    }

    @Test func aStageRegisteredAtMinimalStartsOnSpeechTranscriber() {
        var policy = BackgroundInferencePolicy(configuration: .init(mitigation: .keepNeuralEngine))
        _ = policy.setPerformanceLevel(.minimal)
        let change = policy.register(Policy.asr)
        #expect(change?.to == .systemSpeech)
        #expect(policy.register(Policy.vad) == nil)
    }

    @Test func aFailedMoveToSpeechTranscriberKeepsTheStageRunning() {
        var policy = Policy.policy()
        _ = policy.setPerformanceLevel(.minimal)
        let change = policy.switchFailed(stage: "asr", backend: .systemSpeech, error: "no locale")
        #expect(change?.to == .neuralEngine)
        #expect(policy.pendingSwitch() == nil)
        #expect(policy.status(of: "asr")?.unusable == [.systemSpeech])
    }

    // MARK: Monitor

    @Test func theMonitorPerformsTheSwitchesAndFollowsALevelStream() async throws {
        let monitor = BackgroundInferenceMonitor(
            configuration: .init(mitigation: .keepNeuralEngine), clock: ManualClock(),
            signposter: .disabled(.asr))
        let vad = FakeSwitchableStage("vad")
        let asr = FakeSwitchableStage("asr", backends: [.neuralEngine, .cpu, .systemSpeech])
        await monitor.register(vad, budget: .milliseconds(256))
        await monitor.register(asr, budget: .milliseconds(320))

        let levels = ManualPerformanceLevel(.normal)
        let follower = Task { await monitor.follow(levels.performanceLevels()) }
        defer { follower.cancel() }

        levels.set(.minimal)
        try await waitUntil { await asr.backend == .systemSpeech }
        #expect(await vad.switches.isEmpty)
        #expect(await monitor.performanceLevel == .minimal)
        let record = await monitor.snapshot.switches.last
        #expect(record?.to == .systemSpeech)
        #expect(record?.reason == "the performance level is minimal")

        levels.set(.normal)
        try await waitUntil { await asr.backend == .neuralEngine }
        #expect(await asr.switches == [.systemSpeech, .neuralEngine])
    }

    @Test func repeatingALevelDoesNothing() async {
        let monitor = BackgroundInferenceMonitor(clock: ManualClock(), signposter: .disabled(.asr))
        let asr = FakeSwitchableStage("asr", backends: [.neuralEngine, .cpu, .systemSpeech])
        await monitor.register(asr, budget: .milliseconds(320))
        await monitor.setPerformanceLevel(.minimal)
        await monitor.setPerformanceLevel(.minimal)
        #expect(await asr.switches == [.systemSpeech])
    }
}
