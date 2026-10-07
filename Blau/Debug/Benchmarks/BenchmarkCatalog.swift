#if DEBUG || BLAU_BENCHMARKS
    import BlauAudio
    import BlauMemory
    import BlauTelemetry
    import BlauTopics
    import BlauTranscription
    import BlauVoiceID
    import Foundation

    /// The on-device benchmark suite (#22), composed from the cases each
    /// BlauKit module defines. Only compiled into Debug builds (or builds with
    /// the `BLAU_BENCHMARKS` condition); see docs/benchmarks.md.
    enum BenchmarkCatalog {
        /// `Documents/Benchmarks`: drop an optional `benchmark-speech.wav`
        /// recording and `Models/EmbeddingGemma*.mlmodelc` here (for example
        /// with `xcrun devicectl device copy to`); reports are written to
        /// `Reports/`.
        static var directory: URL {
            URL.documentsDirectory.appendingPathComponent("Benchmarks", isDirectory: true)
        }

        static var modelsDirectory: URL { directory.appendingPathComponent("Models", isDirectory: true) }
        static var reportsDirectory: URL { directory.appendingPathComponent("Reports", isDirectory: true) }
        static var recordingURL: URL { directory.appendingPathComponent("benchmark-speech.wav") }

        /// The benchmark audio: the recording if present, else synthesized
        /// speech.
        static func audioStore() -> AudioFixtureStore {
            AudioFixtureStore.standard(recordingURL: recordingURL)
        }

        /// Every case, in the order the screen lists and runs them.
        static func cases(audio: AudioFixtureStore) -> [any BenchmarkCase] {
            ParakeetEouChunkSize.allCases.map { StreamingAsrBenchmark.parakeetEou($0, audio: audio) } + [
                OfflineAsrBenchmark.parakeetTdtV3(audio: audio),
                SpeakerEmbeddingBenchmark.weSpeaker(audio: audio),
                SpeakerEmbeddingBenchmark.camPlusPlus(audio: audio),
                TextEmbeddingBenchmark.embeddingGemma(searching: [modelsDirectory, directory]),
                TopicLabelBenchmark(generator: FoundationModelsLabelBenchmarkGenerator()),
            ]
        }

        /// Recorded in every report: Debug builds run Swift code (BlauKit,
        /// FluidAudio's decoders) unoptimized, so their numbers stay out of
        /// the results table.
        static var buildConfiguration: String {
            #if DEBUG
                "Debug"
            #else
                "Release"
            #endif
        }

        /// Writes `data` to `Reports/<name>` and returns its URL.
        static func save(_ data: Data, named name: String) throws -> URL {
            try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
            let url = reportsDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }
    }
#endif
