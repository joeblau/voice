import BlauAudio
import BlauCore
import BlauTelemetry
import Darwin
import Foundation
import Testing

@testable import BlauTranscription

/// The VAD fixtures through the **real** Parakeet realtime EOU model and the
/// recorded Silero VAD events. Off by default (it needs the 224 MB model);
/// run it with the model `ModelManager` installed:
///
///     BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=parakeetRealtimeEOU \
///       BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
///     BLAU_ASR_MODEL_DIR=/tmp/blau-models/parakeetRealtimeEOU/<revision> \
///       swift test --filter ParakeetLiveTests
///
/// Optional: `BLAU_ASR_EOU_DEBOUNCE_MS`, `BLAU_ASR_SILENCE_COMMIT_MS` to try
/// other settings, and `BLAU_ASR_SOAK=1` (with `BLAU_ASR_SOAK_MINUTES`,
/// default 60) for the hour-long replay. Results are recorded in
/// docs/asr.md.
@Suite(
    "Parakeet live",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_ASR_MODEL_DIR"] != nil),
    .serialized
)
struct ParakeetLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    var modelDirectory: URL {
        URL(filePath: Self.environment["BLAU_ASR_MODEL_DIR"]!, directoryHint: .isDirectory)
    }

    var debounce: Duration {
        Self.environment["BLAU_ASR_EOU_DEBOUNCE_MS"].flatMap(Int.init).map { .milliseconds($0) }
            ?? ParakeetEouRecognizer.defaultEndOfUtteranceDebounce
    }

    var configuration: StreamingTranscriberConfiguration {
        var configuration = StreamingTranscriberConfiguration.standard
        if let delay = Self.environment["BLAU_ASR_SILENCE_COMMIT_MS"].flatMap(Int.init) {
            configuration.silenceCommitDelay = .milliseconds(delay)
        }
        return configuration
    }

    @Test(arguments: VADFixture.names)
    func transcribesTheFixtureAndCommitsEachUtteranceInTime(_ name: String) async throws {
        let fixture = try VADFixture.load(name)
        let script = try #require(FixtureScript.all[name])
        let vadEvents = try await recordedVADEvents(for: fixture)
        let recognizer = try await ParakeetEouRecognizer.load(
            modelDirectory: modelDirectory, endOfUtteranceDebounce: debounce, signposter: .disabled(.asr))
        let source = FixtureAudioSource(block: fixture.samples)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
            configuration: configuration, signposter: .disabled(.asr), clock: ManualClock())

        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: vadEvents)
        let statistics = replay.statistics

        print("[asr] \(name): debounce \(debounce), silence commit \(configuration.silenceCommitDelay)")
        for emitted in replay.emitted {
            guard case .final(let utterance) = emitted.event else { continue }
            let end = utterance.timeRange.end.sampleCount(sampleRate: 16_000)
            print(
                "[asr]   final \(samplesToMilliseconds(emitted.position - end)) ms + \(emitted.ingestTime.milliseconds) ms after its speech: \"\(utterance.text)\""
            )
        }
        // How far behind the input each partial's decoded audio ends, plus
        // the compute of the call that produced it.
        let partialLags = replay.emitted.compactMap { emitted -> Double? in
            guard case .partial(_, let range) = emitted.event else { return nil }
            return samplesToMilliseconds(emitted.position - range.end.sampleCount(sampleRate: 16_000))
                + emitted.ingestTime.milliseconds
        }
        print(
            """
            [asr]   \(partialLags.count) partials, decoded audio \(partialLags.min() ?? 0)–\(partialLags.max() ?? 0) ms \
            behind the input; \(statistics.chunksProcessed) chunks, mean \(statistics.meanChunkTime.milliseconds) ms, \
            slowest \(statistics.slowestChunk.milliseconds) ms; commits \(statistics.commits.map { "\($0.key.rawValue): \($0.value)" }.sorted())
            """
        )

        // Every sentence comes out, with the word error rate a 120M streaming
        // model reaches on synthetic speech.
        let hypothesis = replay.finals.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(hypothesis, reference: script.sentences.joined(separator: " "))
        print("[asr]   WER \(wer)")
        #expect(wer <= 0.2, "\(name): \(hypothesis)")
        #expect(replay.finals.count == script.sentences.count, "\(name): \(replay.finals.map(\.text))")

        // Each utterance is final within 1.2 s of the end of its speech
        // (audio time plus the compute of the call that committed it).
        for (label, lines) in zip(fixture.labels, script.segments)
        where lines.last?.endsUtterance == true && lines.allSatisfy(\.isRecognizable) {
            let emission = replay.emitted.first { emitted in
                guard case .final(let utterance) = emitted.event else { return false }
                return emitted.position >= label.upperBound
                    && utterance.timeRange.end.sampleCount(sampleRate: 16_000) > label.lowerBound
            }
            let committed = try #require(emission, "\(name): no final after \(label)")
            let latency =
                samplesToMilliseconds(committed.position - label.upperBound) + committed.ingestTime.milliseconds
            print("[asr]   speech ending at \(samplesToMilliseconds(label.upperBound)) ms final after \(latency) ms")
            #expect(latency < 1_200, "\(name): final \(latency) ms after the speech ended")
        }
    }

    /// When the model's own end-of-utterance token comes, with no debounce
    /// and no VAD: each fixture straight through the recognizer, reset after
    /// every end of utterance. This is the measurement behind the default
    /// debounce and the VAD fallback (docs/asr.md).
    @Test func theModelsEndOfUtteranceSignalTiming() async throws {
        var delays: [Double] = []
        var missed = 0
        for name in VADFixture.names {
            let fixture = try VADFixture.load(name)
            let recognizer = try await ParakeetEouRecognizer.load(
                modelDirectory: modelDirectory, endOfUtteranceDebounce: .zero, signposter: .disabled(.asr))
            var start: Int64 = 0
            var ends: [Int64] = []
            var frame: AudioFrame? = nil
            var offset: Int64 = 0
            while offset < Int64(fixture.samples.count) || frame != nil {
                let next =
                    frame
                    ?? AudioFrame(
                        samples: Array(fixture.samples[Int(offset)..<min(Int(offset) + 320, fixture.samples.count)]),
                        sampleOffset: offset)
                offset = max(offset, next.nextSampleOffset)
                frame = nil
                let output = try await recognizer.append(next)
                guard output.isEndOfUtterance else { continue }
                let decodedEnd = start + output.decodedSamples
                ends.append(next.sampleOffset + Int64(output.consumedSamples))
                await recognizer.reset()
                start = decodedEnd
                // Carry on from what the model decoded.
                frame = AudioFrame(
                    samples: Array(fixture.samples[Int(decodedEnd)..<Int(offset)]), sampleOffset: decodedEnd)
                if frame?.isEmpty == true { frame = nil }
            }
            for label in fixture.labels {
                if let end = ends.first(where: { $0 > label.upperBound }),
                    fixture.labels.first(where: { $0.lowerBound > label.upperBound }).map({ end < $0.lowerBound })
                        ?? true
                {
                    delays.append(samplesToMilliseconds(end - label.upperBound))
                } else {
                    missed += 1
                }
            }
            print(
                "[eou] \(name): EOU at \(ends.map(samplesToMilliseconds)) ms; speech ends \(fixture.labels.map { samplesToMilliseconds($0.upperBound) }) ms"
            )
        }
        print(
            "[eou] input position of the EOU after the end of speech: \(delays.sorted()) ms; \(missed) segments without one"
        )
        #expect(!delays.isEmpty)
    }

    /// An hour of looped fixtures through the real model: memory and the
    /// time per chunk must stay flat.
    @Test(
        .enabled(if: environment["BLAU_ASR_SOAK"] == "1"),
        .timeLimit(.minutes(60))
    )
    func anHourOfSpeechKeepsMemoryAndChunkTimeFlat() async throws {
        let minutes = Self.environment["BLAU_ASR_SOAK_MINUTES"].flatMap(Int.init) ?? 60
        let (block, vadEvents) = try await loopBlock()
        let samplesPerMinute = Int64(AudioFrame.captureSampleRate * 60)
        let repeats = Int((Int64(minutes) * samplesPerMinute + Int64(block.count) - 1) / Int64(block.count))
        let source = FixtureAudioSource(block: block, repeats: repeats)
        let events = (0..<repeats).flatMap { index in
            vadEvents.map { $0.shifted(by: Int64(index) * Int64(block.count)) }
        }
        let recognizer = try await ParakeetEouRecognizer.load(
            modelDirectory: modelDirectory, endOfUtteranceDebounce: debounce, signposter: .disabled(.asr))
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
            configuration: configuration, signposter: .disabled(.asr), clock: ManualClock())

        var minutesSeen: [MinuteSample] = []
        var previous = (chunks: Int64(0), time: Duration.zero)
        let started = ContinuousClock.now
        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: events) { position in
            guard position / samplesPerMinute > Int64(minutesSeen.count) else { return }
            let statistics = transcriber.statistics
            let chunks = statistics.chunksProcessed - previous.chunks
            let time = statistics.modelTime - previous.time
            previous = (statistics.chunksProcessed, statistics.modelTime)
            let sample = MinuteSample(
                minute: minutesSeen.count + 1, chunks: chunks,
                meanChunk: chunks == 0 ? .zero : time / Int(chunks), footprint: physicalFootprint())
            minutesSeen.append(sample)
            print(
                "[soak] minute \(sample.minute): \(chunks) chunks, mean \(sample.meanChunk.milliseconds) ms, footprint \(sample.footprint / 1_048_576) MB"
            )
        }
        let wall = ContinuousClock.now - started
        let statistics = replay.statistics
        print(
            """
            [soak] \(minutes) min of audio in \(wall): \(statistics.utterancesCommitted) utterances, \
            \(statistics.chunksProcessed) chunks, mean \(statistics.meanChunkTime.milliseconds) ms, \
            slowest \(statistics.slowestChunk.milliseconds) ms, commits \(statistics.commits)
            """
        )

        // Skip the first minutes (Core ML warm-up, allocator growth).
        let settled = Array(minutesSeen.dropFirst(min(5, minutesSeen.count / 4)))
        let tenth = max(1, settled.count / 10)
        let early = settled.prefix(tenth)
        let late = settled.suffix(tenth)
        func mean(_ samples: ArraySlice<MinuteSample>) -> Double {
            samples.map(\.meanChunk.milliseconds).reduce(0, +) / Double(max(samples.count, 1))
        }
        let footprintGrowth = (late.map(\.footprint).max() ?? 0) - (early.map(\.footprint).max() ?? 0)
        print(
            "[soak] chunk time early \(mean(early)) ms, late \(mean(late)) ms; footprint growth \(footprintGrowth / 1_048_576) MB"
        )
        #expect(mean(late) <= mean(early) * 1.3 + 1, "Per-chunk time grew")
        #expect(footprintGrowth < 64 * 1_048_576, "Memory grew by \(footprintGrowth / 1_048_576) MB")
        #expect(statistics.utterancesCommitted > Int64(minutes) * 10)
    }

    struct MinuteSample {
        let minute: Int
        let chunks: Int64
        let meanChunk: Duration
        let footprint: Int64
    }

    /// The four fixtures back to back, each padded to whole VAD chunks so
    /// the recorded VAD events repeat exactly, and their events.
    func loopBlock() async throws -> ([Float], [VoiceActivityEvent]) {
        var block: [Float] = []
        var events: [VoiceActivityEvent] = []
        for name in VADFixture.names {
            let fixture = try VADFixture.load(name)
            let offset = Int64(block.count)
            events += try await recordedVADEvents(for: fixture).map { $0.shifted(by: offset) }
            block += fixture.samples
            let padding = (4_096 - fixture.samples.count % 4_096) % 4_096
            block += [Float](repeating: 0, count: padding)
        }
        return (block, events)
    }
}

/// The process's physical memory footprint (what Xcode's memory gauge and
/// jetsam use), in bytes.
func physicalFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}
