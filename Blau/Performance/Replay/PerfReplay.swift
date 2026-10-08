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
    import SwiftData
    import os

    /// How the performance suite's scripted session (#73) runs. Read from the
    /// launch environment the perf tests set (docs/performance.md).
    struct PerfReplayConfiguration: Sendable, Hashable {
        /// Which speech recognizer the replay transcribes with.
        enum Recognizer: String, Sendable, Hashable {
            /// `AlignedTranscriptRecognizer`: the real streaming transcriber
            /// with the script's word alignment instead of a model. Hermetic;
            /// emits no `asr.chunk`.
            case scripted
            /// Parakeet realtime EOU, when the models are installed (device
            /// runs). Emits `asr.chunk`. Falls back to `scripted` otherwise.
            case parakeet
        }

        /// Spoken length of the session, on the audio timeline.
        var duration: Duration = .seconds(300)
        /// How many times faster than real time the audio is played, or `nil`
        /// for as fast as the pipeline takes it.
        var speed: Double? = 10
        var recognizer: Recognizer = .scripted

        /// Launch environment variable that opens the replay screen.
        static let enabledKey = "BLAU_PERF_REPLAY"
        static let secondsKey = "BLAU_PERF_REPLAY_SECONDS"
        static let speedKey = "BLAU_PERF_REPLAY_SPEED"
        static let recognizerKey = "BLAU_PERF_REPLAY_ASR"

        static func isRequested(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            environment[enabledKey] == "1"
        }

        /// The configuration in `environment`: `BLAU_PERF_REPLAY_SECONDS`
        /// (default 300), `BLAU_PERF_REPLAY_SPEED` (a factor, `realtime` or
        /// `max`; default 10) and `BLAU_PERF_REPLAY_ASR` (`scripted` or
        /// `parakeet`).
        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            if let seconds = environment[Self.secondsKey].flatMap(Double.init), seconds > 0 {
                duration = .seconds(seconds)
            }
            switch environment[Self.speedKey] {
            case "max": speed = nil
            case "realtime": speed = 1
            case let value?: speed = Double(value).flatMap { $0 > 0 ? $0 : nil } ?? speed
            case nil: break
            }
            if let recognizer = environment[Self.recognizerKey].flatMap(Recognizer.init(rawValue:)) {
                self.recognizer = recognizer
            }
        }

        init(duration: Duration, speed: Double?, recognizer: Recognizer = .scripted) {
            self.duration = duration
            self.speed = speed
            self.recognizer = recognizer
        }
    }

    /// What one replay did, shown on the replay screen and attached to the
    /// perf test's results. In a scripted run every count is deterministic.
    struct PerfReplayReport: Codable, Sendable, Hashable {
        var audioSeconds: Double = 0
        var wallSeconds: Double = 0
        var lines = 0
        var userUtterances = 0
        var agentReplies = 0
        var topicUnits = 0
        var topicBoundaries = 0
        var memoryChunks = 0
        var memorySearches = 0
        var memoryResults = 0
        var verifications = 0
        var accepted = 0
        var saves = 0
        var replyAudioSeconds: Double = 0
        var recognizer = ""
        var voiceActivity = ""

        /// Whether the pipeline handled the whole script: every line was
        /// transcribed, answered, segmented, searched and verified.
        var isComplete: Bool {
            lines > 0 && userUtterances == lines && agentReplies == lines && topicUnits == lines
                && memorySearches == lines && memoryResults > 0 && verifications >= lines && saves > 0
        }

        var summary: String {
            """
            \(Int(audioSeconds)) s of audio in \(String(format: "%.1f", wallSeconds)) s; \
            \(lines) lines, \(userUtterances) transcribed, \(agentReplies) replies; \
            \(topicUnits) topic units, \(topicBoundaries) boundaries; \
            \(memoryChunks) chunks, \(memorySearches) searches, \(memoryResults) results; \
            \(verifications) verifications (\(accepted) accepted); \(saves) saves; \
            \(recognizer), \(voiceActivity)
            """
        }
    }

    /// The performance suite's scripted session (#73): the real voice loop
    /// pipeline, from the capture hub to the stored transcript, driven by a
    /// `ConversationAudioScript` and answered by a `ScriptedRealtimeServer`.
    ///
    /// - **Audio**: the script's microphone audio (speech-shaped lines, room
    ///   noise in between) through the real `CaptureHub` at `speed`.
    /// - **VAD and ASR**: the real `VoiceActivitySegmenter` (energy model, or
    ///   Silero when installed) and `ParakeetStreamingTranscriber`, on the
    ///   script's word alignment (`AlignedTranscriptRecognizer`) or on
    ///   Parakeet itself.
    /// - **Voice ID**: every VAD segment is scored against a voiceprint
    ///   (`voiceid.verify`). The embeddings are synthetic: WeSpeaker needs a
    ///   model, and the verification gate (#47) isn't built yet.
    /// - **Turns**: the real `TurnOrchestrator` and `RealtimeClient`; the
    ///   server answers each line with the script's reply, as streamed
    ///   PCM16 audio and transcript deltas.
    /// - **Transcript**: a `ConversationStore` on a temporary on-disk store
    ///   (`db.save`).
    /// - **Topics and memory**: each exchange is segmented by
    ///   `StreamingTopicSegmenter` (`topics.segment`) and indexed in a
    ///   temporary `MemoryIndex`; each user line runs the hybrid
    ///   `MemorySearch` behind Grok's `search_memory` tool (#64): BM25 and
    ///   int8 vectors fused with weighted RRF (`memory.search`).
    ///
    /// Nothing touches the user's data, the network or the microphone; the
    /// temporary stores are deleted when the run ends.
    actor PerfReplay {
        let configuration: PerfReplayConfiguration
        /// Installed model directories, for `.parakeet` runs.
        let vadModelDirectory: URL?
        let asrModelDirectory: URL?

        init(configuration: PerfReplayConfiguration, vadModelDirectory: URL? = nil, asrModelDirectory: URL? = nil) {
            self.configuration = configuration
            self.vadModelDirectory = vadModelDirectory
            self.asrModelDirectory = asrModelDirectory
        }

        enum Failure: Error, CustomStringConvertible {
            case incomplete(PerfReplayReport)

            var description: String {
                switch self {
                case .incomplete(let report): "The replay didn't finish the script: \(report.summary)"
                }
            }
        }

        // swiftlint:disable:next function_body_length
        func run() async throws -> PerfReplayReport {
            let clock = ContinuousClock()
            let started = clock.now
            let script = ConversationAudioScript.session(lasting: configuration.duration)
            var report = PerfReplayReport()
            report.lines = script.lines.count
            report.audioSeconds = script.duration.timeInterval

            let directory = FileManager.default.temporaryDirectory.appending(
                path: "PerfReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            report.recognizer = recognizerName
            report.voiceActivity = vadName
            let transcriber = ParakeetStreamingTranscriber(
                recognizer: recognizer, audio: hub, voiceActivity: vad, conversationID: conversationID)

            // Grok, played by the scripted server.
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
                    endpoint: URL(string: "wss://replay.blau.invalid/v1/realtime")!,
                    tokenProvider: ScriptedRealtimeServer.TokenProvider(), connector: server),
                configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore()),
                audio: output, transcript: tap)

            // Voice ID on every speech segment VAD reports.
            let voiceprint = ReplayVoiceprint()
            let segments = vad.events()
            let verification = Task {
                var counts = (verified: 0, accepted: 0)
                for await event in segments {
                    guard case .speechEnded(let segment) = event else { continue }
                    let result = voiceprint.scorer.verify(voiceprint.probe(for: segment), config: voiceprint.config)
                    counts.verified += 1
                    if result.decision == .accept { counts.accepted += 1 }
                }
                return counts
            }

            try await orchestrator.start(conversationID: conversationID, waitsForConnection: true)
            try await transcriber.start()
            // Subscribed here, before the first frame is fed, so VAD sees the
            // whole stream and its sample count is a stream position (the
            // feeder paces itself by it).
            let vadFrames = hub.frames()
            let voiceActivity = Task {
                for await frame in vadFrames { await vad.process(frame) }
                await vad.finish()
            }
            let turns = Task { await orchestrator.run(transcript: transcriber.events) }
            Log.performance.notice(
                "Perf replay: \(script.lines.count, privacy: .public) lines, \(Int(report.audioSeconds), privacy: .public) s, \(recognizerName, privacy: .public)"
            )

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
                    })
            } catch {
                hub.finish()
                voiceActivity.cancel()
                await transcriber.finish()
                await orchestrator.shutdown()
                throw error
            }
            hub.finish()
            await voiceActivity.value
            await transcriber.finish()
            await turns.value

            // The orchestrator writes the transcript on a queue of its own:
            // wait for the user's last lines to reach the tap, then for the
            // replies still streaming in to be written too.
            await orchestrator.waitUntilSettled()
            let deadline = clock.now + .seconds(30)
            while await tap.agentReplies < tap.userUtterances, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                await orchestrator.waitUntilSettled()
            }
            await orchestrator.shutdown()
            let counts = await verification.value
            let tapReport = await tap.finish()

            report.userUtterances = tapReport.userUtterances
            report.agentReplies = tapReport.agentReplies
            report.topicUnits = tapReport.topicUnits
            report.topicBoundaries = tapReport.topicBoundaries
            report.memoryChunks = tapReport.memoryChunks
            report.memorySearches = tapReport.memorySearches
            report.memoryResults = tapReport.memoryResults
            report.verifications = counts.verified
            report.accepted = counts.accepted
            report.saves = await store.statistics.saveCount
            report.replyAudioSeconds = Double(output.receivedBytes / 2) / Double(output.sampleRate)
            report.wallSeconds = (clock.now - started).timeInterval
            Log.performance.notice("Perf replay finished: \(report.summary, privacy: .public)")
            guard report.isComplete else { throw Failure.incomplete(report) }
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
            return (AlignedTranscriptRecognizer(words: words), "scripted ASR")
        }
    }

    /// A voiceprint and probe embeddings for the replay's voice ID step:
    /// 256-d unit vectors around one synthetic speaker, so every probe is
    /// the enrolled speaker (cosine about 0.7, above the calibrated accept
    /// thresholds).
    struct ReplayVoiceprint: Sendable {
        let config = VoiceIDConfig.calibrated
        let scorer: VoiceprintScorer
        private let speaker: [Float]

        init(seed: UInt64 = 0x0000_0B1A) {
            var random = SeededRandomGenerator(seed: seed)
            let dimension = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM.dimension
            let speaker = (0..<dimension).map { _ in Float(random.nextUnit() * 2 - 1) }
            let calibrated = VoiceIDConfig.calibrated
            let enrollment = (0..<5).map { clip in
                Self.embedding(
                    around: speaker, seed: seed &+ UInt64(clip) &+ 1, model: calibrated.modelIdentifier, seconds: 8)
            }
            self.speaker = speaker
            // Five valid, same-model embeddings: the enrollment can't be invalid.
            scorer = try! VoiceprintScorer(enrollment: enrollment, scoring: calibrated.scoring)
        }

        /// A probe for `segment`: the speaker plus noise seeded by its start.
        func probe(for segment: SpeechSegment) -> SpeakerEmbedding {
            let seconds = Double(segment.sampleRange.count) / Double(segment.sampleRate)
            return Self.embedding(
                around: speaker, seed: UInt64(segment.sampleRange.lowerBound), model: config.modelIdentifier,
                seconds: seconds)
        }

        private static func embedding(around speaker: [Float], seed: UInt64, model: String, seconds: Double)
            -> SpeakerEmbedding
        {
            var random = SeededRandomGenerator(seed: seed)
            let speakerNorm = speaker.reduce(0) { $0 + $1 * $1 }.squareRoot()
            // Noise with about the speaker's norm: cosine about 0.7.
            let scale = speakerNorm / Float(speaker.count).squareRoot() * 1.7
            let vector = speaker.map { $0 + Float(random.nextUnit() * 2 - 1) * scale }
            return SpeakerEmbedding(normalizing: vector, modelIdentifier: model, audioDuration: .seconds(seconds))!
        }
    }

    /// Writes the replay's transcript to the `ConversationStore`, and on the
    /// way does what the rest of the app will do with each utterance: a
    /// memory search for every user line, and topic segmentation and memory
    /// indexing for every finished exchange.
    actor ReplayTranscriptTap: TurnTranscriptRecording {
        struct Report: Sendable {
            var userUtterances = 0
            var agentReplies = 0
            var topicUnits = 0
            var topicBoundaries = 0
            var memoryChunks = 0
            var memorySearches = 0
            var memoryResults = 0
        }

        private let store: ConversationStore
        private let index: MemoryIndex
        private let segmenter: StreamingTopicSegmenter
        private let conversationID: ConversationID
        private let memorySearch: MemorySearch
        private let embedder = LexicalTextEmbedder(dimension: 256)

        private var seen: Set<UUID> = []
        private var pendingUser: [Utterance] = []
        private var chunks: [MemoryChunk] = []
        private var report = Report()

        init(
            store: ConversationStore, index: MemoryIndex, segmenter: StreamingTopicSegmenter,
            conversationID: ConversationID
        ) {
            self.store = store
            self.index = index
            memorySearch = MemorySearch(index: index, embedder: ReplayQueryEmbedder())
            self.segmenter = segmenter
            self.conversationID = conversationID
        }

        var userUtterances: Int { report.userUtterances }
        var agentReplies: Int { report.agentReplies }

        // MARK: TurnTranscriptRecording

        func beginConversation(_ id: ConversationID, at date: Date) async throws {
            try await store.beginConversation(id, at: date)
        }

        func record(_ utterance: Utterance) async throws {
            try await store.record(utterance)
            // Updates of an utterance (a refinement, a cut reply) are stored
            // but not processed twice.
            guard seen.insert(utterance.id).inserted, !utterance.isBlank else { return }
            switch utterance.speaker {
            case .user:
                report.userUtterances += 1
                pendingUser.append(utterance)
                await search(for: utterance.text)
            case .agent:
                // Counted once the exchange is segmented and indexed: the
                // script speaks its next line when the count goes up, so
                // that line's search always sees this exchange and every
                // count in the report repeats exactly.
                await closeExchange(reply: utterance)
                report.agentReplies += 1
            }
        }

        func finishConversation(_ id: ConversationID, at date: Date) async throws {
            try await store.finishConversation(id, at: date)
        }

        func flush() async throws {
            try await store.flush()
        }

        /// Ends topic segmentation and returns the counts.
        func finish() async -> Report {
            report.topicBoundaries += await segmenter.finish().filter(\.isConfirmation).count
            return report
        }

        // MARK: Topics and memory

        private func closeExchange(reply: Utterance) async {
            guard let first = pendingUser.first, let last = pendingUser.last else { return }
            let userText = pendingUser.map(\.text).joined(separator: " ")
            pendingUser.removeAll()
            // On the audio timeline, like the user's utterances (the agent's
            // utterance is dated by the orchestrator's clock).
            let unit = TopicUnit(
                id: first.id, utteranceIDs: [first.id, last.id, reply.id], userText: userText, agentText: reply.text,
                timeRange: TimeRange(start: first.timeRange.start, end: last.timeRange.end),
                startedAt: first.startedAt)
            do {
                let events = try await segmenter.append(unit)
                report.topicUnits += 1
                let confirmed = events.filter(\.isConfirmation)
                report.topicBoundaries += confirmed.count
                for _ in confirmed {
                    _ = try await store.openTopic(at: first.startedAt)
                }
            } catch {
                Log.performance.error(
                    "Perf replay: topic segmentation failed: \(String(describing: error), privacy: .public)")
            }

            let text = userText + "\n" + reply.text
            let chunk = MemoryChunk(
                sourceID: conversationID.rawValue, sourceKind: .conversation, ordinal: chunks.count, text: text,
                keyText: text, createdAt: first.startedAt, conversationID: conversationID.rawValue)
            chunks.append(chunk)
            do {
                try await index.replace(
                    [MemoryIndex.SourceChunks(kind: .conversation, sourceID: conversationID.rawValue, chunks: chunks)],
                    embeddings: [chunk.id: embedding(of: text)])
                report.memoryChunks = chunks.count
            } catch {
                Log.performance.error("Perf replay: indexing failed: \(String(describing: error), privacy: .public)")
            }
        }

        /// The memory search Grok's `search_memory` tool runs (#64): BM25 and
        /// int8 vectors fused with weighted RRF, then dedupe and snippets,
        /// inside its own `memory.search` interval.
        private func search(for query: String) async {
            do {
                let response = try await memorySearch.search(query, limit: 5)
                report.memorySearches += 1
                report.memoryResults += response.results.count
            } catch {
                Log.performance.error(
                    "Perf replay: memory search failed: \(String(describing: error), privacy: .public)")
            }
        }

        private func embedding(of text: String) -> TextEmbedding {
            ReplayQueryEmbedder.embedding(of: text, embedder: embedder)
        }
    }

    /// Embeds the replay's chunks and queries with the lexical embedder (the
    /// text-embedding model needs a download), so the vector half of every
    /// search runs.
    struct ReplayQueryEmbedder: MemoryQueryEmbedding {
        static let modelVersion = "replay-lexical-256"
        private let embedder = LexicalTextEmbedder(dimension: 256)

        func embedQuery(_ text: String) async throws -> TextEmbedding {
            Self.embedding(of: text, embedder: embedder)
        }

        static func embedding(of text: String, embedder: LexicalTextEmbedder) -> TextEmbedding {
            TextEmbedding(
                fullOutput: embedder.vector(for: text), dimensions: 256, modelVersion: modelVersion,
                tokenCount: ScriptedConversation.words(in: text).count, truncatedTokens: 0)
        }
    }

    extension TopicSegmentationEvent {
        fileprivate var isConfirmation: Bool {
            if case .confirmed = self { true } else { false }
        }
    }
#endif
