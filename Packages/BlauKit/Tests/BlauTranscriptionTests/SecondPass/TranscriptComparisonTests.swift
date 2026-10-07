import FluidAudio
import Foundation
import Testing

@testable import BlauTranscription

@Suite("Second-pass transcript comparison")
struct TranscriptComparisonTests {
    @Test func wordsIgnoreCaseAndPunctuation() {
        #expect(TranscriptComparison.words("Uh-huh, let's go!") == ["uh", "huh", "let's", "go"])
        #expect(TranscriptComparison.words("  ") == [])
        #expect(TranscriptComparison.words("March 2nd.") == ["march", "2nd"])
    }

    @Test func punctuationAndCapitalizationAreNoChange() {
        #expect(
            TranscriptComparison.changeRatio(
                from: "can you remind me what we decided", to: "Can you remind me what we decided?") == 0)
    }

    @Test func changeIsTheWordEditDistanceOverTheStreamingWords() {
        // One substitution in five words.
        #expect(TranscriptComparison.changeRatio(from: "we moved it to march", to: "We moved it to May.") == 0.2)
        // One insertion.
        #expect(TranscriptComparison.changeRatio(from: "okay great", to: "Okay, that's great.") == 0.5)
        // One deletion.
        #expect(TranscriptComparison.changeRatio(from: "so so the plan", to: "So the plan.") == 0.25)
        #expect(TranscriptComparison.changeRatio(from: "a b c", to: "x y z") == 1)
    }

    @Test func emptyTranscripts() {
        #expect(TranscriptComparison.changeRatio(from: "", to: "") == 0)
        #expect(TranscriptComparison.changeRatio(from: "", to: "Hello.") == 1)
        #expect(TranscriptComparison.changeRatio(from: "hello", to: "") == 1)
    }

    @Test func normalizedCollapsesWhitespace() {
        #expect(TranscriptComparison.normalized("  Take \n your   time. ") == "Take your time.")
    }
}

@Suite("Parakeet TDT recognizer")
struct ParakeetTdtRecognizerTests {
    @Test func theMinimumMatchesFluidAudiosGuard() {
        #expect(ParakeetTdtRecognizer.minimumSamples == ASRConstants.minimumRequiredSamples(forSampleRate: 16_000))
        #expect(ParakeetTdtRecognizer.minimumSamples == 4_800)
    }

    @Test func loadingFromADirectoryWithoutTheModelThrows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "blau-tdt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            _ = try await ParakeetTdtRecognizer.load(modelDirectory: directory)
        }
    }

    @Test func theInstalledModelHasTheFilesTheRecognizerLoads() {
        let required = FluidAudioModels.requiredEntries(for: .parakeetTDTv3)
        #expect(required.contains(ModelNames.ASR.vocabularyFile))
        #expect(required.contains(ModelNames.ASR.preprocessorFile))
    }
}
