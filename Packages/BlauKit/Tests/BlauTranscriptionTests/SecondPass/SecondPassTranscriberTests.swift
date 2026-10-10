import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

@Suite("Second-pass transcriber")
struct SecondPassTranscriberTests {
    /// A second pass over `base` with the given recognizer, 30 s of indexed
    /// audio and a recording signposter.
    struct Harness {
        let base = ControlledTranscriber()
        let audio: FixtureAudioSource
        let signposts = RecordingSignpostBackend()
        let transcriber: SecondPassTranscriber
        let log: EventLog

        init(
            recognizer: any SecondPassRecognizer,
            isEnabled: @escaping @Sendable () -> Bool = { true },
            thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { .nominal },
            performance: (any PerformanceLevelProviding)? = nil,
            configuration: SecondPassConfiguration = .standard,
            audio: FixtureAudioSource = indexedAudio(seconds: 30)
        ) {
            self.init(
                provider: { recognizer }, isEnabled: isEnabled, thermalState: thermalState,
                performance: performance, configuration: configuration, audio: audio)
        }

        init(
            provider: @escaping SecondPassRecognizerProvider,
            isEnabled: @escaping @Sendable () -> Bool = { true },
            thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { .nominal },
            performance: (any PerformanceLevelProviding)? = nil,
            configuration: SecondPassConfiguration = .standard,
            audio: FixtureAudioSource = indexedAudio(seconds: 30)
        ) {
            self.audio = audio
            transcriber = SecondPassTranscriber(
                wrapping: base, audio: audio, recognizer: provider, isEnabled: isEnabled,
                thermalState: thermalState, performance: performance, configuration: configuration,
                signposter: Signposter(category: .asr, backend: signposts))
            log = EventLog(transcriber.events)
        }

        /// Ends the base stream and waits for every refinement.
        func finish() async {
            base.finish()
            await log.finished()
        }
    }

    // MARK: Refinement

    @Test func theFinalGoesOutAtOnceAndTheRefinedTextFollowsWithTheSameIdentity() async throws {
        let recognizer = ScriptedSecondPassRecognizer([.text("Can you remind me what we decided?")], held: true)
        let harness = Harness(recognizer: recognizer)
        let streaming = utterance("can you remind me what we decided", samples: 16_000..<48_000)

        harness.base.send(.partial(text: "can you", range: streaming.timeRange))
        harness.base.send(.final(streaming))
        // The final is out while the second pass is still running. The log
        // reads the output stream on its own task, so it can lag the
        // recognizer call: wait for both.
        try await waitUntil { await recognizer.callCount == 1 && harness.log.events.count == 2 }
        #expect(harness.log.events == [.partial(text: "can you", range: streaming.timeRange), .final(streaming)])
        #expect(await recognizer.completed == 0)
        #expect(harness.signposts.openIntervals == ["asr.secondPass"])

        await recognizer.release()
        await harness.finish()

        let refined = try #require(harness.log.refined.first)
        #expect(harness.log.events.count == 3)
        #expect(refined.id == streaming.id)
        #expect(refined.text == "Can you remind me what we decided?")
        #expect(refined.timeRange == streaming.timeRange)
        #expect(refined.speaker == streaming.speaker)
        #expect(refined.conversationID == streaming.conversationID)
        #expect(refined.startedAt == streaming.startedAt)
        #expect(harness.signposts.endMessages(of: "asr.secondPass") == ["refined"])
        #expect(harness.transcriber.statistics.utterancesRefined == 1)
        #expect(harness.transcriber.statistics.recognitions == 1)
    }

    /// The acceptance criterion "turn latency unchanged": a second pass that
    /// never finishes doesn't hold back a single partial or final.
    @Test func aStuckSecondPassDelaysNoOtherEvent() async throws {
        let recognizer = ScriptedSecondPassRecognizer(held: true, fallback: { _ in "Utterance number." })
        let harness = Harness(recognizer: recognizer)
        var sent: [TranscriptEvent] = []
        for index in 0..<20 {
            let start = Int64(index) * 16_000
            let streaming = utterance("utterance number \(index)", samples: start..<(start + 12_000))
            sent += [.partial(text: "utterance", range: streaming.timeRange), .final(streaming)]
        }
        for event in sent { harness.base.send(event) }

        let count = sent.count
        try await waitUntil { harness.log.events.count == count }
        #expect(harness.log.events == sent)
        #expect(await recognizer.completed == 0)

        await recognizer.release()
        await harness.finish()
        // Every final was passed on before any refinement.
        #expect(Array(harness.log.events.prefix(sent.count)) == sent)
        // One running, four waiting, the rest skipped as backlog.
        let statistics = harness.transcriber.statistics
        #expect(statistics.utterancesSubmitted == 20)
        #expect(statistics.utterancesRefined + statistics.skipped[.backlog, default: 0] == 20)
        #expect(statistics.skipped[.backlog, default: 0] >= 15)
    }

    @Test func readsTheUtterancesAudioWithPaddingButNeverThePreviousUtterance() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Fine." })
        let harness = Harness(recognizer: recognizer)
        // Padding 100 ms (1 600 samples) before, 120 ms (1 920) after.
        harness.base.send(.final(utterance("first one", samples: 32_000..<64_000)))
        // Starts 800 samples after the first ended: the padding stops there.
        harness.base.send(.final(utterance("second one", samples: 64_800..<80_000)))
        await harness.finish()

        let received = await recognizer.received
        try #require(received.count == 2)
        #expect(received[0].first == 30_400)
        #expect(received[0].last == 65_919)
        #expect(received[0].count == 65_920 - 30_400)
        #expect(received[1].first == 64_000)
        #expect(received[1].last == 81_919)
    }

    @Test func aRecentUtteranceUsesTheAudioReceivedSoFar() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Okay." })
        let audio = indexedAudio(seconds: 30)
        audio.position = 64_500
        let harness = Harness(recognizer: recognizer, audio: audio)
        harness.base.send(.final(utterance("okay", samples: 48_000..<64_000)))
        await harness.finish()

        let received = await recognizer.received
        #expect(received.first?.last == 64_499)
        #expect(harness.log.refined.map(\.text) == ["Okay."])
    }

    @Test func anUtteranceWhoseStartLeftTheHistoryKeepsItsStreamingText() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "In time." })
        // 40 s of audio, 30 s of history: the first 10 s are gone.
        let harness = Harness(recognizer: recognizer, audio: indexedAudio(seconds: 40))
        harness.base.send(.final(utterance("too late", samples: 100_000..<200_000)))
        harness.base.send(.final(utterance("in time", samples: 300_000..<320_000)))
        await harness.finish()

        #expect(await recognizer.callCount == 1)
        #expect(harness.log.refined.map(\.text) == ["In time."])
        #expect(harness.transcriber.statistics.skipped == [.audioUnavailable: 1])
    }

    @Test func theLongestUtteranceNeedsMoreThanTheDefaultHistory() {
        let required = SecondPassConfiguration.standard.requiredHistory(for: .standard)
        #expect(required == .milliseconds(32_100))
        #expect(required > CaptureHub.Configuration.standard.historyDuration)
    }

    @Test func aMaximumLengthUtteranceIsRefinedWithTheRequiredHistory() async throws {
        let streaming = StreamingTranscriberConfiguration.standard
        let history = SecondPassConfiguration.standard.requiredHistory(for: streaming)
        // 30 s of speech starting at 2 s, committed 1 s later than the cut.
        let start: Int64 = 32_000
        let end = start + streaming.maximumUtteranceDuration.sampleCount(sampleRate: 16_000)
        let audio = FixtureAudioSource(
            block: (0..<(40 * 16_000)).map(Float.init), historyDuration: history)
        audio.position = end + 16_000
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "A very long monologue." })
        let harness = Harness(recognizer: recognizer, audio: audio)
        harness.base.send(.final(utterance("a very long monologue", samples: start..<end)))
        await harness.finish()
        #expect(harness.log.refined.map(\.text) == ["A very long monologue."])
    }

    // MARK: When it is skipped

    @Test func theFeatureFlagTurnsItOffPerUtterance() async throws {
        let flags = FeatureFlags.inMemory([.secondPassASR: false])
        let provider = CountingProvider([.recognizer(ScriptedSecondPassRecognizer(fallback: { _ in "On." }))])
        let base = ControlledTranscriber()
        let transcriber = SecondPassTranscriber(
            wrapping: base, audio: indexedAudio(seconds: 30), recognizer: provider.provider, flags: flags,
            thermalState: { .nominal }, signposter: .disabled(.asr))
        let log = EventLog(transcriber.events)

        base.send(.final(utterance("off", samples: 0..<16_000)))
        try await waitUntil { transcriber.statistics.skipped[.disabled] == 1 }
        flags.setOverride(true, for: .secondPassASR)
        base.send(.final(utterance("on", samples: 16_000..<32_000)))
        base.finish()
        await log.finished()

        #expect(log.finals.map(\.text) == ["off", "on"])
        #expect(log.refined.map(\.text) == ["On."])
        #expect(provider.calls == 1)
        #expect(transcriber.statistics.skipped == [.disabled: 1])
    }

    @Test func theFlagIsOnByDefault() {
        #expect(FeatureFlags.inMemory().isEnabled(.secondPassASR))
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func itIsSkippedUnderThermalPressure(_ state: ProcessInfo.ThermalState) async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Hot." })
        let harness = Harness(recognizer: recognizer, thermalState: { state })
        harness.base.send(.final(utterance("hot", samples: 0..<16_000)))
        await harness.finish()

        #expect(await recognizer.callCount == 0)
        #expect(harness.log.refined.isEmpty)
        #expect(harness.transcriber.statistics.skipped == [.thermalPressure: 1])
        #expect(harness.signposts.records.isEmpty)
    }

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func itRunsWhenTheDeviceIsCool(_ state: ProcessInfo.ThermalState) async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Cool." })
        let harness = Harness(recognizer: recognizer, thermalState: { state })
        harness.base.send(.final(utterance("cool", samples: 0..<16_000)))
        await harness.finish()
        #expect(harness.log.refined.map(\.text) == ["Cool."])
    }

    @Test func aDeviceThatHeatsUpWhileAnUtteranceWaitsSkipsIt() async throws {
        let thermal = ThermalSwitch()
        let recognizer = ScriptedSecondPassRecognizer(held: true, fallback: { _ in "Text." })
        let harness = Harness(recognizer: recognizer, thermalState: { thermal.state })
        harness.base.send(.final(utterance("first", samples: 0..<16_000)))
        try await waitUntil { await recognizer.callCount == 1 }
        harness.base.send(.final(utterance("second", samples: 16_000..<32_000)))
        try await waitUntil { harness.log.finals.count == 2 }
        thermal.state = .serious
        await recognizer.release()
        await harness.finish()

        #expect(harness.log.refined.count == 1)
        #expect(harness.transcriber.statistics.skipped[.thermalPressure] == 1)
    }

    // MARK: Thermal and power policy (#75)

    @Test(arguments: [PerformanceLevel.reduced, .minimal])
    func itIsSkippedBelowTheNormalPerformanceLevel(_ level: PerformanceLevel) async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Saving power." })
        let harness = Harness(recognizer: recognizer, performance: FixedPerformanceLevel(level))
        harness.base.send(.final(utterance("saving power", samples: 0..<16_000)))
        await harness.finish()

        #expect(harness.log.finals.map(\.text) == ["saving power"], "the final still goes out")
        #expect(await recognizer.callCount == 0)
        #expect(harness.log.refined.isEmpty)
        #expect(harness.transcriber.statistics.skipped == [.reducedPerformance: 1])
        #expect(harness.signposts.records.isEmpty)
    }

    @Test func itRunsAgainOnceTheLevelIsBackToNormal() async throws {
        let performance = ManualPerformanceLevel(.reduced)
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Back." })
        let harness = Harness(recognizer: recognizer, performance: performance)
        harness.base.send(.final(utterance("skipped", samples: 0..<16_000)))
        try await waitUntil { harness.transcriber.statistics.skipped[.reducedPerformance] == 1 }
        performance.set(.normal)
        harness.base.send(.final(utterance("back", samples: 16_000..<32_000)))
        await harness.finish()

        #expect(harness.log.refined.map(\.text) == ["Back."])
        #expect(harness.transcriber.statistics.skipped == [.reducedPerformance: 1])
    }

    @Test func anUtteranceWaitingWhenTheLevelDropsIsSkipped() async throws {
        let performance = ManualPerformanceLevel(.normal)
        let recognizer = ScriptedSecondPassRecognizer(held: true, fallback: { _ in "Text." })
        let harness = Harness(recognizer: recognizer, performance: performance)
        harness.base.send(.final(utterance("first", samples: 0..<16_000)))
        try await waitUntil { await recognizer.callCount == 1 }
        harness.base.send(.final(utterance("second", samples: 16_000..<32_000)))
        try await waitUntil { harness.log.finals.count == 2 }
        performance.set(.reduced)
        await recognizer.release()
        await harness.finish()

        #expect(harness.log.refined.count == 1)
        #expect(harness.transcriber.statistics.skipped[.reducedPerformance] == 1)
    }

    @Test func withoutTheModelItWaitsUntilOneIsInstalled() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Installed." })
        let provider = CountingProvider([.notInstalled, .recognizer(recognizer)])
        let harness = Harness(provider: provider.provider)
        harness.base.send(.final(utterance("before", samples: 0..<16_000)))
        harness.base.send(.final(utterance("after", samples: 16_000..<32_000)))
        harness.base.send(.final(utterance("later", samples: 32_000..<48_000)))
        await harness.finish()

        #expect(harness.log.refined.map(\.text) == ["Installed.", "Installed."])
        // Loaded once and kept.
        #expect(provider.calls == 2)
        #expect(harness.transcriber.statistics.skipped == [.modelUnavailable: 1])
        #expect(harness.transcriber.statistics.recognizerLoads == 2)
    }

    @Test func aFailedLoadIsRetriedAfterTheRetryInterval() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Loaded." })
        let provider = CountingProvider([.failure, .recognizer(recognizer)])
        let harness = Harness(
            provider: provider.provider, configuration: SecondPassConfiguration(loadRetryInterval: 2))
        for index in 0..<4 {
            let start = Int64(index) * 16_000
            harness.base.send(.final(utterance("utterance \(index)", samples: start..<(start + 16_000))))
        }
        await harness.finish()

        // Utterance 0 fails to load, 1 and 2 don't try, 3 loads.
        #expect(provider.calls == 2)
        #expect(harness.log.refined.map(\.text) == ["Loaded."])
        #expect(harness.transcriber.statistics.skipped == [.modelUnavailable: 3])
    }

    @Test func aRecognizerFailureKeepsTheStreamingTextAndTheNextUtteranceIsRefined() async throws {
        let recognizer = ScriptedSecondPassRecognizer([.failure, .text("Second.")])
        let harness = Harness(recognizer: recognizer)
        harness.base.send(.final(utterance("first", samples: 0..<16_000)))
        harness.base.send(.final(utterance("second", samples: 16_000..<32_000)))
        await harness.finish()

        #expect(harness.log.refined.map(\.text) == ["Second."])
        #expect(harness.transcriber.statistics.skipped == [.failed: 1])
        #expect(harness.signposts.endMessages(of: "asr.secondPass") == ["failed", "refined"])
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func blankUnchangedAndDivergentTranscriptsKeepTheStreamingText() async throws {
        let recognizer = ScriptedSecondPassRecognizer([
            .text("   "),
            .text("exactly the same words"),
            .text("Something else entirely here."),
            .text("Yeah, no."),
        ])
        let harness = Harness(recognizer: recognizer)
        harness.base.send(.final(utterance("hello there", samples: 0..<16_000)))
        harness.base.send(.final(utterance("exactly the same words", samples: 16_000..<32_000)))
        harness.base.send(.final(utterance("we moved the launch to march", samples: 32_000..<48_000)))
        // Two words: below the word-change check, so even a different
        // reading is taken.
        harness.base.send(.final(utterance("yeah so", samples: 48_000..<64_000)))
        await harness.finish()

        #expect(harness.log.refined.map(\.text) == ["Yeah, no."])
        let statistics = harness.transcriber.statistics
        #expect(statistics.skipped == [.blank: 1, .diverged: 1])
        #expect(statistics.utterancesUnchanged == 1)
        #expect(statistics.utterancesRefined == 1)
        #expect(
            harness.signposts.endMessages(of: "asr.secondPass") == ["blank", "unchanged", "diverged", "refined"])
    }

    @Test func theRefinedTextIsTrimmed() async throws {
        let recognizer = ScriptedSecondPassRecognizer([.text("  Take   your time. ")])
        let harness = Harness(recognizer: recognizer)
        harness.base.send(.final(utterance("take your time", samples: 0..<16_000)))
        await harness.finish()
        #expect(harness.log.refined.map(\.text) == ["Take your time."])
    }

    @Test func aBacklogDropsTheOldestWaitingUtterance() async throws {
        let recognizer = ScriptedSecondPassRecognizer(
            held: true, fallback: { samples in "Starts at \(Int(samples[0]))." })
        let harness = Harness(
            recognizer: recognizer, configuration: SecondPassConfiguration(maximumPendingUtterances: 1))
        harness.base.send(.final(utterance("running", samples: 16_000..<32_000)))
        try await waitUntil { await recognizer.callCount == 1 }
        harness.base.send(.final(utterance("dropped", samples: 48_000..<64_000)))
        harness.base.send(.final(utterance("kept", samples: 80_000..<96_000)))
        try await waitUntil { harness.transcriber.statistics.skipped[.backlog] == 1 }
        await recognizer.release()
        await harness.finish()

        #expect(harness.log.finals.map(\.text) == ["running", "dropped", "kept"])
        #expect(harness.log.refined.map(\.text) == ["Starts at 14400.", "Starts at 78400."])
    }

    // MARK: Lifecycle

    @Test func startStopAndPhaseChangesReachTheStreamingTranscriber() async throws {
        let harness = Harness(recognizer: ScriptedSecondPassRecognizer())
        try await harness.transcriber.start()
        await harness.transcriber.appPhaseDidChange(AppPhaseTransition(from: .active, to: .background))
        await harness.transcriber.stop()
        #expect(harness.base.calls == ["start", "phase active → background", "stop"])
        await harness.finish()
    }

    @Test func eventsFinishOnlyAfterTheWaitingUtterancesAreRefined() async throws {
        let recognizer = ScriptedSecondPassRecognizer(held: true, fallback: { _ in "Done." })
        let harness = Harness(recognizer: recognizer)
        harness.base.send(.final(utterance("one", samples: 0..<16_000)))
        harness.base.send(.final(utterance("two", samples: 16_000..<32_000)))
        harness.base.finish()
        try await waitUntil { await recognizer.callCount == 1 }
        await recognizer.release()
        await harness.transcriber.waitUntilFinished()
        await harness.log.finished()

        #expect(harness.log.refined.map(\.text) == ["Done.", "Done."])
        guard case .refined = harness.log.events.last else {
            Issue.record("The stream finished before the refinements: \(harness.log.events)")
            return
        }
    }

    @Test func statisticsAddUp() async throws {
        let recognizer = ScriptedSecondPassRecognizer(fallback: { _ in "Yes." })
        let harness = Harness(recognizer: recognizer)
        harness.base.send(.final(utterance("yes", samples: 16_000..<24_000)))
        await harness.finish()

        let statistics = harness.transcriber.statistics
        #expect(statistics.utterancesSubmitted == 1)
        #expect(statistics.utterancesSkipped == 0)
        #expect(statistics.samplesTranscribed == 8_000 + 1_600 + 1_920)
        #expect(statistics.meanModelTime <= statistics.slowestUtterance)
        #expect(statistics.realTimeFactor >= 0)
    }
}

/// A thermal state a test changes while the transcriber runs.
final class ThermalSwitch: Sendable {
    private let value = Mutex(ProcessInfo.ThermalState.nominal)

    var state: ProcessInfo.ThermalState {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
