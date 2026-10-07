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

    @Test func the320MillisecondExportIsTheInstalledModel() {
        // `ModelID.parakeetRealtimeEOU` pins FluidAudio's 320 ms repository.
        let upstream = FluidAudioModels.upstream(for: .parakeetRealtimeEOU)
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

    @Test func theDefaultDebounceIsTwoChunks() {
        #expect(ParakeetEouRecognizer.defaultEndOfUtteranceDebounce == ASRChunkSize.ms320.shift * 2)
    }
}
