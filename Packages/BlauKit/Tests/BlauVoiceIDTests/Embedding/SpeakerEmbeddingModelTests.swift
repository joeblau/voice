import BlauCore
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Testing

@testable import BlauVoiceID

/// Runs the real WeSpeaker Core ML model over the speaker fixture set. Off by
/// default (it needs the downloaded model); point `BLAU_SPEAKER_MODEL_DIR`
/// at the installed `.speakerEmbedding` model directory (the one holding
/// `wespeaker_v2.mlmodelc`), for example after
///
///     BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=speakerEmbedding \
///       BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
///     BLAU_SPEAKER_MODEL_DIR=/tmp/blau-models/speakerEmbedding/df2625ac79a7ac6b65ad868fee6d80f320da4232 \
///       swift test --filter SpeakerEmbeddingModelTests
///
/// `BLAU_SPEAKER_BENCHMARK=1` also times every compute-unit setting (see
/// docs/benchmarks.md).
@Suite(
    "WeSpeaker model (opt-in)",
    .enabled(if: SpeakerModelEnvironment.modelDirectory != nil),
    .serialized
)
struct SpeakerEmbeddingModelTests {
    static var modelDirectory: URL? { SpeakerModelEnvironment.modelDirectory }

    private func loadEmbedder(_ units: SpeakerEmbeddingComputeUnits = .cpuAndNeuralEngine) async throws
        -> WeSpeakerEmbedder
    {
        try await WeSpeakerEmbedder.load(modelDirectory: try #require(Self.modelDirectory), computeUnits: units)
    }

    // MARK: Acceptance: same speaker scores higher than different speakers

    /// Every same-speaker pair must score higher than every
    /// different-speaker pair, at each window the gate uses and on the
    /// whole clip.
    @Test(arguments: [SpeakerEmbeddingWindow.short, .long, SpeakerEmbeddingWindow(duration: .seconds(10))])
    func sameSpeakerScoresAboveDifferentSpeakers(window: SpeakerEmbeddingWindow) async throws {
        let clips = try SpeakerFixtures.load()
        let embedder = try await loadEmbedder()
        let embeddings = try await embedder.embed(clips.map { window.prefix(of: $0.audio) })

        var same: [Float] = []
        var different: [Float] = []
        var hardestSame = (score: Float.infinity, pair: "")
        var hardestDifferent = (score: -Float.infinity, pair: "")
        for i in clips.indices {
            for j in clips.indices where j > i {
                let score = embeddings[i].cosineSimilarity(to: embeddings[j])
                let pair = "\(clips[i].name)/\(clips[j].name)"
                if clips[i].speaker == clips[j].speaker {
                    same.append(score)
                    if score < hardestSame.score { hardestSame = (score, pair) }
                } else {
                    different.append(score)
                    if score > hardestDifferent.score { hardestDifferent = (score, pair) }
                }
            }
        }
        #expect(same.count == 12 && different.count == 54)
        let label = "\(SpeakerEmbeddingBenchmark.milliseconds(window.duration)) ms window"
        print(
            """
            [voiceid] \(label): same speaker min \(hardestSame.score) (\(hardestSame.pair)) \
            mean \(mean(same)); different speaker max \(hardestDifferent.score) (\(hardestDifferent.pair)) \
            mean \(mean(different)); margin \(hardestSame.score - hardestDifferent.score)
            """)
        #expect(
            hardestSame.score > hardestDifferent.score,
            "\(label): \(hardestSame.pair) scored \(hardestSame.score), below \(hardestDifferent.pair) at \(hardestDifferent.score)"
        )
    }

    /// Enrollment-style check: a voiceprint from two clips, scored with the
    /// third clip of every speaker, is highest for its own speaker.
    @Test func heldOutClipMatchesItsOwnSpeakersVoiceprint() async throws {
        let clips = try SpeakerFixtures.load()
        let embedder = try await loadEmbedder()
        let short = try await embedder.embed(clips.map { SpeakerEmbeddingWindow.short.prefix(of: $0.audio) })
        let full = try await embedder.embed(clips.map(\.audio))
        let probes = clips.indices.filter { clips[$0].utterance == "a0003" }
        for speaker in Set(clips.map(\.speaker)).sorted() {
            let enrollment = clips.indices.filter { clips[$0].speaker == speaker && clips[$0].utterance != "a0003" }
            let voiceprint = try #require(SpeakerEmbedding.mean(of: enrollment.map { full[$0] }))
            let genuine = try #require(probes.first { clips[$0].speaker == speaker })
            let genuineScore = short[genuine].cosineSimilarity(to: voiceprint)
            for impostor in probes where clips[impostor].speaker != speaker {
                let impostorScore = short[impostor].cosineSimilarity(to: voiceprint)
                #expect(
                    genuineScore > impostorScore,
                    "\(speaker) voiceprint: \(clips[genuine].name) \(genuineScore) vs \(clips[impostor].name) \(impostorScore)"
                )
            }
        }
    }

    // MARK: Correctness of the wrapper

    @Test func modelHasTheExpectedLayout() async throws {
        let directory = try #require(Self.modelDirectory)
        let network = try await CoreMLSpeakerEmbeddingNetwork.load(
            contentsOf: directory.appending(path: WeSpeakerEmbedder.modelBundleName))
        #expect(network.shape == .weSpeaker)
    }

    /// Blau's input layout (repeat padding, all-ones mask) gives the same
    /// vector as FluidAudio's own `EmbeddingExtractor`.
    @Test func matchesFluidAudiosEmbeddingExtractor() async throws {
        let clip = try #require(try SpeakerFixtures.load().first)
        let audio = SpeakerEmbeddingWindow.short.prefix(of: clip.audio)
        let ours = try await loadEmbedder(.cpuOnly).embed(audio)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(
            contentsOf: try #require(Self.modelDirectory).appending(path: WeSpeakerEmbedder.modelBundleName),
            configuration: configuration)
        let extractor = EmbeddingExtractor(embeddingModel: model)
        let mask = [Float](repeating: 1, count: SpeakerEmbeddingNetworkShape.weSpeaker.maskFrameCount)
        let theirs = try #require(try extractor.getEmbeddings(audio: audio.samples, masks: [mask]).first)
        let reference = try #require(
            SpeakerEmbedding(
                normalizing: theirs, modelIdentifier: ours.modelIdentifier, audioDuration: ours.audioDuration))

        let similarity = ours.cosineSimilarity(to: reference)
        print("[voiceid] cosine with FluidAudio's EmbeddingExtractor: \(similarity)")
        #expect(similarity > 0.999)
    }

    /// A segment's embedding doesn't depend on the other segments in the
    /// call. (The model's three slots share one waveform, so packing
    /// different segments into them would silently embed the first one
    /// three times.)
    @Test func otherSegmentsInTheCallDoNotChangeTheResult() async throws {
        let clips = try SpeakerFixtures.load()
        let embedder = try await loadEmbedder(.cpuOnly)
        let together = try await embedder.embed(clips.map(\.audio))
        for index in [0, 4, 11] {
            let alone = try await embedder.embed(clips[index].audio)
            #expect(alone.cosineSimilarity(to: together[index]) > 0.9999, "\(clips[index].name)")
        }
    }

    @Test func outputIsUnitLength() async throws {
        let clip = try #require(try SpeakerFixtures.load().first)
        let embedding = try await loadEmbedder().embed(clip.audio)
        #expect(embedding.dimension == 256)
        let norm = embedding.vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-4)
    }

    // MARK: Latency

    /// Times the standard scenarios on every compute-unit setting and prints
    /// Markdown tables for docs/benchmarks.md: the full embedder call, then
    /// the model run alone. Opt-in on top of the model:
    /// `BLAU_SPEAKER_BENCHMARK=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_SPEAKER_BENCHMARK"] == "1"))
    func benchmark() async throws {
        let directory = try #require(Self.modelDirectory)
        let bundle = directory.appending(path: WeSpeakerEmbedder.modelBundleName)
        let benchmark = SpeakerEmbeddingBenchmark(iterations: 100, warmUpIterations: 10)
        let scenarios = SpeakerEmbeddingBenchmark.Scenario.standard + [.enrollmentClip]
        for units in SpeakerEmbeddingComputeUnits.allCases {
            let loadStart = ContinuousClock.now
            let network = try await CoreMLSpeakerEmbeddingNetwork.load(contentsOf: bundle, computeUnits: units)
            let loadTime = ContinuousClock.now - loadStart
            let embedder = WeSpeakerEmbedder(network: network)
            let calls = try await benchmark.run(embedder, scenarios: scenarios)
            let modelOnly = try await benchmark.run(network, scenarios: scenarios)
            print(
                """
                [voiceid] compute units: \(units.rawValue) (load \(SpeakerEmbeddingBenchmark.milliseconds(loadTime)) ms)
                WeSpeakerEmbedder.embed:
                \(SpeakerEmbeddingBenchmark.markdownTable(calls))
                Model run only:
                \(SpeakerEmbeddingBenchmark.markdownTable(modelOnly))

                """)
            #expect(calls.allSatisfy { $0.samples.count == 100 })
        }
    }

    /// Where Core ML places the model's operations with the production
    /// compute units, weighted by its cost estimate. Explains the latency
    /// numbers in docs/benchmarks.md. Opt-in: `BLAU_SPEAKER_BENCHMARK=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_SPEAKER_BENCHMARK"] == "1"))
    func computePlan() async throws {
        let bundle = try #require(Self.modelDirectory).appending(path: WeSpeakerEmbedder.modelBundleName)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: bundle, configuration: configuration)
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else {
            Issue.record("Expected an ML program with a main function")
            return
        }
        var operations: [String: Int] = [:]
        var cost: [String: Double] = [:]
        for operation in main.block.operations {
            guard let usage = plan.deviceUsage(for: operation) else { continue }
            let device: String
            switch usage.preferred {
            case .cpu: device = "CPU"
            case .gpu: device = "GPU"
            case .neuralEngine: device = "Neural Engine"
            @unknown default: device = "other"
            }
            operations[device, default: 0] += 1
            cost[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
        }
        for device in operations.keys.sorted() {
            print(
                "[voiceid] compute plan: \(device): \(operations[device]!) ops, \(String(format: "%.1f", cost[device]! * 100))% of estimated cost"
            )
        }
        #expect(!operations.isEmpty)
    }

    private func mean(_ values: [Float]) -> Float {
        values.reduce(0, +) / Float(values.count)
    }
}

/// Where the opt-in model tests find the real model.
enum SpeakerModelEnvironment {
    /// `BLAU_SPEAKER_MODEL_DIR`: the `.speakerEmbedding` model directory.
    static var modelDirectory: URL? {
        ProcessInfo.processInfo.environment["BLAU_SPEAKER_MODEL_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
    }
}
