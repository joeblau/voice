import BlauCore
import BlauTelemetry
import FluidAudio
import Foundation
import Testing

@testable import BlauTranscription

/// Checks `ParakeetEouRecognizer`'s assumptions against the resolved
/// FluidAudio source, without loading the model (`ParakeetLiveTests` runs
/// the model itself).
@Suite("Parakeet EOU recognizer")
struct ParakeetEouRecognizerTests {
    /// The recognizer feeds FluidAudio exactly one chunk per call by
    /// mirroring its buffer arithmetic, so the geometry must match.
    @Test(arguments: ASRChunkSize.allCases)
    func chunkGeometryMatchesFluidAudio(_ size: ASRChunkSize) {
        let fluid = size.fluidAudio
        #expect(size.windowSamples == fluid.chunkSamples)
        #expect(size.shiftSamples == fluid.shiftSamples)
        #expect(size.outputFrames == fluid.validOutputLen)
        #expect(size.rawValue == "ms" + fluid.modelSubdirectory.replacingOccurrences(of: "ms", with: ""))
    }

    @Test func the320MillisecondExportIsTheInstalledModel() throws {
        // `ModelID.parakeetRealtimeEOU` pins FluidAudio's 320 ms repository.
        let upstream = try #require(FluidAudioModels.upstream(for: .parakeetRealtimeEOU))
        #expect(upstream.directory == ASRChunkSize.ms320.fluidAudio.modelSubdirectory)
        #expect(ASRChunkSize.ms320.shift == .milliseconds(320))
        #expect(ASRChunkSize.ms320.window == .milliseconds(630))
        #expect(ASRChunkSize.ms320.frameSamples == 1_280)
    }

    @Test func loadingFromADirectoryWithoutTheModelThrows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "blau-no-parakeet-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: (any Error).self) {
            _ = try await ParakeetEouRecognizer.load(modelDirectory: directory, signposter: .disabled(.asr))
        }
    }

    /// The flush rebuilds the text from FluidAudio's raw pieces (as
    /// `getRawTokenStrings()` returns them) the way its `Tokenizer.decode`
    /// does, keeping the tokens up to the cutoff.
    @Test func theFlushKeepsTheTokensUpToTheCutoff() {
        let pieces = ["\u{2581}I", "\u{2581}would", "\u{2581}li", "ke", "<id:1025>", "\u{2581}a", "\u{2581}cof", "fee"]
        let timestamps = [80, 320, 640, 720, 800, 1_520, 1_680, 1_760]

        let all = ParakeetEouRecognizer.transcript(pieces: pieces, timestampsMs: timestamps, throughMilliseconds: nil)
        #expect(all.text == "I would like a coffee")
        #expect(all.lastTimestampMs == 1_760)

        // A cutoff between the words: the word split over two pieces stays
        // whole, and an unknown id is skipped as `decode` skips it.
        let cut = ParakeetEouRecognizer.transcript(pieces: pieces, timestampsMs: timestamps, throughMilliseconds: 800)
        #expect(cut.text == "I would like")
        #expect(cut.lastTimestampMs == 800)

        let none = ParakeetEouRecognizer.transcript(pieces: pieces, timestampsMs: timestamps, throughMilliseconds: 40)
        #expect(none.text.isEmpty)
        #expect(none.lastTimestampMs == nil)
    }

    /// The simulated recognizer's flush follows the same rules, so the
    /// transcriber tests exercise them: it decodes the whole buffer one
    /// padded chunk (one output span) at a time, or only up to the cutoff.
    @Test func theSimulatedFlushDecodesTheBufferedAudioUpToTheCutoff() async throws {
        let words = [
            ScriptedWord(text: "one", end: 3_000, endsUtterance: false),
            ScriptedWord(text: "two", end: 7_000, endsUtterance: false),
            ScriptedWord(text: "three", end: 9_500, endsUtterance: false),
        ]
        // 9 600 samples: less than a window, so nothing ran yet, and more
        // than one shift, which FluidAudio's own `finish()` would truncate.
        let audio = AudioFrame(samples: [Float](repeating: 0, count: 9_600), sampleOffset: 0)

        let whole = SimulatedEouRecognizer(words: words)
        _ = try await whole.append(audio)
        let all = await whole.finish(keepingTokensThrough: nil)
        #expect(all.transcript == "one two three")
        #expect(all.chunks == 2)
        #expect(all.decodedSamples == 9_600)

        let cut = SimulatedEouRecognizer(words: words)
        _ = try await cut.append(audio)
        let first = await cut.finish(keepingTokensThrough: 4_000)
        #expect(first.transcript == "one")
        #expect(first.chunks == 1)
        #expect(first.lastTokenEnd == 3_000)
    }

    @Test func theDefaultDebounceIsTwoChunks() {
        #expect(ParakeetEouRecognizer.defaultEndOfUtteranceDebounce == ASRChunkSize.ms320.shift * 2)
    }
}
