import BlauCore
import BlauTelemetry
import Testing

@testable import BlauTranscription

/// The background inference decision table and the runtime escalation
/// rules (docs/background.md).
@Suite("Background inference policy")
struct BackgroundInferencePolicyTests {
    static let vad = BackgroundInferencePolicy.Stage(
        name: "vad", ladder: [.neuralEngine, .cpu], budget: .milliseconds(256))
    static let asr = BackgroundInferencePolicy.Stage(
        name: "asr", ladder: [.neuralEngine, .cpu, .systemSpeech], budget: .milliseconds(320))

    static func policy(
        _ mitigation: BackgroundInferenceMitigation = .keepNeuralEngine,
        stages: [BackgroundInferencePolicy.Stage] = [vad, asr]
    ) -> BackgroundInferencePolicy {
        var policy = BackgroundInferencePolicy(configuration: .init(mitigation: mitigation))
        for stage in stages {
            #expect(policy.register(stage) == nil)
        }
        return policy
    }

    /// Feeds `count` completed inferences of `latency` to `stage`.
    static func feed(
        _ policy: inout BackgroundInferencePolicy, _ stage: String, latency: Duration, count: Int
    ) -> [BackgroundInferencePolicy.Change] {
        (0..<count).compactMap { _ in policy.observe(.completed(stage, latency: latency)) }
    }

    static func fail(_ policy: inout BackgroundInferencePolicy, _ stage: String, count: Int)
        -> [BackgroundInferencePolicy.Change]
    {
        (0..<count).compactMap { _ in policy.observe(.init(stage: stage, outcome: .failed(description: "E5RT"))) }
    }

    /// Performs every pending switch successfully, as the monitor would.
    static func settle(_ policy: inout BackgroundInferencePolicy) {
        while let (stage, backend) = policy.pendingSwitch() {
            policy.switchCompleted(stage: stage, to: backend)
        }
    }

    // MARK: The decision table

    @Test(
        "Where each mitigation starts a stage off screen",
        arguments: [
            (
                BackgroundInferenceMitigation.keepNeuralEngine, InferenceBackend.neuralEngine,
                InferenceBackend.neuralEngine
            ),
            (.acceptCPUFallback, .neuralEngine, .neuralEngine),
            (.reloadOnCPUWhenBackgrounded, .cpu, .cpu),
            (.switchToSystemTranscriber, .cpu, .systemSpeech),
            (.fixBackgroundExecution, .neuralEngine, .neuralEngine),
            (.rerunProbe, .neuralEngine, .neuralEngine),
        ])
    func mitigationTable(
        mitigation: BackgroundInferenceMitigation, vad: InferenceBackend, asr: InferenceBackend
    ) {
        #expect(mitigation.backgroundBackend(ladder: Self.vad.ladder) == vad)
        #expect(mitigation.backgroundBackend(ladder: Self.asr.ladder) == asr)
        // A stage that only has the Neural Engine stays there.
        #expect(mitigation.backgroundBackend(ladder: [.neuralEngine]) == .neuralEngine)
    }

    @Test func shipsWithTheProvisionalMitigation() {
        // Until the probe has run on iOS 27 iPhones (docs/benchmarks.md).
        #expect(BackgroundInferenceMitigation.shipping == .keepNeuralEngine)
        #expect(BackgroundInferencePolicy.Configuration.standard.mitigation == .shipping)
        #expect(BackgroundInferencePolicy.Configuration.standard.budgetShare == 0.8)
    }

    @Test func stagesAreOrderedPreferredFirst() {
        let stage = BackgroundInferencePolicy.Stage(name: "x", ladder: [.cpu, .neuralEngine], budget: .seconds(1))
        #expect(stage.ladder == [.neuralEngine, .cpu])
        #expect(stage.current == .neuralEngine)
        #expect(InferenceBackend.neuralEngine < .cpu && InferenceBackend.cpu < .systemSpeech)
    }

    // MARK: Phases

    @Test func leavingTheScreenAppliesTheMitigationAndReturningUndoesIt() {
        var policy = Self.policy(.switchToSystemTranscriber)
        let leaving = policy.setPhase(.background)
        #expect(
            leaving == [
                .init(stage: "vad", from: .neuralEngine, to: .cpu, reason: .leftForeground(.switchToSystemTranscriber)),
                .init(
                    stage: "asr", from: .neuralEngine, to: .systemSpeech,
                    reason: .leftForeground(.switchToSystemTranscriber)),
            ])
        #expect(policy.pendingSwitch()! == ("vad", .cpu))
        Self.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .systemSpeech)

        let returning = policy.setPhase(.foreground)
        #expect(returning.map(\.to) == [.neuralEngine, .neuralEngine])
        #expect(returning.allSatisfy { $0.reason == .returnedToForeground })
        Self.settle(&policy)
        #expect(policy.statuses.allSatisfy { $0.current == .neuralEngine })
    }

    @Test func keepingTheNeuralEngineMovesNothing() {
        var policy = Self.policy(.keepNeuralEngine)
        #expect(policy.setPhase(.background).isEmpty)
        #expect(policy.setPhase(.locked).isEmpty)
        #expect(policy.phase == .locked)
        #expect(policy.setPhase(.foreground).isEmpty)
        #expect(policy.pendingSwitch() == nil)
    }

    @Test func lockingWhileOffScreenChangesNothing() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded)
        #expect(policy.setPhase(.background).count == 2)
        Self.settle(&policy)
        #expect(policy.setPhase(.locked).isEmpty)
        #expect(policy.setPhase(.background).isEmpty)
        #expect(policy.statuses.allSatisfy { $0.current == .cpu })
    }

    @Test func registeringOffScreenMovesTheStageAtOnce() {
        var policy = BackgroundInferencePolicy(configuration: .init(mitigation: .reloadOnCPUWhenBackgrounded))
        _ = policy.setPhase(.locked)
        let change = policy.register(Self.vad)
        #expect(change?.to == .cpu)
        #expect(change?.reason == .leftForeground(.reloadOnCPUWhenBackgrounded))
    }

    // MARK: Errors

    @Test func errorsOffScreenMoveTheStageDownItsLadder() {
        var policy = Self.policy()
        _ = policy.setPhase(.locked)

        #expect(Self.fail(&policy, "asr", count: 1).isEmpty)
        let toCPU = Self.fail(&policy, "asr", count: 1)
        #expect(
            toCPU == [.init(stage: "asr", from: .neuralEngine, to: .cpu, reason: .errors(count: 2, lastError: "E5RT"))])
        // Nothing more is decided while the switch is pending.
        #expect(Self.fail(&policy, "asr", count: 3).isEmpty)
        Self.settle(&policy)

        let toSystem = Self.fail(&policy, "asr", count: 2)
        #expect(toSystem.map(\.to) == [.systemSpeech])
        Self.settle(&policy)

        // Nowhere left: the stage is exhausted and stays.
        #expect(Self.fail(&policy, "asr", count: 5).isEmpty)
        let status = policy.status(of: "asr")
        #expect(status?.current == .systemSpeech)
        #expect(status?.isExhausted == true)
        #expect(status?.failedInferences == 12)
    }

    @Test func aSuccessResetsTheErrorCount() {
        var policy = Self.policy()
        _ = policy.setPhase(.background)
        _ = Self.fail(&policy, "vad", count: 1)
        _ = Self.feed(&policy, "vad", latency: .milliseconds(5), count: 1)
        #expect(Self.fail(&policy, "vad", count: 1).isEmpty)
        #expect(policy.status(of: "vad")?.consecutiveErrors == 1)
    }

    @Test func errorsOnScreenAreOnlyCounted() {
        var policy = Self.policy()
        #expect(Self.fail(&policy, "vad", count: 10).isEmpty)
        #expect(policy.status(of: "vad")?.current == .neuralEngine)
        #expect(policy.status(of: "vad")?.failedInferences == 10)
    }

    // MARK: Latency

    @Test func tooSlowOffScreenMovesTheStage() throws {
        var policy = Self.policy()
        _ = policy.setPhase(.background)
        // VAD budget: 80% of 256 ms = 204.8 ms. Two warm-up inferences are
        // ignored, then twenty at 250 ms.
        let changes = Self.feed(&policy, "vad", latency: .milliseconds(250), count: 22)
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.to == .cpu)
        #expect(change.reason == .tooSlow(p95Milliseconds: 250, budgetMilliseconds: 204.8))
    }

    @Test func withinBudgetNothingMoves() {
        var policy = Self.policy()
        _ = policy.setPhase(.locked)
        #expect(Self.feed(&policy, "vad", latency: .milliseconds(200), count: 100).isEmpty)
        #expect(Self.feed(&policy, "asr", latency: .milliseconds(250), count: 100).isEmpty)
        #expect(policy.status(of: "vad")?.recentP95Milliseconds == 200)
    }

    @Test func aFewSlowInferencesDontMoveTheStage() {
        var policy = Self.policy()
        _ = policy.setPhase(.locked)
        // One slow inference in 25 (4%) is under the p95, from the first
        // judgement on.
        for index in 0..<400 {
            let latency: Duration = index.isMultiple(of: 25) ? .milliseconds(900) : .milliseconds(40)
            #expect(policy.observe(.completed("asr", latency: latency)) == nil)
        }
    }

    @Test func slowOnScreenIsOnlyMeasured() {
        var policy = Self.policy()
        #expect(Self.feed(&policy, "vad", latency: .seconds(1), count: 50).isEmpty)
        #expect(policy.status(of: "vad")?.recentP95Milliseconds == 1_000)
    }

    @Test func eachPhaseIsJudgedOnItsOwnInferences() {
        var policy = Self.policy()
        // Slow on screen (a thermal spike, say) doesn't count off screen.
        _ = Self.feed(&policy, "vad", latency: .milliseconds(250), count: 30)
        _ = policy.setPhase(.background)
        #expect(policy.status(of: "vad")?.recentP95Milliseconds == nil)
        #expect(Self.feed(&policy, "vad", latency: .milliseconds(250), count: 21).isEmpty)
        #expect(Self.feed(&policy, "vad", latency: .milliseconds(250), count: 1).count == 1)
    }

    @Test func inferencesDuringASwitchAreIgnoredAndTheNewBackendWarmsUp() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded)
        _ = policy.setPhase(.background)
        // Still running on the Neural Engine while the CPU model loads.
        #expect(Self.feed(&policy, "vad", latency: .seconds(1), count: 30).isEmpty)
        #expect(policy.status(of: "vad")?.recentP95Milliseconds == nil)
        Self.settle(&policy)
        _ = Self.feed(&policy, "vad", latency: .milliseconds(900), count: 2)  // warm-up
        _ = Self.feed(&policy, "vad", latency: .milliseconds(20), count: 10)
        #expect(policy.status(of: "vad")?.recentP95Milliseconds == 20)
    }

    // MARK: Switch failures

    @Test func aFailedSwitchOffScreenTriesTheNextBackend() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded)
        _ = policy.setPhase(.background)
        let next = policy.switchFailed(stage: "asr", backend: .cpu, error: "load failed")
        #expect(
            next
                == .init(stage: "asr", from: .cpu, to: .systemSpeech, reason: .switchFailed(.cpu, error: "load failed"))
        )
        #expect(policy.status(of: "asr")?.unusable == [.cpu])
        #expect(policy.pendingSwitch()! == ("vad", .cpu))
    }

    @Test func aFailedSwitchWithNothingLeftStaysPut() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded, stages: [Self.vad])
        _ = policy.setPhase(.background)
        let change = policy.switchFailed(stage: "vad", backend: .cpu, error: "load failed")
        #expect(change?.to == .neuralEngine)
        #expect(policy.pendingSwitch() == nil)
        #expect(policy.status(of: "vad")?.isExhausted == true)

        // Back on screen everything is retried next time.
        _ = policy.setPhase(.foreground)
        #expect(policy.status(of: "vad")?.unusable == [])
        #expect(policy.status(of: "vad")?.isExhausted == false)
        #expect(policy.setPhase(.background).map(\.to) == [.cpu])
    }

    @Test func exhaustionOffScreenIsCountedAcrossPhases() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded, stages: [Self.vad])
        _ = policy.setPhase(.locked)
        _ = policy.switchFailed(stage: "vad", backend: .cpu, error: "load failed")
        #expect(policy.status(of: "vad")?.exhaustedOffScreen == 1)
        // Staying exhausted (locked -> background) doesn't count again.
        _ = policy.setPhase(.background)
        #expect(Self.fail(&policy, "vad", count: 4).isEmpty)
        #expect(policy.status(of: "vad")?.exhaustedOffScreen == 1)

        // Unlocking clears `isExhausted` but not the count.
        _ = policy.setPhase(.foreground)
        #expect(policy.status(of: "vad")?.isExhausted == false)
        #expect(policy.status(of: "vad")?.exhaustedOffScreen == 1)

        // A second trip that runs out again counts again.
        _ = policy.setPhase(.locked)
        _ = policy.switchFailed(stage: "vad", backend: .cpu, error: "load failed")
        #expect(policy.status(of: "vad")?.exhaustedOffScreen == 2)
    }

    @Test func failingToReturnToTheNeuralEngineKeepsTheCPU() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded, stages: [Self.vad])
        _ = policy.setPhase(.background)
        Self.settle(&policy)
        _ = policy.setPhase(.foreground)
        let change = policy.switchFailed(stage: "vad", backend: .neuralEngine, error: "compile failed")
        #expect(change?.to == .cpu)
        #expect(policy.pendingSwitch() == nil)
        #expect(policy.status(of: "vad")?.current == .cpu)
    }

    @Test func aFailureForASupersededSwitchIsIgnored() {
        var policy = Self.policy(.reloadOnCPUWhenBackgrounded, stages: [Self.vad])
        _ = policy.setPhase(.background)
        _ = policy.setPhase(.foreground)  // Back before the CPU switch ran.
        #expect(policy.pendingSwitch() == nil)
        #expect(policy.switchFailed(stage: "vad", backend: .cpu, error: "late") == nil)
    }

    // MARK: Learning

    @Test func theNextTripOffScreenStartsWhereTheLastOneEnded() {
        var policy = Self.policy()
        _ = policy.setPhase(.locked)
        _ = Self.fail(&policy, "asr", count: 2)
        Self.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .cpu)

        _ = policy.setPhase(.foreground)
        Self.settle(&policy)
        #expect(policy.status(of: "asr")?.current == .neuralEngine)
        #expect(policy.status(of: "asr")?.nextBackgroundBackend == .cpu)
        // The VAD never needed to move.
        #expect(policy.status(of: "vad")?.nextBackgroundBackend == .neuralEngine)

        let leaving = policy.setPhase(.background)
        #expect(
            leaving == [.init(stage: "asr", from: .neuralEngine, to: .cpu, reason: .leftForeground(.keepNeuralEngine))])
    }

    @Test func unknownStagesAreIgnored() {
        var policy = Self.policy()
        _ = policy.setPhase(.background)
        #expect(Self.fail(&policy, "nope", count: 5).isEmpty)
        policy.unregister("vad")
        #expect(policy.stageNames == ["asr"])
        #expect(policy.status(of: "vad") == nil)
    }

    @Test func p95() {
        #expect(BackgroundInferencePolicy.p95([]) == nil)
        #expect(BackgroundInferencePolicy.p95([7]) == 7)
        #expect(BackgroundInferencePolicy.p95((1...20).map(Double.init)) == 19)
        #expect(BackgroundInferencePolicy.p95((1...100).map(Double.init)) == 95)
    }
}
