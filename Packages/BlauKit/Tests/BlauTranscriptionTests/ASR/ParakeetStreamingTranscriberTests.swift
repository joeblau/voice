import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// The transcriber's decisions on a simulated recognizer with Parakeet's
/// chunk timing and FluidAudio's end-of-utterance rule (hermetic: no model).
/// `ParakeetLiveTests` runs the same fixtures through the real model.
@Suite("Streaming transcriber")
struct ParakeetStreamingTranscriberTests {
    // MARK: Fixtures

    @Test(arguments: VADFixture.names)
    func everySentenceOfAFixtureIsCommittedWithinTheBudget(_ name: String) async throws {
        let fixture = try VADFixture.load(name)
        let script = try #require(FixtureScript.all[name])
        let recognizer = SimulatedEouRecognizer(words: script.words(over: fixture.labels))
        let source = FixtureAudioSource(block: fixture.samples)
        let transcriber = makeTranscriber(recognizer, source: source)

        let replay = await TranscriptionReplay.run(
            transcriber, source: source, vadEvents: try await recordedVADEvents(for: fixture), vadLag: 320)

        #expect(replay.finals.map(\.text) == script.sentences(includingUnrecognizable: true))
        // Each sentence is final within 1.2 s of the end of its speech, on
        // the audio timeline (VAD's events arrive 20 ms after its decision).
        for (label, lines) in zip(fixture.labels, script.segments) where lines.last?.endsUtterance == true {
            let emission = try #require(
                replay.finalEmissions.first {
                    $0.position >= label.upperBound
                        && $0.utterance.timeRange.end.sampleCount(sampleRate: 16_000) > label.lowerBound
                })
            #expect(emission.position - label.upperBound < 19_200, "\(name): \(emission.position - label.upperBound)")
        }
        // Utterances cover their speech.
        for utterance in replay.finals {
            #expect(utterance.speaker == .user)
            #expect(utterance.speakerDecision == nil)
            #expect(fixture.labels.contains { utterance.timeRange.overlaps(range($0)) })
        }
        #expect(await recognizer.resets >= replay.finals.count)
        #expect(await recognizer.discontinuities == 0)
    }

    @Test func aPauseInsideASentenceKeepsOneUtteranceAndAFollowingSentenceIsWhole() async throws {
        // "pauses": "Let me think" (200 ms) "about that for a moment"
        // (700 ms) "Take your time". VAD confirms "Take" after the fallback
        // already committed: the next utterance still starts at its onset.
        let fixture = try VADFixture.load("pauses")
        let script = try #require(FixtureScript.all["pauses"])
        let recognizer = SimulatedEouRecognizer(words: script.words(over: fixture.labels))
        let source = FixtureAudioSource(block: fixture.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source,
            vadEvents: try await recordedVADEvents(for: fixture), vadLag: 320)

        #expect(replay.finals.map(\.text) == ["Let me think about that for a moment", "Take your time"])
        let second = try #require(replay.finals.last)
        #expect(abs(second.timeRange.start.sampleCount(sampleRate: 16_000) - fixture.labels[1].lowerBound) < 1_600)
    }

    // MARK: Commit rules

    @Test func theModelsEndOfUtteranceCommitsBeforeTheFallbackAndResetsTheRecognizer() async throws {
        let scenario = Scenario(seconds: 8)
            .speech("hello there how are you", from: 0.5, to: 2.5, endsUtterance: true)
            .speech("fine thanks", from: 5.0, to: 6.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words, debounce: .milliseconds(320))
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = makeTranscriber(
            recognizer, source: source, configuration: .init(silenceCommitDelay: .seconds(3)))

        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        #expect(replay.finals.map(\.text) == ["hello there how are you", "fine thanks"])
        #expect(replay.statistics.commits == [.endOfUtterance: 2])
        #expect(await recognizer.resets == 2)
        #expect(await recognizer.finishes == 0, "An end of utterance needs no flush")
        // The model decides within a second or so of the end of speech.
        for (emission, end) in zip(replay.finalEmissions, [2.5, 6.0]) {
            let delay = Double(emission.position) / 16_000 - end
            #expect(delay > 0.3 && delay < 1.4, "\(delay)")
        }
    }

    @Test func vadsEndOfSpeechCommitsWhenTheModelDoesNotEndTheUtterance() async throws {
        // The sentence trails off: the model never fires.
        let scenario = Scenario(seconds: 5).speech("so I was thinking that", from: 0.5, to: 2.0, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        #expect(replay.finals.map(\.text) == ["so I was thinking that"])
        #expect(replay.statistics.commits == [.silence: 1])
        let emission = try #require(replay.finalEmissions.first)
        // 0.9 s after the end of speech, to the frame.
        #expect(abs(emission.position - (32_000 + 14_400)) <= 320)
        #expect(replay.statistics.endOfSpeechCommits == 1)
        #expect(abs(replay.statistics.slowestEndOfSpeechCommit.milliseconds - 900) <= 20)
        #expect(await recognizer.finishes == 1)
    }

    @Test func speechThatResumesBeforeTheFallbackStaysOneUtterance() async throws {
        let scenario = Scenario(seconds: 6)
            .speech("I would like", from: 0.5, to: 1.5, endsUtterance: false)
            .speech("a coffee please", from: 2.0, to: 3.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        #expect(replay.finals.map(\.text) == ["I would like a coffee please"])
        let utterance = try #require(replay.finals.first)
        #expect(utterance.timeRange == range(8_000..<48_000))
    }

    /// A short pause where VAD confirms the resumed speech only after the
    /// fallback committed: the flush decodes audio past the end of speech
    /// (up to `silenceCommitDelay` after it), which holds the start of the
    /// resumed speech, and the next utterance decodes that audio again from
    /// its onset. The flush keeps only the words up to the end of speech, so
    /// every word lands in exactly one utterance.
    @Test(arguments: [0.35, 0.4, 0.45, 0.5, 0.6], [0.25, 0.4, 0.55])
    func speechConfirmedAfterTheFallbackIsNeitherRepeatedNorLost(pause: Double, onsetDelay: Double) async throws {
        let first = "I would like"
        let second = "a coffee please"
        let resumeAt = 1.5 + pause
        let scenario = Scenario(seconds: 6)
            .speech(first, from: 0.5, to: 1.5, endsUtterance: false, onsetConfirmedAfter: onsetDelay)
            .speech(second, from: resumeAt, to: resumeAt + 0.9, endsUtterance: true, onsetConfirmedAfter: onsetDelay)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events, vadLag: 320)

        let finals = replay.finals.map(\.text)
        #expect(finals.joined(separator: " ") == "\(first) \(second)", "\(finals)")
        // Whether the pause splits the speech depends on whether VAD confirms
        // the resumed onset before the fallback fires (0.9 s after the end of
        // speech; both events reach the transcriber 20 ms late). Too close to
        // call within a frame, either outcome is right.
        let race = (pause + onsetDelay) - 0.9
        if race > 0.03 {
            #expect(finals == [first, second])
            #expect(replay.statistics.commits[.silence] == 2)
        } else if race < -0.03 {
            #expect(finals == ["\(first) \(second)"])
        }
        #expect(await recognizer.discontinuities == 0)
    }

    @Test func aLongPauseSplitsTheSpeechIntoTwoUtterances() async throws {
        let scenario = Scenario(seconds: 7)
            .speech("I would like", from: 0.5, to: 1.5, endsUtterance: false)
            .speech("a coffee please", from: 3.5, to: 4.5, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        #expect(replay.finals.map(\.text) == ["I would like", "a coffee please"])
        #expect(replay.statistics.commits[.silence] == 2)
    }

    @Test func theMaximumLengthSplitsAMonologueWithoutLosingOrRepeatingAudio() async throws {
        // 12 s of speech with no pause; VAD splits it at 8 s itself.
        let words = (0..<40).map { "w\($0)" }.joined(separator: " ")
        let scenario = Scenario(seconds: 15).speech(words, from: 0.5, to: 12.5, endsUtterance: true, vadSplitAt: [8.5])
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = makeTranscriber(
            recognizer, source: source, configuration: .init(maximumUtteranceDuration: .seconds(5)))
        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        #expect(replay.statistics.commits[.maximumLength] == 2)
        #expect(replay.finals.count == 3)
        #expect(replay.finals.map(\.text).joined(separator: " ") == words)
        for utterance in replay.finals {
            #expect(utterance.duration <= .seconds(5) + .milliseconds(20))
        }
        // One contiguous span from the onset: nothing skipped, nothing twice.
        let transcribed = await recognizer.transcribed
        #expect(transcribed.count == 1)
        #expect(transcribed.first?.lowerBound == 8_000)
        #expect(await recognizer.discontinuities == 0)
    }

    @Test func theOnsetIsReadBackFromTheHistoryWhenVADReportsItLate() async throws {
        let scenario = Scenario(seconds: 4).speech("good morning", from: 1.0, to: 2.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        // VAD's events arrive 0.6 s after its decision.
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events, vadLag: 9_600)

        #expect(replay.finals.map(\.text) == ["good morning"])
        #expect(await recognizer.transcribed.first?.lowerBound == 16_000)
        #expect(replay.statistics.samplesMissed == 0)
    }

    @Test func audioThatScrolledOutOfTheHistoryIsSkippedAndCounted() async throws {
        let scenario = Scenario(seconds: 4).speech("good morning", from: 1.0, to: 2.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples, historyDuration: .milliseconds(100))
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events, vadLag: 9_600)

        #expect(replay.statistics.samplesMissed > 0)
        #expect(await recognizer.discontinuities == 0)
        let utterance = try #require(replay.finals.first)
        #expect(utterance.timeRange.start > .seconds(1))
    }

    @Test func speechWithNoWordsIsDropped() async throws {
        let scenario = Scenario(seconds: 4).speech("", from: 1.0, to: 2.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: [])
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        #expect(replay.emitted.isEmpty)
        #expect(replay.statistics.blankUtterancesDropped == 1)
        #expect(replay.statistics.utterancesCommitted == 0)
        #expect(await recognizer.resets == 1)
    }

    @Test func theEndOfTheStreamCommitsTheOpenUtterance() async throws {
        let scenario = Scenario(seconds: 3).speech("are you still there", from: 0.5, to: 3.0, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source,
            vadEvents: scenario.events.filter { if case .speechStarted = $0 { true } else { false } })

        #expect(replay.finals.map(\.text) == ["are you still there"])
        #expect(replay.statistics.commits == [.streamEnded: 1])
    }

    @Test func finishingCommitsTheOpenUtteranceAndEndsTheStream() async throws {
        let scenario = Scenario(seconds: 3).speech("wait a second", from: 0.5, to: 2.5, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source,
            vadEvents: scenario.events.filter { if case .speechStarted = $0 { true } else { false } },
            endOfStream: false)

        #expect(replay.finals.map(\.text) == ["wait a second"])
        #expect(replay.statistics.commits == [.stopped: 1])
    }

    @Test func finishingReleasesTheRecognizersModelOnceAfterTheLastCommit() async throws {
        // #31: `TranscriberRouter` finishes Parakeet when it switches to
        // Apple's engine; the Core ML models must go with it even if
        // something still holds the transcriber.
        let scenario = Scenario(seconds: 3).speech("wait a second", from: 0.5, to: 2.5, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        // As `ParakeetStreamingTranscriber.load` builds it: it owns its
        // recognizer.
        let transcriber = makeTranscriber(recognizer, source: source, unloadsRecognizerOnFinish: true)
        let onset = scenario.events.filter { if case .speechStarted = $0 { true } else { false } }
        await transcriber.ingest(onset, frame: source.frame(at: 0, length: 40_000))
        await transcriber.stop()
        // A stopped transcriber can start again: it keeps its model.
        #expect(await recognizer.unloads == 0)
        try await transcriber.start()
        await transcriber.finish()
        await transcriber.finish()

        #expect(await recognizer.finishes == 1)
        #expect(await recognizer.unloads == 1)
        #expect(await recognizer.callsAfterUnload == 0)
        // Finished for good: a start doesn't bring the unloaded model back.
        try await transcriber.start()
        #expect(await transcriber.isRunning == false)
    }

    @Test func aRecognizerPassedInStaysLoadedForTheNextTranscriber() async throws {
        // A recognizer the caller shares across transcribers (the ASR
        // evaluation engine's, one per fixture; the soak run's) must
        // survive each one's `finish()`.
        let scenario = Scenario(seconds: 4).speech("hello there", from: 0.5, to: 2.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        for _ in 0..<3 {
            await recognizer.reset()
            let source = FixtureAudioSource(block: scenario.samples)
            // `run` finishes the transcriber.
            let replay = await TranscriptionReplay.run(
                makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)
            #expect(replay.finals.map(\.text) == ["hello there"])
        }
        #expect(await recognizer.unloads == 0)
        #expect(await recognizer.callsAfterUnload == 0)
    }

    @Test func aRecognizerFailureCommitsWhatWasDecodedAndCarriesOn() async throws {
        let scenario = Scenario(seconds: 9)
            .speech("one two three four five six", from: 0.5, to: 3.0, endsUtterance: true)
            .speech("seven eight", from: 5.0, to: 6.0, endsUtterance: true)
        // The fifth chunk (input ≈ 1.9 s) fails.
        let recognizer = SimulatedEouRecognizer(words: scenario.words, failingChunks: [4])
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        #expect(replay.statistics.recognizerFailures == 1)
        #expect(replay.statistics.commits[.recognizerFailure] == 1)
        let texts = replay.finals.map(\.text)
        #expect(texts.first.map { "one two three four five six".hasPrefix($0) } == true)
        #expect(texts.last == "seven eight")
    }

    // MARK: Events

    @Test func partialsGrowWordByWordAndStartAtTheOnset() async throws {
        let scenario = Scenario(seconds: 5).speech("the quick brown fox jumps", from: 0.5, to: 2.5, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let replay = await TranscriptionReplay.run(
            makeTranscriber(recognizer, source: source), source: source, vadEvents: scenario.events)

        let partials = replay.partials
        #expect(partials.count >= 3)
        #expect(partials.last?.text == "the quick brown fox jumps")
        for (previous, next) in zip(partials, partials.dropFirst()) {
            #expect(next.text.hasPrefix(previous.text))
            #expect(next.range.end >= previous.range.end)
        }
        for partial in partials {
            #expect(partial.range.start == .milliseconds(500))
            // The decoded audio is one chunk shift behind the input, at most
            // a window.
            let lag = partial.position - partial.range.end.sampleCount(sampleRate: 16_000)
            #expect(lag >= 0 && lag <= Int64(ASRChunkSize.ms320.windowSamples), "\(lag)")
        }
        // Every partial comes before the final.
        let finalIndex = try #require(replay.emitted.firstIndex { if case .final = $0.event { true } else { false } })
        #expect(finalIndex == replay.emitted.count - 1)
    }

    @Test func utterancesCarryTheConversationAndTheirWallClockStart() async throws {
        let scenario = Scenario(seconds: 4).speech("hello", from: 1.0, to: 1.6, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_000_000))
        let conversation = ConversationID()
        let transcriber = makeTranscriber(recognizer, source: source, clock: clock)
        await transcriber.setConversationID(conversation)

        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        let utterance = try #require(replay.finals.first)
        #expect(utterance.conversationID == conversation)
        // The clock didn't move while the audio replayed, so the latest frame
        // (at 4 s) maps to `now` and the onset to 3 s before it.
        let frameEnd = Double(replay.finalEmissions.first!.position) / 16_000
        let expected = clock.now.addingTimeInterval(1.0 - frameEnd)
        #expect(abs(utterance.startedAt.timeIntervalSince(expected)) < 0.001)
    }

    @Test func endOfSpeechIntervalsEndWithTheirDecision() async throws {
        let backend = RecordingSignpostBackend()
        let scenario = Scenario(seconds: 9)
            .speech("I would like", from: 0.5, to: 1.5, endsUtterance: false)
            .speech("a coffee please", from: 2.0, to: 3.0, endsUtterance: false)
            .speech("thanks", from: 6.0, to: 6.5, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = makeTranscriber(
            recognizer, source: source, signposter: Signposter(category: .asr, backend: backend))
        _ = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        #expect(backend.openIntervals.isEmpty)
        #expect(backend.endMessages(of: "asr.eou") == ["resumed", "silence", "silence"])
    }

    /// The latency budget's first hop (#74): each final leaves its end of
    /// speech and end-of-utterance moments for the turn orchestrator.
    @Test func eachEndOfUtteranceLeavesItsLatencyMarks() async throws {
        let scenario = Scenario(seconds: 9)
            .speech("hello there how are you", from: 0.5, to: 2.5, endsUtterance: true)
            .speech("so I was thinking that", from: 4.0, to: 5.0, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words, debounce: .milliseconds(320))
        let source = FixtureAudioSource(block: scenario.samples)
        let marks = LatencyMarks()
        let clock = ManualClock(uptime: .seconds(100))
        let transcriber = makeTranscriber(recognizer, source: source, clock: clock, latencyMarks: marks)

        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        #expect(replay.finalEmissions.count == 2)
        for (final, position) in replay.finalEmissions {
            let mark = try #require(marks.take(final.id))
            #expect(mark.endOfUtterance == .seconds(100))
            // The clock stood still while the audio replayed, so the hop is
            // the audio between the end of speech and the decision (to the
            // frame: a commit on VAD's event comes before that frame).
            let endOfSpeech = try #require(mark.endOfSpeech)
            let hop = (mark.endOfUtterance - endOfSpeech).timeInterval
            let audio = Double(position - final.timeRange.end.sampleCount(sampleRate: 16_000)) / 16_000
            #expect(abs(hop - audio) <= 0.021, "\(hop) vs \(audio)")
            #expect(hop > 0.3 && hop < 1.0, "\(hop)")
        }
        #expect(marks.count == 0)
    }

    @Test func aCaptureHostTimePlacesTheEndOfSpeech() async throws {
        let scenario = Scenario(seconds: 4).speech("hello there", from: 0.5, to: 1.5, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words, debounce: .milliseconds(320))
        let source = FixtureAudioSource(block: scenario.samples)
        let marks = LatencyMarks()
        let transcriber = makeTranscriber(recognizer, source: source, clock: SystemClock(), latencyMarks: marks)
        let events = transcriber.events
        let collector = Task {
            var finals: [Utterance] = []
            for await case .final(let utterance) in events { finals.append(utterance) }
            return finals
        }

        // Live frames stamped with the host time they were captured at: the
        // whole stream lies in the past, so the transcriber's frame arrival
        // (now) is not when the speech ended.
        let streamStart = HostClock.now - HostClock.ticks(for: .seconds(4))
        var pending = scenario.events.sorted { $0.detectedAt < $1.detectedAt }[...]
        var offset: Int64 = 0
        while offset < source.totalSamples {
            let frame = source.frame(at: offset, length: 320)
            var due: [VoiceActivityEvent] = []
            while let next = pending.first, next.detectedAt <= frame.sampleOffset {
                due.append(next)
                pending.removeFirst()
            }
            source.position = frame.nextSampleOffset
            let hostTime = streamStart + HostClock.ticks(for: .samples(offset, sampleRate: 16_000))
            await transcriber.ingest(
                due, frame: AudioFrame(samples: frame.samples, sampleOffset: frame.sampleOffset, hostTime: hostTime))
            offset = frame.nextSampleOffset
        }
        await transcriber.finish()

        let final = try #require(await collector.value.first)
        let mark = try #require(marks.take(final.id))
        let endOfSpeech = try #require(mark.endOfSpeech)
        let capturedAt = streamStart + HostClock.ticks(for: final.timeRange.end)
        let expected = SystemClock().uptime - HostClock.elapsed(since: capturedAt)
        #expect(abs((endOfSpeech - expected).timeInterval) < 0.01, "\(endOfSpeech) vs \(expected)")
        // The replay took an instant, so the decision came about 2.5 s after
        // the speech was captured, not one frame after its arrival.
        #expect((mark.endOfUtterance - endOfSpeech).timeInterval > 2)
    }

    // MARK: Lifecycle

    @Test func startFollowsTheCaptureAndVADStreamsAndStopCommits() async throws {
        let scenario = Scenario(seconds: 6)
            .speech("first thought", from: 0.5, to: 1.5, endsUtterance: true)
            .speech("and another", from: 4.0, to: 5.0, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let vad = ScriptedVoiceActivity()
        let transcriber = makeTranscriber(recognizer, source: source, voiceActivity: vad)
        var events = transcriber.events.makeAsyncIterator()

        try await transcriber.start()
        #expect(await transcriber.isRunning)
        #expect(vad.subscriberCount == 1)

        // Feed in real order: frames, and VAD's events once it decided.
        var pending = scenario.events.sorted { $0.detectedAt < $1.detectedAt }[...]
        var offset: Int64 = 0
        let stopAt: Int64 = 5 * 16_000
        while offset < stopAt {
            while let next = pending.first, next.detectedAt <= offset {
                vad.send(next)
                pending.removeFirst()
            }
            let frame = source.frame(at: offset, length: 320)
            source.publish(frame)
            offset = frame.nextSampleOffset
            await Task.yield()
        }
        var finals: [String] = []
        while finals.isEmpty, let event = await events.next() {
            if case .final(let utterance) = event { finals.append(utterance.text) }
        }
        #expect(finals == ["first thought"])

        // Stopping mid-utterance commits what was said so far.
        try await waitUntil { await transcriber.receivedPosition == stopAt }
        await transcriber.stop()
        #expect(await transcriber.isRunning == false)
        while let event = await events.next() {
            if case .final(let utterance) = event {
                finals.append(utterance.text)
                break
            }
        }
        #expect(finals.count == 2)
        #expect(transcriber.statistics.commits[.stopped] == 1)

        await transcriber.finish()
        #expect(await events.next() == nil)
    }

    @Test func theEndOfTheCaptureStreamEndsTheRun() async throws {
        let scenario = Scenario(seconds: 2).speech("bye", from: 0.5, to: 1.0, endsUtterance: false)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        let vad = ScriptedVoiceActivity()
        let transcriber = makeTranscriber(recognizer, source: source, voiceActivity: vad)
        try await transcriber.start()
        for event in scenario.events.prefix(1) { vad.send(event) }
        try await waitUntil { vad.subscriberCount == 1 }
        // Let the VAD event land before the audio.
        try await Task.sleep(for: .milliseconds(20))
        for offset in stride(from: Int64(0), to: 32_000, by: 320) {
            source.publish(source.frame(at: offset, length: 320))
        }
        source.finishFrames()
        try await waitUntil { await transcriber.isRunning == false }
        #expect(transcriber.statistics.commits[.streamEnded] == 1)
    }

    // MARK: Chunk size

    @Test func theChunkSizeChangesBetweenUtterancesWhenThePolicyAsks() async throws {
        let scenario = Scenario(seconds: 8)
            .speech("it is getting warm", from: 0.5, to: 2.0, endsUtterance: true)
            .speech("still talking", from: 4.0, to: 5.0, endsUtterance: true)
        let first = SimulatedEouRecognizer(words: scenario.words)
        let reduced = SimulatedEouRecognizer(words: scenario.words, chunkSize: .ms1280)
        let state = TestThermalState(.nominal)
        let requests = Counter()
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: first, audio: source, voiceActivity: ScriptedVoiceActivity(),
            chunkSizePolicy: ThermalASRChunkSizePolicy(thermalState: { state.value }),
            recognizerProvider: { size in
                requests.increment()
                return size == .ms1280 ? reduced : nil
            },
            signposter: .disabled(.asr), clock: ManualClock())

        // Heat up mid-utterance: nothing changes until it is committed.
        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events) {
            position in
            if position == 16_000 { state.value = .serious }
        }

        #expect(replay.finals.map(\.text) == ["it is getting warm", "still talking"])
        #expect(replay.statistics.chunkSizeChanges == 1)
        #expect(requests.value == 1)
        #expect(await first.transcribed.first?.lowerBound == 8_000)
        #expect(await reduced.transcribed.first?.lowerBound == 64_000)
        #expect(await first.resets >= 2)
    }

    @Test func aChunkSizeThatIsNotInstalledIsNotRequestedAgain() async throws {
        let scenario = Scenario(seconds: 10)
            .speech("one", from: 0.5, to: 1.0, endsUtterance: true)
            .speech("two", from: 3.5, to: 4.0, endsUtterance: true)
            .speech("three", from: 6.5, to: 7.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let requests = Counter()
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
            chunkSizePolicy: FixedASRChunkSizePolicy(.ms1280),
            recognizerProvider: { _ in
                requests.increment()
                return nil
            },
            signposter: .disabled(.asr), clock: ManualClock())
        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        #expect(replay.finals.map(\.text) == ["one", "two", "three"])
        #expect(requests.value == 1)
        #expect(await transcriber.chunkSize == .ms320)
    }

    @Test func thermalPolicyMovesUpWhenHotAndBackOnlyWhenCool() {
        let state = TestThermalState(.nominal)
        let policy = ThermalASRChunkSizePolicy(thermalState: { state.value })
        #expect(policy.preferredChunkSize(current: .ms320) == .ms320)
        state.value = .fair
        #expect(policy.preferredChunkSize(current: .ms320) == .ms320)
        state.value = .serious
        #expect(policy.preferredChunkSize(current: .ms320) == .ms1280)
        state.value = .critical
        #expect(policy.preferredChunkSize(current: .ms1280) == .ms1280)
        state.value = .fair
        #expect(policy.preferredChunkSize(current: .ms1280) == .ms1280, "Hysteresis")
        state.value = .nominal
        #expect(policy.preferredChunkSize(current: .ms1280) == .ms320)
    }

    @Test func performancePolicyUses1280msChunksBelowNormal() {
        let performance = ManualPerformanceLevel(.normal)
        let policy = PerformanceASRChunkSizePolicy(performance)
        #expect(policy.preferredChunkSize(current: .ms320) == .ms320)
        performance.set(.reduced)
        #expect(policy.preferredChunkSize(current: .ms320) == .ms1280)
        performance.set(.minimal)
        #expect(policy.preferredChunkSize(current: .ms1280) == .ms1280)
        performance.set(.normal)
        #expect(policy.preferredChunkSize(current: .ms1280) == .ms320)
    }

    /// The thermal and power policy (#75) drives the chunk size: up to
    /// 1280 ms when the level drops, back to 320 ms when it recovers, each
    /// time between utterances.
    @Test func theChunkSizeFollowsThePerformanceLevelBothWays() async throws {
        let scenario = Scenario(seconds: 10)
            .speech("normal start", from: 0.5, to: 1.5, endsUtterance: true)
            .speech("running warm", from: 3.5, to: 4.5, endsUtterance: true)
            .speech("cooled down", from: 6.5, to: 7.5, endsUtterance: true)
        let standard = SimulatedEouRecognizer(words: scenario.words)
        let lowPower = SimulatedEouRecognizer(words: scenario.words, chunkSize: .ms1280)
        let performance = ManualPerformanceLevel(.normal)
        let requested = RequestLog()
        let source = FixtureAudioSource(block: scenario.samples)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: standard, audio: source, voiceActivity: ScriptedVoiceActivity(),
            chunkSizePolicy: PerformanceASRChunkSizePolicy(performance),
            recognizerProvider: { size in
                requested.append(size)
                return size == .ms1280 ? lowPower : standard
            },
            signposter: .disabled(.asr), clock: ManualClock())

        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events) {
            position in
            if position == 40_000 { performance.set(.reduced) }
            if position == 88_000 { performance.set(.normal) }
        }

        #expect(replay.finals.map(\.text) == ["normal start", "running warm", "cooled down"])
        #expect(requested.sizes == [.ms1280, .ms320])
        #expect(replay.statistics.chunkSizeChanges == 2)
        #expect(await lowPower.transcribed.isEmpty == false)
        #expect(await transcriber.chunkSize == .ms320)
    }

    // MARK: Helpers

    func makeTranscriber(
        _ recognizer: any StreamingSpeechRecognizer,
        source: FixtureAudioSource,
        voiceActivity: any VoiceActivitySource = ScriptedVoiceActivity(),
        configuration: StreamingTranscriberConfiguration = .standard,
        signposter: Signposter = .disabled(.asr),
        clock: any BlauClock = ManualClock(),
        latencyMarks: LatencyMarks? = nil,
        unloadsRecognizerOnFinish: Bool = false
    ) -> ParakeetStreamingTranscriber {
        ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: voiceActivity, configuration: configuration,
            signposter: signposter, clock: clock, latencyMarks: latencyMarks,
            unloadsRecognizerOnFinish: unloadsRecognizerOnFinish)
    }
}

// MARK: - Scenario

/// Synthetic speech for the simulated recognizer: where each stretch of
/// words is, and VAD's events for it (onset confirmed 300 ms in unless
/// stated, end decided 400 ms after the speech).
struct Scenario {
    let seconds: Double
    var words: [ScriptedWord] = []
    var events: [VoiceActivityEvent] = []
    private var segmentID = 0

    init(seconds: Double) {
        self.seconds = seconds
    }

    /// Room tone at -60 dBFS (the simulated recognizer ignores the audio).
    var samples: [Float] {
        roomNoise(count: Int(seconds * 16_000), levelDecibels: -60, seed: 7)
    }

    func speech(
        _ text: String, from start: Double, to end: Double, endsUtterance: Bool, vadSplitAt splits: [Double] = [],
        onsetConfirmedAfter onsetDelay: Double = 0.3
    ) -> Scenario {
        var scenario = self
        let startOffset = Int64(start * 16_000)
        let endOffset = Int64(end * 16_000)
        let tokens = text.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            let wordEnd = startOffset + (endOffset - startOffset) * Int64(index + 1) / Int64(tokens.count)
            scenario.words.append(
                ScriptedWord(text: token, end: wordEnd, endsUtterance: endsUtterance && index == tokens.count - 1))
        }
        var segmentStart = startOffset
        var isContinuation = false
        for split in splits.map({ Int64($0 * 16_000) }) + [endOffset] {
            let id = scenario.segmentID
            scenario.segmentID += 1
            let isLast = split == endOffset
            scenario.events.append(
                .speechStarted(
                    SpeechOnset(
                        segmentID: id, startOffset: segmentStart, sampleRate: 16_000, isContinuation: isContinuation,
                        detectedAt: isContinuation ? segmentStart : segmentStart + Int64(onsetDelay * 16_000))))
            scenario.events.append(
                .speechEnded(
                    SpeechSegment(
                        id: id, sampleRange: segmentStart..<split, sampleRate: 16_000, isContinuation: isContinuation,
                        endReason: isLast ? .silence : .maximumDuration,
                        detectedAt: isLast ? split + 6_400 : split, peakProbability: 0.99, meanProbability: 0.9)))
            segmentStart = split
            isContinuation = true
        }
        return scenario
    }
}

func range(_ samples: Range<Int64>) -> TimeRange {
    TimeRange(
        start: .samples(samples.lowerBound, sampleRate: 16_000), end: .samples(samples.upperBound, sampleRate: 16_000))
}

final class TestThermalState: Sendable {
    private let state: Mutex<ProcessInfo.ThermalState>

    init(_ value: ProcessInfo.ThermalState) {
        state = Mutex(value)
    }

    var value: ProcessInfo.ThermalState {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

final class Counter: Sendable {
    private let state = Mutex(0)

    var value: Int { state.withLock { $0 } }

    func increment() {
        state.withLock { $0 += 1 }
    }
}

/// Polls `condition` until it holds, failing after `timeout`.
func waitUntil(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// The chunk sizes a `RecognizerProvider` was asked for, in order.
private final class RequestLog: Sendable {
    private let state = Mutex<[ASRChunkSize]>([])

    func append(_ size: ASRChunkSize) {
        state.withLock { $0.append(size) }
    }

    var sizes: [ASRChunkSize] { state.withLock { $0 } }
}
