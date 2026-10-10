#if DEBUG || BLAU_PERF
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
    import Synchronization
    import os

    /// The automated long-session soak test (#76): one or two hours of the
    /// voice loop's real pipeline, from the capture hub to the stored
    /// transcript, sampled as it goes and judged at the end
    /// (docs/soak.md).
    ///
    /// It is the performance suite's scripted session (`PerfReplay`, #73)
    /// made long and messier:
    ///
    /// - **Audio**: the user's scripted conversation with an interlude every
    ///   topic, 30 s of TV dialogue from another voice and 30 s of silence
    ///   (`ConversationAudioScript.Interlude.tvAndSilence`), played into the
    ///   real `CaptureHub` (the app's virtual input) at `speed`. The user's
    ///   speech is the hermetic speech-shaped signal for the scripted
    ///   recognizer, and synthesized speech of each topic's sentences for
    ///   Parakeet (`speech(for:)`).
    /// - **ASR**: the scripted recognizer on the script's word alignment,
    ///   or Parakeet and Silero from the installed models
    ///   (`BLAU_SOAK_ASR=parakeet`), never a silent fallback from one to the
    ///   other (`SetupError`). The checks are line-exact for the first and
    ///   allow for split or missed lines with the second
    ///   (`SoakTranscriptSource`).
    /// - **Voice ID**: the real `VerificationGate` (#47) between the
    ///   transcriber and the orchestrator, as in a conversation. Its verifier
    ///   (`SoakSpeechVerifier`) gives the TV's speech another speaker's
    ///   embedding: every score of the TV must reject, every score of the user
    ///   accept, and every user line must still reach Grok.
    /// - **Grok**: the real `TurnOrchestrator` and `RealtimeClient` against
    ///   `ScriptedRealtimeServer`, a local fake that streams canned replies
    ///   and counts every connection. xAI's session schedule (renew at 110
    ///   minutes, deadline 118) is scaled so the renewal lands
    ///   `rolloverAt` into the audio, and the session is renewed and
    ///   reseeded from the stored transcript as a real one would be (#39).
    /// - **Transcript, topics, memory**: as in the replay.
    ///
    /// Every `sampleInterval` of audio it records the process's footprint,
    /// the recognizer's chunk time, capture drops, the conversation's
    /// counts and the session renewals (`SoakSample`); `SoakReport` judges
    /// them. Nothing touches the user's data, the network or the microphone.
    actor SoakRun {
        let configuration: SoakConfiguration
        let vadModelDirectory: URL?
        let asrModelDirectory: URL?
        private let progress: @Sendable (SoakProgress) -> Void

        /// Exchanges per topic of the scripted conversation; an interlude
        /// (TV, then silence) comes before every new topic.
        static let exchangesPerTopic = 6

        init(
            configuration: SoakConfiguration, vadModelDirectory: URL? = nil, asrModelDirectory: URL? = nil,
            progress: @escaping @Sendable (SoakProgress) -> Void = { _ in }
        ) {
            self.configuration = configuration
            self.vadModelDirectory = vadModelDirectory
            self.asrModelDirectory = asrModelDirectory
            self.progress = progress
        }

        // swiftlint:disable:next function_body_length
        func run() async throws -> SoakReport {
            // The speech and the models first, before the clock starts: a
            // Parakeet soak that can't run Parakeet fails here instead of
            // quietly running the scripted recognizer.
            let recognizerKind = configuration.recognizer
            try Self.requireModelDirectories(recognizerKind, vad: vadModelDirectory, asr: asrModelDirectory)
            let clips = try await Self.speech(for: recognizerKind)
            let script = ConversationAudioScript.session(
                lasting: configuration.duration, exchangesPerTopic: Self.exchangesPerTopic, interlude: .tvAndSilence,
                backgroundVoice: clips.background, topicVoices: clips.topics)
            let models = try await Self.models(
                recognizerKind, vadDirectory: vadModelDirectory, asrDirectory: asrModelDirectory, script: script)

            // Whole seconds, so the report's ISO 8601 JSON round-trips.
            let startedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let clock = ContinuousClock()
            let started = clock.now

            let directory = FileManager.default.temporaryDirectory.appending(
                path: "Soak-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            // Transcript, topics and memory.
            let conversationID = ConversationID()
            let container = try BlauModelContainer.makeLocal(url: directory.appending(path: "Blau.store"))
            let store = ConversationStore(modelContainer: container)
            let index = try MemoryIndex.open(at: directory.appending(path: MemoryIndex.fileName))
            let tap = ReplayTranscriptTap(
                store: store, index: index, segmenter: StreamingTopicSegmenter(embedder: LexicalTextEmbedder()),
                conversationID: conversationID)

            // Audio, VAD, ASR.
            let hub = CaptureHub()
            let vad = VoiceActivitySegmenter(model: models.voiceActivity)
            let transcriber = ParakeetStreamingTranscriber(
                recognizer: models.recognizer, audio: hub, voiceActivity: vad, conversationID: conversationID)

            // Grok, played by the local fake server.
            let replies = Dictionary(script.lines.map { ($0.text, $0.reply) }, uniquingKeysWith: { first, _ in first })
            let speed = configuration.speed
            let server = ScriptedRealtimeServer(
                pacing: .init(
                    firstAudioDelay: .milliseconds(600) / (speed ?? 100),
                    audioSpeed: speed.map { $0 * 2 })
            ) { request in
                .init(text: replies[request.userText] ?? "Okay. Tell me more about that.")
            }
            let output = DiscardingAgentAudioOutput()
            let orchestrator = TurnOrchestrator(
                client: RealtimeClient(
                    endpoint: URL(string: "wss://soak.blau.invalid/v1/realtime")!,
                    tokenProvider: ScriptedRealtimeServer.TokenProvider(), connector: server),
                configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore()),
                audio: output, transcript: tap, reseedContext: store,
                configuration: .init(continuity: configuration.continuity))

            // Voice ID: the verification gate between ASR and Grok.
            let verifier = SoakSpeechVerifier(script: script)
            let gate = VerificationGate(verifier: verifier, history: hub)

            // Failed turns: every time the orchestrator shows the error state.
            // The gate's uncertain policy also follows Grok's activity, as in
            // the voice loop.
            let failures = orchestrator.updates(bufferingPolicy: .bufferingNewest(64))
            let turnActivity = gate.turnActivity
            let failureCount = Task {
                var count = 0
                var inError = false
                for await snapshot in failures {
                    turnActivity.agentActivityChanged(snapshot.state.isAgentActive)
                    if case .error = snapshot.state {
                        if !inError { count += 1 }
                        inError = true
                    } else {
                        inError = false
                    }
                }
                return count
            }

            try await orchestrator.start(conversationID: conversationID, waitsForConnection: true)
            let sessionStarted = clock.now
            try await transcriber.start()
            // The gate subscribes to VAD's speech audio before VAD sees any.
            let speech = vad.speechAudio()
            let gating = Task { await gate.run(speech: speech) }
            let vadFrames = hub.frames()
            let voiceActivity = Task {
                for await frame in vadFrames { await vad.process(frame) }
                await vad.finish()
            }
            let turns = Task { await orchestrator.run(transcript: gate.filter(transcriber.events)) }

            let sampler = SoakSampler(
                started: started, interval: configuration.sampleInterval, hub: hub, transcriber: transcriber,
                tap: tap, orchestrator: orchestrator)
            let progress = progress
            let totalSeconds = script.duration.timeInterval
            Log.performance.notice(
                "Soak: \(script.lines.count, privacy: .public) lines, \(script.backgroundBursts.count, privacy: .public) background bursts, \(Int(totalSeconds), privacy: .public) s, \(self.configuration.summary, privacy: .public)"
            )
            await sampler.take(at: 0)
            let transcript = models.transcript

            do {
                try await CaptureReplayFeeder(script: script, speed: speed).feed(
                    into: hub,
                    consumed: { min(vad.statistics.samplesProcessed, await transcriber.receivedPosition ?? 0) },
                    beforeLine: { line in
                        // The user waits for Blau's answer before speaking
                        // (at most 20 s; a reply that never comes shows up
                        // in the report).
                        await Self.waitForReply(
                            before: line, transcript: transcript, tap: tap, orchestrator: orchestrator,
                            deadline: ContinuousClock.now + .seconds(20))
                    },
                    progress: { position in
                        let audioSeconds = Double(position) / Double(ConversationAudioScript.sampleRate)
                        if let sample = await sampler.takeIfDue(at: audioSeconds) {
                            progress(
                                SoakProgress(audioSeconds: audioSeconds, totalSeconds: totalSeconds, latest: sample))
                        }
                    })
            } catch {
                hub.finish()
                voiceActivity.cancel()
                gating.cancel()
                await transcriber.finish()
                await orchestrator.shutdown()
                failureCount.cancel()
                throw error
            }
            hub.finish()
            await voiceActivity.value
            await transcriber.finish()
            await turns.value

            // Let the last replies arrive and be written, as the replay does.
            await Self.waitForReply(
                before: nil, transcript: transcript, tap: tap, orchestrator: orchestrator,
                deadline: ContinuousClock.now + .seconds(30))
            let final = await sampler.take(at: totalSeconds)
            let wallSinceSession = clock.now - sessionStarted
            await orchestrator.shutdown()
            await gating.value
            let counts = verifier.counts
            let gateStatistics = gate.statistics
            let tapReport = await tap.finish()
            failureCount.cancel()
            let failed = await failureCount.value

            let outcome = SoakOutcome(
                lines: script.lines.count, backgroundBursts: script.backgroundBursts.count,
                scriptedTopicChanges: Set(script.lines.map { $0.exchange / Self.exchangesPerTopic }).count - 1,
                expectedRollovers: configuration.expectedRollovers(wallTime: wallSinceSession),
                userUtterances: tapReport.userUtterances, agentReplies: tapReport.agentReplies,
                userScores: counts.user, userAccepted: counts.userAccepted,
                backgroundScores: counts.background, backgroundRejected: counts.backgroundRejected,
                gateCommitted: gateStatistics.committed, gateDiscarded: gateStatistics.discarded,
                topicBoundaries: tapReport.topicBoundaries, rollovers: final.rollovers, reseeds: final.reseeds,
                connections: server.sockets.count, failedTurns: failed,
                unansweredUtterances: tapReport.unansweredUtterances, transcript: models.transcript)
            let setup = SoakReport.Setup(
                audioSeconds: totalSeconds, speed: speed, recognizer: models.recognizerName,
                voiceActivity: models.voiceActivityName,
                audio:
                    "user speech from \(script.source); TV dialogue (\(script.backgroundBursts.count) bursts) "
                    + "from \(clips.background.source); and silence",
                rolloverAfterSeconds: configuration.continuity.rolloverAfter?.timeInterval,
                sampleIntervalSeconds: configuration.sampleInterval.timeInterval)
            let report = SoakReport(
                device: .current, startedAt: startedAt, wallSeconds: (clock.now - started).timeInterval, setup: setup,
                outcome: outcome, samples: await sampler.samples)
            Log.performance.notice("Soak finished: \(report.summary, privacy: .public)")
            return report
        }

        /// Why a soak couldn't start. A Parakeet soak never falls back to the
        /// scripted recognizer or the energy VAD: it would pass while
        /// claiming to be the device run.
        enum SetupError: Error, Equatable, CustomStringConvertible {
            /// `BLAU_SOAK_ASR=parakeet`, but these models aren't installed.
            case modelsMissing([String])
            /// A model is installed but didn't load.
            case modelFailedToLoad(model: String, reason: String)
            /// The system speech synthesizer gave no speech for the user's
            /// lines or the TV.
            case speechUnavailable(String)

            var description: String {
                switch self {
                case .modelsMissing(let models):
                    "The Parakeet soak needs the installed speech models; missing: \(models.joined(separator: ", "))"
                case .modelFailedToLoad(let model, let reason):
                    "\(model) didn't load: \(reason)"
                case .speechUnavailable(let reason):
                    "No synthesized speech for the Parakeet soak: \(reason)"
                }
            }
        }

        /// The audio the script cuts its speech from.
        struct Speech {
            /// Each topic's clip (`ConversationAudioScript.topicVoices`);
            /// empty for the default voice.
            var topics: [String: AudioFixture] = [:]
            var background = ConversationAudioScript.defaultBackgroundVoice
        }

        /// The scripted recognizer reads the script's word alignment, so the
        /// hermetic speech-shaped signal is all it needs. Parakeet needs
        /// words to transcribe: each topic's sentences and the TV's, spoken
        /// by the system synthesizer (about four and a half minutes of
        /// audio, rendered once).
        static func speech(for kind: PerfReplayConfiguration.Recognizer) async throws -> Speech {
            guard kind == .parakeet else { return Speech() }
            var speech = Speech()
            do {
                for (topic, passage) in ConversationAudioScript.topicPassages(exchangesPerTopic: exchangesPerTopic) {
                    speech.topics[topic] = try await AudioFixture.synthesizedSpeech(passage)
                }
                // Another voice for the TV where the system has one.
                speech.background = try await AudioFixture.synthesizedSpeech(tvPassage, language: "en-GB")
            } catch {
                throw SetupError.speechUnavailable(String(describing: error))
            }
            return speech
        }

        /// What the TV says in the Parakeet soak's interludes.
        static let tvPassage = """
            Good evening and welcome to the late news. Heavy rain is moving across the coast tonight, \
            and drivers are being asked to stay off the motorway until the morning. In sport, the home \
            side came back from two goals down to win in the final minute. Markets closed slightly \
            higher after a quiet day of trading. And finally, the city zoo has welcomed a baby giraffe, \
            the first born there in more than ten years. Now, the weather for the weekend.
            """

        /// The voice activity model and recognizer a run uses.
        struct Models {
            var voiceActivity: any SpeechProbabilityModel
            var voiceActivityName: String
            var recognizer: any StreamingSpeechRecognizer
            var recognizerName: String
            var transcript: SoakTranscriptSource
        }

        /// Throws `SetupError.modelsMissing` when `kind` needs installed
        /// models and a directory is missing.
        static func requireModelDirectories(
            _ kind: PerfReplayConfiguration.Recognizer, vad: URL?, asr: URL?
        ) throws {
            guard kind == .parakeet else { return }
            let missing = [vad == nil ? "Silero VAD" : nil, asr == nil ? "Parakeet EOU" : nil].compactMap { $0 }
            if !missing.isEmpty { throw SetupError.modelsMissing(missing) }
        }

        /// The energy VAD and the scripted recognizer, or Silero and Parakeet
        /// from the installed models.
        ///
        /// - Throws: `SetupError` when Parakeet is asked for and a model
        ///   directory is missing or a model doesn't load.
        static func models(
            _ kind: PerfReplayConfiguration.Recognizer, vadDirectory: URL?, asrDirectory: URL?,
            script: ConversationAudioScript
        ) async throws -> Models {
            switch kind {
            case .scripted:
                let words = script.words.map {
                    AlignedTranscriptRecognizer.Word(text: $0.text, end: $0.end, endsUtterance: $0.endsLine)
                }
                // Timed by the call: the aligned recognizer runs no model and
                // reports no time of its own, and `asr.chunkLatency` needs one.
                return Models(
                    voiceActivity: EnergySpeechProbabilityModel(), voiceActivityName: "energy VAD",
                    recognizer: TimedSpeechRecognizer(AlignedTranscriptRecognizer(words: words)),
                    recognizerName: "scripted ASR", transcript: .scripted)
            case .parakeet:
                try requireModelDirectories(kind, vad: vadDirectory, asr: asrDirectory)
                guard let vadDirectory, let asrDirectory else { throw SetupError.modelsMissing([]) }
                let silero: SileroSpeechProbabilityModel
                do {
                    silero = try await SileroSpeechProbabilityModel(modelDirectory: vadDirectory)
                } catch {
                    throw SetupError.modelFailedToLoad(model: "Silero VAD", reason: String(describing: error))
                }
                let parakeet: ParakeetEouRecognizer
                do {
                    parakeet = try await ParakeetEouRecognizer.load(modelDirectory: asrDirectory)
                } catch {
                    throw SetupError.modelFailedToLoad(model: "Parakeet EOU", reason: String(describing: error))
                }
                return Models(
                    voiceActivity: silero, voiceActivityName: "Silero VAD", recognizer: parakeet,
                    recognizerName: "Parakeet EOU", transcript: .recognized)
            }
        }

        /// Waits while ``awaitsReply(before:transcript:replies:utterances:turn:)``
        /// says the user is still waiting for Blau, until `deadline` at the
        /// latest. Every check, and the return, follows `waitUntilSettled()`,
        /// so a finished turn's writes have landed (its reply counted, its
        /// exchange segmented and indexed) and what the user says next sees
        /// them.
        ///
        /// - Parameter line: The line about to be said (from 1), or `nil`
        ///   once the script is over.
        static func waitForReply(
            before line: Int?, transcript: SoakTranscriptSource, tap: ReplayTranscriptTap,
            orchestrator: TurnOrchestrator, deadline: ContinuousClock.Instant
        ) async {
            while true {
                await orchestrator.waitUntilSettled()
                let waits = await awaitsReply(
                    before: line, transcript: transcript, replies: tap.agentReplies,
                    utterances: tap.userUtterances, turn: orchestrator.snapshot)
                guard waits, ContinuousClock.now < deadline else {
                    // A turn that ended after the drain above queued its
                    // last writes: let them land too.
                    await orchestrator.waitUntilSettled()
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// Whether the user, about to say line `line` (from 1; `nil` once
        /// the script is over), is still waiting for Blau.
        ///
        /// - **Scripted:** every earlier line is exactly one utterance, so
        ///   the user waits for `line` replies (at the end, one reply per
        ///   utterance).
        /// - **Recognized:** the counts can't tell. A model may miss a line,
        ///   and when it splits one with a pause longer than the
        ///   orchestrator's merge window, the second half abandons the first
        ///   half's turn as interrupted (`TurnOrchestrator.commit`). That
        ///   utterance is stored but, when Grok's audio hadn't arrived yet,
        ///   never answered, and comparing replies with utterances would
        ///   then cost the whole timeout before every later line. So the
        ///   user waits while a turn is in flight instead
        ///   (``isTurnInFlight(_:)``).
        static func awaitsReply(
            before line: Int?, transcript: SoakTranscriptSource, replies: Int, utterances: Int, turn: TurnSnapshot
        ) -> Bool {
            switch transcript {
            case .scripted: replies < (line ?? utterances)
            case .recognized: isTurnInFlight(turn)
            }
        }

        /// Whether `turn` shows an utterance still on its way to a reply:
        /// Grok is working on or speaking one (`committing`, `agentThinking`,
        /// `agentSpeaking`, or reply audio still listed), the last line's
        /// final hasn't come through the gate yet (`userSpeaking`), or an
        /// utterance waits for a session that isn't ready. A failed turn
        /// (`error`) is over: it shows up in the report, not as a wait.
        static func isTurnInFlight(_ turn: TurnSnapshot) -> Bool {
            turn.state.isAgentActive || turn.state == .userSpeaking || !turn.agentSpeech.isEmpty
                || turn.queuedUtterances > 0
        }
    }

    /// The soak's voice ID verifier (#47's `SpeechVerifying`): instead of
    /// embedding the audio with WeSpeaker (a model download), it looks up
    /// who the script has speaking there and returns that speaker's
    /// synthetic embedding (`ReplayVoiceprint`), then scores it against the
    /// voiceprint with the calibrated thresholds, exactly as
    /// `SpeakerVerifier` does after its embedding. It counts every score by
    /// who was really speaking.
    final class SoakSpeechVerifier: SpeechVerifying {
        struct Counts: Sendable, Hashable {
            var user = 0
            var userAccepted = 0
            var background = 0
            var backgroundRejected = 0
        }

        private let script: ConversationAudioScript
        private let voiceprint = ReplayVoiceprint()
        private let tally = Mutex(Counts())

        init(script: ConversationAudioScript) {
            self.script = script
        }

        var counts: Counts { tally.withLock { $0 } }

        func verify(_ speech: AudioFrame) async throws -> SpeakerScore {
            let range = speech.sampleOffset..<speech.nextSampleOffset
            let isBackground = script.talker(in: range) == .background
            let seconds = Double(speech.sampleCount) / Double(AudioFrame.captureSampleRate)
            let probe = voiceprint.probe(startingAt: speech.sampleOffset, seconds: seconds, impostor: isBackground)
            let config = voiceprint.config
            let verification = voiceprint.scorer.verify(probe, config: config)
            tally.withLock { counts in
                if isBackground {
                    counts.background += 1
                    if verification.decision == .reject { counts.backgroundRejected += 1 }
                } else {
                    counts.user += 1
                    if verification.decision == .accept { counts.userAccepted += 1 }
                }
            }
            return SpeakerScore(
                score: verification.score, decision: verification.decision, audioDuration: probe.audioDuration,
                thresholds: config.thresholds(forAudioDuration: probe.audioDuration))
        }
    }

    /// Where a soak run is, for the screen.
    struct SoakProgress: Sendable, Hashable {
        var audioSeconds: Double
        var totalSeconds: Double
        var latest: SoakSample

        var fraction: Double { totalSeconds > 0 ? min(1, audioSeconds / totalSeconds) : 0 }
    }

    /// Takes the soak run's samples: one every `interval` of audio.
    actor SoakSampler {
        private let started: ContinuousClock.Instant
        private let interval: Double
        private let hub: CaptureHub
        private let transcriber: ParakeetStreamingTranscriber
        private let tap: ReplayTranscriptTap
        private let orchestrator: TurnOrchestrator
        private let memory = ProcessMemoryProbe()
        private var nextDue: Double = 0
        private var firstAudioSeen = 0
        private(set) var samples: [SoakSample] = []

        init(
            started: ContinuousClock.Instant, interval: Duration, hub: CaptureHub,
            transcriber: ParakeetStreamingTranscriber, tap: ReplayTranscriptTap, orchestrator: TurnOrchestrator
        ) {
            self.started = started
            self.interval = max(1, interval.timeInterval)
            self.hub = hub
            self.transcriber = transcriber
            self.tap = tap
            self.orchestrator = orchestrator
        }

        /// A sample if `audioSeconds` reached the next one's time.
        func takeIfDue(at audioSeconds: Double) async -> SoakSample? {
            guard audioSeconds >= nextDue else { return nil }
            return await take(at: audioSeconds)
        }

        @discardableResult
        func take(at audioSeconds: Double) async -> SoakSample {
            nextDue = (audioSeconds / interval).rounded(.down) * interval + interval
            let capture = hub.statistics
            let asr = transcriber.statistics
            let snapshot = await orchestrator.snapshot
            let firstAudio = snapshot.latency.firstAudio
            // The latencies recorded since the last sample (the window keeps
            // the newest 200, far more than arrive between two samples).
            let fresh = min(firstAudio.totalCount - firstAudioSeen, firstAudio.samples.count)
            firstAudioSeen = firstAudio.totalCount
            let recent = firstAudio.samples.suffix(max(0, fresh))
            let frames = Self.frameCounts(capture)
            let sample = SoakSample(
                audioSeconds: audioSeconds,
                wallSeconds: (ContinuousClock.now - started).timeInterval,
                footprintBytes: memory.snapshot()?.physicalFootprint,
                asrChunks: asr.chunksProcessed,
                asrSeconds: asr.modelTime.timeInterval,
                framesDelivered: frames.delivered,
                framesDropped: frames.dropped,
                subscriberFramesDropped: frames.missedBySubscribers,
                userUtterances: await tap.userUtterances,
                agentReplies: await tap.agentReplies,
                topicBoundaries: await tap.topicBoundaries,
                rollovers: snapshot.session.rollovers,
                reseeds: snapshot.session.reseeds,
                firstAudioCount: recent.count,
                firstAudioMilliseconds: recent.isEmpty
                    ? nil : recent.reduce(0) { $0 + $1.timeInterval * 1_000 } / Double(recent.count),
                heapInUseBytes: HeapUsage.current().inUse)
            samples.append(sample)
            return sample
        }

        /// A sample's frame counters from the capture hub's statistics.
        /// `droppedFrames(frameLength:)` already includes the subscriber
        /// drops, so they are not added again; they are kept apart as well,
        /// because they were published (`SoakAnalysis.frameLoss`).
        static func frameCounts(
            _ capture: CaptureStatistics
        ) -> (delivered: Int64, dropped: Int64, missedBySubscribers: Int64) {
            (
                capture.framesPublished,
                capture.droppedFrames(frameLength: frameLength),
                capture.subscriberDroppedFrames
            )
        }

        /// The frames `CaptureReplayFeeder` plays: 20 ms at 16 kHz.
        static let frameLength = 320
    }

    /// Saves soak reports to `Documents/Soak` as JSON and Markdown, plus
    /// `latest.json` and `latest.md`, which `scripts/soak/soak.sh` copies
    /// off the simulator.
    enum SoakReportStore {
        static var directory: URL {
            URL.documentsDirectory.appending(path: "Soak", directoryHint: .isDirectory)
        }

        /// Removes `latest.*`, so a reader waiting for this run's report
        /// never picks up the previous one.
        static func clearLatest() {
            for name in ["latest.json", "latest.md"] {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }

        @discardableResult
        static func save(_ report: SoakReport) throws -> URL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = report.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let json = try report.jsonData()
            let markdown = Data(report.markdown.utf8)
            let url = directory.appending(path: "\(name).json")
            try json.write(to: url, options: .atomic)
            try markdown.write(to: directory.appending(path: "\(name).md"), options: .atomic)
            // Markdown first: the script waits for latest.json.
            try markdown.write(to: directory.appending(path: "latest.md"), options: .atomic)
            try json.write(to: directory.appending(path: "latest.json"), options: .atomic)
            return url
        }
    }
#endif
