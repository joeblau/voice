import BlauCore
import Foundation
import Testing

@testable import BlauTranscription

/// The bundled ASR fixtures (`Fixtures/ASR`, made by
/// `scripts/make-asr-fixtures.py`). The WAVs are in Git LFS: without
/// `git lfs pull` they are pointer files, and the tests that need the audio
/// are skipped.
enum ASRFixtures {
    static func manifestURL() throws -> URL {
        try #require(
            Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/ASR"),
            "Missing Fixtures/ASR/manifest.json")
    }

    static var audioIsAvailable: Bool {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/ASR")
        else { return false }
        return ASREvaluationDataset.audioIsAvailable(manifest: url)
    }

    /// The repository root, from this file's location.
    static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

// MARK: - Synthetic fixtures

/// A fixture of room tone at -60 dBFS with a -24 dBFS tone burst where each
/// utterance is "spoken", so a level-based VAD finds exactly the labelled
/// speech.
func syntheticFixture(
    id: String = "synthetic", category: String = "clean", seconds: Double,
    utterances: [(text: String, from: Double, to: Double)]
) -> ASREvaluationFixture {
    var samples = roomNoise(count: Int(seconds * 16_000), levelDecibels: -60, seed: 11)
    var references: [ASRReferenceUtterance] = []
    for utterance in utterances {
        let start = Int(utterance.from * 16_000)
        let end = Int(utterance.to * 16_000)
        for index in start..<end {
            // About -24 dBFS RMS.
            samples[index] += 0.09 * Float(sin(Double(index) * 2 * .pi * 220 / 16_000))
        }
        references.append(ASRReferenceUtterance(range: Int64(start)..<Int64(end), text: utterance.text))
    }
    return ASREvaluationFixture(id: id, category: category, samples: samples, utterances: references)
}

/// The words of each reference utterance spread evenly over its speech, the
/// last one ending the utterance: the alignment `SimulatedEouRecognizer`
/// "recognizes".
func scriptedWords(for fixture: ASREvaluationFixture) -> [ScriptedWord] {
    fixture.utterances.flatMap { utterance -> [ScriptedWord] in
        let tokens = utterance.text.split(separator: " ").map(String.init)
        let length = utterance.range.upperBound - utterance.range.lowerBound
        return tokens.enumerated().map { index, token in
            ScriptedWord(
                text: token, end: utterance.range.lowerBound + length * Int64(index + 1) / Int64(tokens.count),
                endsUtterance: index == tokens.count - 1)
        }
    }
}

/// A streaming engine over the simulated recognizer (Parakeet's chunk
/// timing, transcribing from the labels) and a level-based VAD: the whole
/// streaming path without Core ML.
func simulatedStreamingEngine(id: String = "simulated-eou") -> StreamingASREvaluationEngine {
    StreamingASREvaluationEngine(
        descriptor: ASREngineDescriptor(id: id, title: "Simulated EOU recognizer", kind: .streaming),
        recognizer: { fixture in SimulatedEouRecognizer(words: scriptedWords(for: fixture)) },
        speechModel: LevelSpeechProbabilityModel())
}

/// Speech when a chunk is louder than -40 dBFS RMS. Stateless, so one
/// instance serves every fixture.
struct LevelSpeechProbabilityModel: SpeechProbabilityModel {
    let chunkLength = 4_096

    func speechProbability(of samples: [Float], at sampleOffset: Int64) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-9)) > -40 ? 0.95 : 0.02
    }

    func reset() {}
}

/// An engine that returns prepared transcripts, for testing the evaluator.
struct PreparedEngine: ASREvaluationEngine {
    let descriptor: ASREngineDescriptor
    let transcripts: [String: ASREngineTranscript]

    init(
        id: String = "prepared", kind: ASREngineDescriptor.Kind = .streaming,
        _ transcripts: [String: ASREngineTranscript]
    ) {
        descriptor = ASREngineDescriptor(id: id, title: "Prepared \(id)", kind: kind)
        self.transcripts = transcripts
    }

    func transcribe(_ fixture: ASREvaluationFixture) throws -> ASREngineTranscript {
        guard let transcript = transcripts[fixture.id] else { throw PreparedEngineError.noTranscript(fixture.id) }
        return transcript
    }

    enum PreparedEngineError: Error {
        case noTranscript(String)
    }
}

// MARK: - Files

/// A 16-bit PCM mono WAV file's bytes.
func wavData(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
    var data = Data()
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let payload = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + payload)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(payload)
    for sample in samples {
        let value = Int16(max(-1, min(1, sample)) * 32_767)
        append16(UInt16(bitPattern: value))
    }
    return data
}

/// A temporary directory, removed when the value is deinitialized.
final class ASRTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "blau-asr-eval-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ data: Data, to path: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func writeManifest(_ manifest: ASREvaluationManifest, name: String = "manifest.json") throws -> URL {
        let file = url.appending(path: name)
        try JSONEncoder().encode(manifest).write(to: file)
        return file
    }
}
