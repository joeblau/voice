import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

@Suite("AppleTranscriber: utterances from SpeechAnalyzer results")
struct AppleTranscriberTests {
    private func makeTranscriber(
        engine: ScriptedSpeechAnalyzerEngine = ScriptedSpeechAnalyzerEngine(),
        audio: any CaptureFrameSource = SilentCaptureSource(),
        voiceActivity: (any VoiceActivitySource)? = nil,
        vocabulary: (any RecognitionVocabularySource)? = nil,
        configuration: AppleTranscriberConfiguration = .standard,
        conversationID: ConversationID = ConversationID(),
        signposter: Signposter = .disabled(.asr),
        clock: any BlauClock = ManualClock()
    ) -> AppleTranscriber {
        AppleTranscriber(
            engine: engine, audio: audio, voiceActivity: voiceActivity, vocabulary: vocabulary,
            configuration: configuration, conversationID: conversationID, signposter: signposter, clock: clock)
    }

    // MARK: Committing

    @Test func aFinalizedSentenceIsCommittedAfterThePause() async throws {
        let conversation = ConversationID()
        let transcriber = makeTranscriber(conversationID: conversation)
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 2.0)
        await transcriber.receive(.volatile("Can you", from: 0, to: 2.0))
        await feeder.feed(to: 3.0)
        await transcriber.receive(.volatile("Can you remind", from: 0, to: 3.0))
        await feeder.feed(to: 4.0)
        await transcriber.receive(.volatile("Can you remind me", from: 0, to: 4.0))
        await feeder.feed(to: 4.9)
        await transcriber.receive(
            .final(
                [("Can", 1.02, 1.32), ("you", 1.32, 1.56), ("remind", 1.56, 1.98), ("me?", 1.98, 4.86)], from: 1.02,
                to: 4.92))
        #expect(transcriber.statistics.utterancesCommitted == 0)

        // 0.9 s after the last word ends (4.86 s).
        await feeder.feed(to: 5.74)
        #expect(transcriber.statistics.utterancesCommitted == 0)
        await feeder.feed(to: 5.78)
        #expect(transcriber.statistics.utterancesCommitted == 1)
        #expect(transcriber.statistics.commits[.silence] == 1)

        try await log.waitForFinals(1)
        let utterance = try #require(log.finals.first)
        #expect(utterance.text == "Can you remind me?")
        #expect(utterance.speaker == .user)
        #expect(utterance.conversationID == conversation)
        #expect(utterance.speakerDecision == nil)
        #expect(utterance.timeRange.start == .samples(streamOffset(1.02), sampleRate: 16_000))
        #expect(utterance.timeRange.end == .samples(streamOffset(4.86), sampleRate: 16_000))
        #expect(log.partials == ["Can you", "Can you remind", "Can you remind me", "Can you remind me?"])
        #expect(transcriber.statistics.finalizationRequests == 0)
    }

    @Test func sentencesWithAShortPauseBetweenThemAreOneUtterance() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 2.3)
        await transcriber.receive(.final("Let me think.", wordsFrom: 0.5, wordsTo: 2.0, to: 2.3))
        await feeder.feed(to: 2.8)
        // The next sentence starts 0.6 s later; its words show up before
        // the 0.9 s pause has passed.
        await transcriber.receive(.volatile("About that", from: 2.3, to: 2.8))
        await feeder.feed(to: 4.0)
        #expect(transcriber.statistics.utterancesCommitted == 0)
        await transcriber.receive(.final("About that for a moment.", wordsFrom: 2.6, wordsTo: 3.8, to: 4.0))
        await feeder.feed(to: 4.8)

        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["Let me think. About that for a moment."])
        #expect(log.finals[0].timeRange.start == .samples(streamOffset(0.5), sampleRate: 16_000))
        #expect(log.partials.last == "Let me think. About that for a moment.")
        #expect(log.partials.contains("Let me think. About that"))
    }

    @Test func aLongerPauseSplitsUtterances() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 2.5)
        await transcriber.receive(.final("Yes.", wordsFrom: 1.0, wordsTo: 1.4, to: 2.5))
        await feeder.feed(to: 4.0)
        await transcriber.receive(.final("Okay great.", wordsFrom: 3.0, wordsTo: 3.6, to: 4.0))
        await feeder.feed(to: 5.0)

        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["Yes.", "Okay great."])
        #expect(log.finals[1].timeRange.start == .samples(streamOffset(3.0), sampleRate: 16_000))
        #expect(transcriber.statistics.commits[.silence] == 2)
    }

    @Test func unchangedPendingWordsAreFinalizedOnRequest() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let transcriber = makeTranscriber(engine: engine)
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 1.0)
        await transcriber.receive(.volatile("Hello there", from: 0, to: 1.0))
        // Unchanged for 1.5 s of audio: ask for the final.
        await feeder.feed(to: 2.48)
        #expect(await engine.finalizationRequests.isEmpty)
        await feeder.feed(to: 2.52)
        #expect(await engine.finalizationRequests == [streamOffset(2.5)])
        #expect(transcriber.statistics.finalizationRequests == 1)

        // The engine finalizes on request; the pause is long over, so it
        // commits at once.
        await transcriber.receive(.final("Hello there.", wordsFrom: 0.4, wordsTo: 1.0, to: 2.6))
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["Hello there."])
        #expect(transcriber.statistics.unfinalizedCommits == 0)
    }

    @Test func wordsThatNeverGetFinalizedAreCommittedAfterTheTimeout() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let transcriber = makeTranscriber(engine: engine)
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 1.0)
        await transcriber.receive(.volatile("Hello there", from: 0, to: 1.0))
        await feeder.feed(to: 2.5)
        #expect(await engine.finalizationRequests.count == 1)
        await feeder.feed(to: 3.98)
        #expect(transcriber.statistics.utterancesCommitted == 0)
        await feeder.feed(to: 4.02)

        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["Hello there"])
        #expect(transcriber.statistics.unfinalizedCommits == 1)

        // The engine's late final for the same words isn't repeated, and
        // its next guess still covering them is dropped.
        await transcriber.receive(.final("Hello there.", wordsFrom: 0.3, wordsTo: 0.9, to: 4.1))
        await transcriber.receive(.volatile("Hello there", from: 0, to: 4.2))
        #expect(transcriber.statistics.staleResultsDropped == 2)

        // New speech after the committed audio is a new utterance.
        await feeder.feed(to: 5.0)
        await transcriber.receive(.final("How are you?", wordsFrom: 4.3, wordsTo: 4.9, to: 5.0))
        await feeder.feed(to: 6.0)
        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["Hello there", "How are you?"])
    }

    @Test func changingWordsPostponeTheFinalizationRequest() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let transcriber = makeTranscriber(engine: engine)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 1.0)
        await transcriber.receive(.volatile("I think", from: 0, to: 1.0))
        await feeder.feed(to: 2.0)
        await transcriber.receive(.volatile("I think we should", from: 0, to: 2.0))
        await feeder.feed(to: 3.4)
        #expect(await engine.finalizationRequests.isEmpty)
        await feeder.feed(to: 3.6)
        #expect(await engine.finalizationRequests.count == 1)
    }

    @Test func aLongMonologueIsCommittedAtTheLastSentenceWhenItGetsTooLong() async throws {
        var configuration = AppleTranscriberConfiguration.standard
        configuration.maximumUtteranceDuration = .seconds(5)
        let transcriber = makeTranscriber(configuration: configuration)
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 2.0)
        await transcriber.receive(.final("So the first thing.", wordsFrom: 0.5, wordsTo: 2.0))
        await feeder.feed(to: 2.6)
        await transcriber.receive(.volatile("Is the", from: 2.0, to: 2.6))
        await feeder.feed(to: 3.6)
        await transcriber.receive(.final("Is the hiring plan.", wordsFrom: 2.0, wordsTo: 3.6))
        await feeder.feed(to: 4.4)
        await transcriber.receive(.volatile("And then", from: 3.6, to: 4.4))
        await feeder.feed(to: 5.4)
        await transcriber.receive(.volatile("And then the", from: 3.6, to: 5.4))
        #expect(transcriber.statistics.utterancesCommitted == 0)
        await feeder.feed(to: 5.6)

        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["So the first thing. Is the hiring plan."])
        #expect(transcriber.statistics.commits[.maximumLength] == 1)
        // The words after the last sentence start the next utterance.
        #expect(log.partials.last == "And then the")

        await transcriber.receive(.final("And then the offers.", wordsFrom: 3.8, wordsTo: 5.6, to: 5.7))
        await feeder.feed(to: 6.6)
        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text).last == "And then the offers.")
        #expect(log.finals[1].timeRange.start >= log.finals[0].timeRange.end)
    }

    @Test func blankAndWhitespaceResultsAreIgnored() async throws {
        let transcriber = makeTranscriber()
        var feeder = AppleFeeder(transcriber)
        await feeder.feed(to: 1.0)
        await transcriber.receive(.volatile("  ", from: 0, to: 1.0))
        await transcriber.receive(.final([], from: 0, to: 1.0))
        await feeder.feed(to: 3.0)
        #expect(transcriber.statistics.utterancesCommitted == 0)
        #expect(transcriber.statistics.partialsEmitted == 0)
    }

    @Test func textIsNormalized() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)
        await feeder.feed(to: 2.0)
        await transcriber.receive(.final([(" Okay,", 1.0, 1.3), ("  great. ", 1.3, 1.6)], from: 1.0, to: 2.0))
        await feeder.feed(to: 3.0)
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["Okay, great."])
    }

    // MARK: VAD

    @Test func nothingCommitsWhileVADHearsSpeech() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 0.8, vad: [.started(at: 0.5)])
        await feeder.feed(to: 2.0)
        await transcriber.receive(.final("Well.", wordsFrom: 0.6, wordsTo: 1.0, to: 2.0))
        // VAD still hears speech (the speaker is mid-sentence and the
        // transcriber hasn't caught up): no commit despite the long gap.
        await feeder.feed(to: 4.0)
        #expect(transcriber.statistics.utterancesCommitted == 0)

        await feeder.feed(to: 4.2, vad: [.ended(from: 0.5, to: 3.5)])
        await transcriber.receive(.final("I was thinking.", wordsFrom: 2.2, wordsTo: 3.5, to: 4.2))
        await feeder.feed(to: 4.38)
        #expect(transcriber.statistics.utterancesCommitted == 0)
        await feeder.feed(to: 4.42)
        #expect(transcriber.statistics.utterancesCommitted == 1)

        try await log.waitForFinals(1)
        let utterance = try #require(log.finals.first)
        #expect(utterance.text == "Well. I was thinking.")
        // The onset and end from VAD.
        #expect(utterance.timeRange.start == .samples(streamOffset(0.5), sampleRate: 16_000))
        #expect(utterance.timeRange.end == .samples(streamOffset(3.5), sampleRate: 16_000))
    }

    @Test func aSentenceFinalizedAfterTheNextOneStartedEndsAtVADsPause() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 1.0, vad: [.started(at: 0.5)])
        await transcriber.receive(.volatile("Can you", from: 0, to: 1.0))
        await feeder.feed(to: 2.3, vad: [.ended(from: 0.5, to: 2.0)])
        // The next sentence starts 1.2 s later, before the engine
        // finalized the first one.
        await feeder.feed(to: 3.5, vad: [.started(at: 3.2)])
        await transcriber.receive(.volatile("Can you help yes", from: 0, to: 3.6))
        await feeder.feed(to: 3.6)
        #expect(transcriber.statistics.utterancesCommitted == 0)

        await transcriber.receive(.final("Can you help?", wordsFrom: 0.6, wordsTo: 2.0, to: 2.4))
        #expect(transcriber.statistics.utterancesCommitted == 1)
        await transcriber.receive(.volatile("Yes", from: 2.4, to: 4.0))
        await feeder.feed(to: 4.3, vad: [.ended(from: 3.2, to: 4.0)])
        await transcriber.receive(.final("Yes.", wordsFrom: 3.3, wordsTo: 3.8, to: 4.3))
        await feeder.feed(to: 5.0)

        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["Can you help?", "Yes."])
        #expect(log.finals[0].timeRange.start == .samples(streamOffset(0.5), sampleRate: 16_000))
        #expect(log.finals[0].timeRange.end == .samples(streamOffset(2.0), sampleRate: 16_000))
        #expect(log.finals[1].timeRange.start == .samples(streamOffset(3.2), sampleRate: 16_000))
        #expect(log.finals[1].timeRange.end == .samples(streamOffset(4.0), sampleRate: 16_000))
    }

    @Test func aFinalSpanningAPauseIsSplitAtTheResumedSpeech() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)

        await feeder.feed(to: 2.3, vad: [.started(at: 0.5)])
        await feeder.feed(to: 3.5, vad: [.ended(from: 0.5, to: 2.0)])
        await feeder.feed(to: 4.3, vad: [.started(at: 3.2)])
        await transcriber.receive(
            .final([("Hello", 0.5, 1.0), ("there.", 1.0, 2.0), ("Yes.", 3.3, 3.8)], from: 0.5, to: 4.0))
        #expect(transcriber.statistics.utterancesCommitted == 1)
        await feeder.feed(to: 5.0, vad: [.ended(from: 3.2, to: 4.0)])

        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["Hello there.", "Yes."])
        #expect(log.finals[1].timeRange.start == .samples(streamOffset(3.2), sampleRate: 16_000))
    }

    @Test func speechWithoutWordsIsForgotten() async throws {
        let transcriber = makeTranscriber()
        var feeder = AppleFeeder(transcriber)
        // Ten minutes of noise VAD takes for speech, which the engine never
        // transcribes.
        for second in stride(from: 0.0, to: 600.0, by: 2.0) {
            await feeder.feed(to: second + 1.0, vad: [.started(at: second)])
            await feeder.feed(to: second + 2.0, vad: [.ended(from: second, to: second + 1.0)])
        }
        #expect(await transcriber.rememberedSpeechSpans <= 16)
        #expect(transcriber.statistics.utterancesCommitted == 0)
    }

    @Test func endOfUtteranceIntervalsEndWithTheReason() async throws {
        let backend = RecordingSignpostBackend()
        let transcriber = makeTranscriber(signposter: Signposter(category: .asr, backend: backend))
        var feeder = AppleFeeder(transcriber)
        await feeder.feed(to: 1.0)
        await transcriber.receive(.volatile("Hi", from: 0, to: 1.0))
        await feeder.feed(to: 2.0)
        await transcriber.receive(.final("Hi.", wordsFrom: 0.5, wordsTo: 0.9, to: 2.0))
        await feeder.feed(to: 3.0)
        #expect(backend.openIntervals.isEmpty)
        #expect(backend.endMessages(of: "asr.eou") == ["silence"])
    }

    // MARK: Lifecycle

    @Test func startFeedsTheEngineAndStopCommitsWhatIsPending() async throws {
        let engine = ScriptedSpeechAnalyzerEngine(
            script: [
                .init(at: streamOffset(1.0), result: .volatile("first", from: 0, to: 1.0)),
                .init(at: streamOffset(2.0), result: .final("First thought.", wordsFrom: 0.4, wordsTo: 1.2, to: 2.0)),
                .init(at: streamOffset(4.0), result: .volatile("and another", from: 3.5, to: 4.0)),
            ],
            onFinish: [.final("And another.", wordsFrom: 3.6, wordsTo: 4.0, to: 4.1)])
        let source = SilentCaptureSource()
        let vocabulary = StaticRecognitionVocabulary(["Blau", " Grok ", "blau", ""])
        let transcriber = makeTranscriber(engine: engine, audio: source, vocabulary: vocabulary)
        let log = TranscriptLog(transcriber.events)

        try await transcriber.start()
        #expect(await transcriber.isRunning)
        #expect(await engine.sessions == 1)
        #expect(await engine.sessionContextualStrings == [["Blau", "Grok"]])
        #expect(source.lookbacks == [.zero])

        source.publish(to: 4.0)
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["First thought."])

        try await waitUntil { await transcriber.transcribedPosition == streamOffset(4.0) }
        await transcriber.stop()
        #expect(await transcriber.isRunning == false)
        #expect(await engine.finishes == 1)
        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["First thought.", "And another."])
        #expect(transcriber.statistics.commits[.stopped] == 1)
        #expect(await engine.appended == [0..<streamOffset(4.0)])

        await transcriber.finish()
        try await waitUntil { Int64(log.all.count) == transcriber.statistics.partialsEmitted + 2 }
    }

    @Test func theEndOfTheCaptureStreamCommitsAndEndsTheRun() async throws {
        let engine = ScriptedSpeechAnalyzerEngine(script: [
            .init(at: streamOffset(1.0), result: .volatile("bye", from: 0, to: 1.0))
        ])
        let source = SilentCaptureSource()
        let transcriber = makeTranscriber(engine: engine, audio: source)
        let log = TranscriptLog(transcriber.events)
        try await transcriber.start()
        source.publish(to: 1.2)
        source.finishFrames()
        try await waitUntil { await transcriber.isRunning == false }
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["bye"])
        #expect(transcriber.statistics.commits[.streamEnded] == 1)
    }

    @Test func resumingSkipsAudioBeforeThePositionAndReadsTheRestFromHistory() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let source = SilentCaptureSource()
        source.publish(to: 8.0)
        let transcriber = makeTranscriber(engine: engine, audio: source)
        let log = TranscriptLog(transcriber.events)

        try await transcriber.start(resumingAt: .seconds(5))
        #expect(source.lookbacks == [AppleTranscriberConfiguration.standard.maximumResumeLookback])
        source.publish(to: 9.0)
        try await waitUntil { await engine.appendedEnd == streamOffset(9.0) }
        // Only from the resume position on, without a gap.
        #expect(await engine.appended == [streamOffset(5.0)..<streamOffset(9.0)])
        #expect(transcriber.statistics.samplesSkipped == streamOffset(5.0))

        // A result reaching back before the position keeps only the words
        // after it.
        await engine.emit(.final([("Earlier", 4.0, 4.6), ("now.", 5.2, 5.6)], from: 4.0, to: 6.0))
        source.publish(to: 7.0 + 3.0)
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["now."])
        #expect(log.finals[0].timeRange.start == .samples(streamOffset(5.2), sampleRate: 16_000))
        await transcriber.finish()
    }

    @Test func speechAlreadyUnderwayWhenResumingStartsAtTheResumePosition() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let source = SilentCaptureSource()
        source.publish(to: 6.0)
        let vad = SettableVoiceActivity(isSpeechActive: true)
        let transcriber = makeTranscriber(engine: engine, audio: source, voiceActivity: vad)
        let log = TranscriptLog(transcriber.events)

        try await transcriber.start(resumingAt: .seconds(5))
        await engine.emit(.volatile("go on", from: 4.0, to: 5.8))
        // Trimmed: the guess reaches back before the position.
        await engine.emit(.volatile("go on", from: 5.0, to: 5.8))
        source.publish(to: 6.5)
        try await waitUntil { transcriber.statistics.partialsEmitted == 1 }
        vad.send(.ended(from: 5.0, to: 6.0))
        await engine.emit(.final("Go on.", wordsFrom: 5.1, wordsTo: 5.7, to: 6.5))
        source.publish(to: 7.5)
        try await log.waitForFinals(1)
        #expect(log.finals[0].timeRange.start == .samples(streamOffset(5.0), sampleRate: 16_000))
        await transcriber.finish()
    }

    @Test func aFailedSessionCommitsWhatItHadAndRestarts() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let source = SilentCaptureSource()
        let transcriber = makeTranscriber(engine: engine, audio: source)
        let log = TranscriptLog(transcriber.events)
        try await transcriber.start()
        source.publish(to: 1.0)
        await engine.emit(.volatile("half a", from: 0, to: 1.0))
        try await waitUntil { transcriber.statistics.partialsEmitted == 1 }
        await engine.fail(TestFailure.analyzerFailed)

        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["half a"])
        #expect(transcriber.statistics.commits[.recognizerFailure] == 1)
        source.publish(to: 1.2)
        try await waitUntil { transcriber.statistics.sessionsStarted == 2 }
        #expect(await engine.sessions == 2)
        #expect(await engine.cancels == 1)
        #expect(transcriber.statistics.engineFailures == 1)
        await transcriber.finish()
    }

    @Test func aStartFailureIsThrownAndNothingRuns() async throws {
        let engine = ScriptedSpeechAnalyzerEngine(startErrors: [AppleSpeechError.unsupportedLocale("xx")])
        let source = SilentCaptureSource()
        let transcriber = makeTranscriber(engine: engine, audio: source)
        await #expect(throws: AppleSpeechError.unsupportedLocale("xx")) {
            try await transcriber.start()
        }
        #expect(await transcriber.isRunning == false)
        #expect(source.subscriberCount == 0)
    }

    @Test func theVocabularyCanBeRefreshedMidSession() async throws {
        let engine = ScriptedSpeechAnalyzerEngine()
        let vocabulary = MutableVocabulary(["Acme"])
        let transcriber = makeTranscriber(engine: engine, vocabulary: vocabulary)
        try await transcriber.start()
        vocabulary.terms = ["Acme", "Paul Graham"]
        await transcriber.refreshVocabulary()
        await transcriber.refreshVocabulary()  // unchanged: not sent again
        #expect(await engine.updatedContextualStrings == [["Acme", "Paul Graham"]])
        #expect(await transcriber.contextualStrings == ["Acme", "Paul Graham"])
        await transcriber.finish()
    }

    @Test func startedAtComesFromTheCaptureClock() async throws {
        let clock = ManualClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let transcriber = makeTranscriber(clock: clock)
        let log = TranscriptLog(transcriber.events)
        var feeder = AppleFeeder(transcriber)
        await feeder.feed(to: 2.0)
        await transcriber.receive(.final("Hi.", wordsFrom: 1.0, wordsTo: 1.5, to: 2.0))
        await feeder.feed(to: 3.0)
        try await log.waitForFinals(1)
        // Committed when the audio reached 2.4 s, at "now"; the speech
        // started 1.4 s before that.
        #expect(abs(log.finals[0].startedAt.timeIntervalSinceReferenceDate - 998.6) < 0.001)
    }

    @Test func setConversationIDAppliesToLaterUtterances() async throws {
        let transcriber = makeTranscriber()
        let log = TranscriptLog(transcriber.events)
        let next = ConversationID()
        await transcriber.setConversationID(next)
        var feeder = AppleFeeder(transcriber)
        await feeder.feed(to: 2.0)
        await transcriber.receive(.final("Hi.", wordsFrom: 1.0, wordsTo: 1.5, to: 2.0))
        await feeder.feed(to: 3.0)
        try await log.waitForFinals(1)
        #expect(log.finals[0].conversationID == next)
    }
}

enum TestFailure: Error {
    case analyzerFailed
}

final class MutableVocabulary: RecognitionVocabularySource {
    private let state: Mutex<[String]>

    init(_ terms: [String]) {
        state = Mutex(terms)
    }

    var terms: [String] {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func recognitionVocabulary() async -> [String] { terms }
}

@Suite("SpeechAnalyzerResult")
struct SpeechAnalyzerResultTests {
    @Test func trimmingDropsWordsBeforeThePosition() {
        let result = SpeechAnalyzerResult.final(
            [("one", 1.0, 1.5), ("two", 1.5, 2.0), ("three", 2.0, 2.5)], from: 1, to: 3)
        let trimmed = result.trimmed(before: streamOffset(1.5))
        #expect(trimmed.text == "two three")
        #expect(trimmed.range == streamOffset(1.5)..<streamOffset(3))
        #expect(trimmed.firstWordStart == streamOffset(1.5))
        #expect(trimmed.lastWordEnd == streamOffset(2.5))
        #expect(result.trimmed(before: streamOffset(0.5)) == result)
        #expect(result.trimmed(before: streamOffset(3)).text.isEmpty)
    }

    @Test func aVolatileResultStartingBeforeThePositionIsDroppedWhole() {
        let result = SpeechAnalyzerResult.volatile("hello there", from: 0, to: 2)
        #expect(result.trimmed(before: streamOffset(1)).text.isEmpty)
        #expect(result.lastWordEnd == streamOffset(2))
    }
}
