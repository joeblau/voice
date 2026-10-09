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
    ///   real `CaptureHub` (the app's virtual input) at `speed`.
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
            // Whole seconds, so the report's ISO 8601 JSON round-trips.
            let startedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let clock = ContinuousClock()
            let started = clock.now
            let script = ConversationAudioScript.session(
                lasting: configuration.duration, exchangesPerTopic: Self.exchangesPerTopic, interlude: .tvAndSilence)

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
            let (vadModel, vadName) = await Self.voiceActivityModel(directory: vadModelDirectory)
            let vad = VoiceActivitySegmenter(model: vadModel)
            let (recognizer, recognizerName) = try await Self.recognizer(
                configuration.recognizer, directory: asrModelDirectory, script: script)
            let transcriber = ParakeetStreamingTranscriber(
                recognizer: recognizer, audio: hub, voiceActivity: vad, conversationID: conversationID)

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

            do {
                try await CaptureReplayFeeder(script: script, speed: speed).feed(
                    into: hub,
                    consumed: { min(vad.statistics.samplesProcessed, await transcriber.receivedPosition ?? 0) },
                    beforeLine: { line in
                        // The user waits for Blau's answer to every earlier
                        // line before speaking (at most 20 s; a reply that
                        // never comes shows up in the report).
                        let deadline = ContinuousClock.now + .seconds(20)
                        while await tap.agentReplies < line, ContinuousClock.now < deadline {
                            try? await Task.sleep(for: .milliseconds(5))
                        }
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
            await orchestrator.waitUntilSettled()
            let deadline = clock.now + .seconds(30)
            while await tap.agentReplies < tap.userUtterances, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                await orchestrator.waitUntilSettled()
            }
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
                connections: server.sockets.count, failedTurns: failed)
            let setup = SoakReport.Setup(
                audioSeconds: totalSeconds, speed: speed, recognizer: recognizerName, voiceActivity: vadName,
                audio: "user speech, TV dialogue (\(script.backgroundBursts.count) bursts) and silence",
                rolloverAfterSeconds: configuration.continuity.rolloverAfter?.timeInterval,
                sampleIntervalSeconds: configuration.sampleInterval.timeInterval)
            let report = SoakReport(
                device: .current, startedAt: startedAt, wallSeconds: (clock.now - started).timeInterval, setup: setup,
                outcome: outcome, samples: await sampler.samples)
            Log.performance.notice("Soak finished: \(report.summary, privacy: .public)")
            return report
        }

        private static func voiceActivityModel(directory: URL?) async -> (any SpeechProbabilityModel, String) {
            if let directory, let silero = try? await SileroSpeechProbabilityModel(modelDirectory: directory) {
                return (silero, "Silero VAD")
            }
            return (EnergySpeechProbabilityModel(), "energy VAD")
        }

        private static func recognizer(
            _ kind: PerfReplayConfiguration.Recognizer, directory: URL?, script: ConversationAudioScript
        ) async throws -> (any StreamingSpeechRecognizer, String) {
            if kind == .parakeet, let directory {
                return (try await ParakeetEouRecognizer.load(modelDirectory: directory), "Parakeet EOU")
            }
            let words = script.words.map {
                AlignedTranscriptRecognizer.Word(text: $0.text, end: $0.end, endsUtterance: $0.endsLine)
            }
            // Timed by the call: the aligned recognizer runs no model and
            // reports no time of its own, and `asr.chunkLatency` needs one.
            return (TimedSpeechRecognizer(AlignedTranscriptRecognizer(words: words)), "scripted ASR")
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
            let sample = SoakSample(
                audioSeconds: audioSeconds,
                wallSeconds: (ContinuousClock.now - started).timeInterval,
                footprintBytes: memory.snapshot()?.physicalFootprint,
                asrChunks: asr.chunksProcessed,
                asrSeconds: asr.modelTime.timeInterval,
                framesDelivered: capture.framesPublished,
                framesDropped: capture.droppedFrames(frameLength: 320) + capture.subscriberDroppedFrames,
                userUtterances: await tap.userUtterances,
                agentReplies: await tap.agentReplies,
                topicBoundaries: await tap.topicBoundaries,
                rollovers: snapshot.session.rollovers,
                reseeds: snapshot.session.reseeds,
                firstAudioCount: recent.count,
                firstAudioMilliseconds: recent.isEmpty
                    ? nil : recent.reduce(0) { $0 + $1.timeInterval * 1_000 } / Double(recent.count))
            samples.append(sample)
            return sample
        }
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
