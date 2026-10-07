import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// A labelled speech fixture from `Fixtures/VAD` (see the README there and
/// `scripts/make-vad-fixtures.py`).
struct VADFixture: Sendable {
    let name: String
    let samples: [Float]
    /// Expected segments, in 16 kHz sample offsets.
    let labels: [Range<Int64>]

    static let names = ["conversation-quiet", "conversation-noisy", "monologue-long", "pauses"]

    static func load(_ name: String) throws -> VADFixture {
        let wav = try Data(contentsOf: try resource("\(name).wav"))
        let labelData = try Data(contentsOf: try resource("\(name).labels.json"))
        let labels = try JSONDecoder().decode(Labels.self, from: labelData)
        let samples = try WAV.decodePCM16Mono(wav, expectedRate: AudioFrame.captureSampleRate)
        #expect(samples.count == labels.sampleCount, "\(name): sample count")
        return VADFixture(
            name: name,
            samples: samples,
            labels: labels.segments.map { Int64($0.start)..<Int64($0.end) }
        )
    }

    /// The recorded Silero probabilities for this fixture.
    func recordedProbabilities() throws -> RecordedProbabilities {
        let data = try Data(contentsOf: try Self.resource("\(name).silero.json"))
        return try JSONDecoder().decode(RecordedProbabilities.self, from: data)
    }

    /// The fixture as 20 ms capture frames starting at `offset`.
    func frames(startingAt offset: Int64 = 0, frameLength: Int = 320) -> [AudioFrame] {
        stride(from: 0, to: samples.count, by: frameLength).map { index in
            AudioFrame(
                samples: Array(samples[index..<min(index + frameLength, samples.count)]),
                sampleOffset: offset + Int64(index)
            )
        }
    }

    static func resource(_ file: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures/VAD"),
            "Missing fixture \(file)"
        )
    }

    /// Where the fixtures live in the source tree, for re-recording.
    static var sourceDirectory: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/VAD", directoryHint: .isDirectory)
    }

    private struct Labels: Decodable {
        struct Segment: Decodable {
            let start: Int
            let end: Int
        }
        let sampleRate: Int
        let sampleCount: Int
        let segments: [Segment]
    }
}

/// Silero's per-chunk speech probabilities over a fixture, recorded by
/// `SileroFixtureTests` with `BLAU_VAD_RECORD=1`.
struct RecordedProbabilities: Codable, Sendable {
    var model: String
    var chunkLength: Int
    var probabilities: [Float]
}

/// Replays recorded probabilities by chunk position, so the hermetic tests
/// see exactly what Silero said about the fixture.
actor ReplayedSpeechProbabilityModel: SpeechProbabilityModel {
    nonisolated let chunkLength: Int
    private let probabilities: [Float]
    private let streamStart: Int64
    private(set) var calls = 0

    init(_ recorded: RecordedProbabilities, streamStart: Int64 = 0) {
        chunkLength = recorded.chunkLength
        probabilities = recorded.probabilities
        self.streamStart = streamStart
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) throws -> Float {
        calls += 1
        let index = Int((sampleOffset - streamStart) / Int64(chunkLength))
        guard probabilities.indices.contains(index) else { throw ReplayError.noRecording(index) }
        return probabilities[index]
    }

    func reset() {}

    enum ReplayError: Error {
        case noRecording(Int)
    }
}

/// Records every probability a wrapped model returns, by chunk position.
actor RecordingSpeechProbabilityModel: SpeechProbabilityModel {
    nonisolated let chunkLength: Int
    private let base: any SpeechProbabilityModel
    private(set) var probabilities: [Float] = []

    init(_ base: any SpeechProbabilityModel) {
        self.base = base
        chunkLength = base.chunkLength
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) async throws -> Float {
        let probability = try await base.speechProbability(of: samples, at: sampleOffset)
        probabilities.append(probability)
        return probability
    }

    func reset() async {
        await base.reset()
    }
}

/// A model that returns scripted probabilities per chunk index (from the
/// first chunk it sees) and counts its calls.
actor ScriptedSpeechProbabilityModel: SpeechProbabilityModel {
    nonisolated let chunkLength: Int
    private let probability: @Sendable (Int) -> Float
    private var firstOffset: Int64?
    private(set) var calls = 0
    private(set) var resets = 0
    private var failingChunks: Set<Int>

    init(chunkLength: Int = 4_096, failing: Set<Int> = [], probability: @escaping @Sendable (Int) -> Float) {
        self.chunkLength = chunkLength
        self.probability = probability
        self.failingChunks = failing
    }

    /// Speech probability 0.95 in `speech` chunk ranges, 0.02 elsewhere.
    init(chunkLength: Int = 4_096, speechChunks: [Range<Int>]) {
        self.init(chunkLength: chunkLength) { index in
            speechChunks.contains { $0.contains(index) } ? 0.95 : 0.02
        }
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) throws -> Float {
        calls += 1
        let first = firstOffset ?? sampleOffset
        firstOffset = first
        let index = Int((sampleOffset - first) / Int64(chunkLength))
        if failingChunks.contains(index) {
            throw ScriptedError.failed
        }
        return probability(index)
    }

    func reset() {
        resets += 1
    }

    enum ScriptedError: Error {
        case failed
    }
}

/// Runs `samples` through a segmenter and collects what it reports.
struct SegmenterRun {
    var events: [VoiceActivityEvent] = []
    var audio: [SpeechAudioEvent] = []
    var statistics = VoiceActivityStatistics()

    var segments: [SpeechSegment] {
        events.compactMap { if case .speechEnded(let segment) = $0 { segment } else { nil } }
    }

    var onsets: [SpeechOnset] {
        events.compactMap { if case .speechStarted(let onset) = $0 { onset } else { nil } }
    }

    static func run(
        _ frames: [AudioFrame],
        model: any SpeechProbabilityModel,
        configuration: VoiceActivityConfiguration = .standard
    ) async -> SegmenterRun {
        let segmenter = VoiceActivitySegmenter(
            model: model, configuration: configuration, signposter: .disabled(.asr))
        let events = segmenter.events()
        let audio = segmenter.speechAudio()
        for frame in frames {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        var run = SegmenterRun()
        for await event in events { run.events.append(event) }
        for await event in audio { run.audio.append(event) }
        run.statistics = segmenter.statistics
        return run
    }
}

/// Room-tone noise (seeded, low-passed Gaussian) at `level` dBFS RMS.
func roomNoise(count: Int, levelDecibels: Float, seed: UInt64) -> [Float] {
    var generator = SplitMix64(seed: seed)
    var state: Float = 0
    var samples = [Float](repeating: 0, count: count)
    for index in 0..<count {
        // Box-Muller.
        let u1 = max(Float(generator.next() >> 40) / Float(1 << 24), 1e-7)
        let u2 = Float(generator.next() >> 40) / Float(1 << 24)
        let gaussian = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        state = 0.85 * state + gaussian
        samples[index] = state
    }
    let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
    let scale = pow(10, levelDecibels / 20) / rms
    return samples.map { $0 * scale }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum WAV {
    enum Failure: Error {
        case notWAV
        case unsupported(String)
    }

    /// Decodes a 16-bit PCM mono RIFF/WAVE file to floats in `-1..<1`.
    static func decodePCM16Mono(_ data: Data, expectedRate: Int) throws -> [Float] {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
            String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE"
        else { throw Failure.notWAV }
        var position = 12
        var format: (channels: Int, rate: Int, bits: Int)?
        while position + 8 <= bytes.count {
            let id = String(decoding: bytes[position..<position + 4], as: UTF8.self)
            let size = u32(position + 4)
            let body = position + 8
            if id == "fmt " {
                format = (u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                guard let format, format.channels == 1, format.bits == 16, format.rate == expectedRate else {
                    throw Failure.unsupported("\(String(describing: format))")
                }
                let count = min(size, bytes.count - body) / 2
                return (0..<count).map { index in
                    Float(Int16(bitPattern: UInt16(u16(body + index * 2)))) / 32_768
                }
            }
            position = body + size + (size & 1)
        }
        throw Failure.notWAV
    }
}
