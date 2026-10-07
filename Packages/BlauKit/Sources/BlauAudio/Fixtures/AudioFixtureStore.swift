import Foundation

/// Produces a benchmark's audio once and hands the same clip to every case
/// that asks, so a suite run synthesizes (or reads) its speech only once.
public actor AudioFixtureStore {
    private let loader: @Sendable () async throws -> AudioFixture
    private var cached: AudioFixture?

    public init(loader: @escaping @Sendable () async throws -> AudioFixture) {
        self.loader = loader
    }

    /// A store that always returns `fixture`.
    public init(fixture: AudioFixture) {
        self.init { fixture }
    }

    /// The clip, loading it on first use. A failed load is retried on the
    /// next call.
    public func fixture() async throws -> AudioFixture {
        if let cached { return cached }
        let fixture = try await loader()
        cached = fixture
        return fixture
    }

    /// The default benchmark audio, best source first:
    ///
    /// 1. the recording at `recordingURL`, if the file exists;
    /// 2. `AudioFixture.benchmarkPassage` rendered by the speech synthesizer;
    /// 3. the deterministic synthetic signal, if synthesis is unavailable.
    ///
    /// The result's `source` records which one was used.
    public static func standard(recordingURL: URL? = nil) -> AudioFixtureStore {
        AudioFixtureStore {
            if let recordingURL, FileManager.default.fileExists(atPath: recordingURL.path) {
                let recording = try AudioFixture.load(contentsOf: recordingURL)
                if !recording.samples.isEmpty { return recording }
            }
            do {
                return try await AudioFixture.synthesizedSpeech()
            } catch {
                let fallback = AudioFixture.syntheticSignal(duration: .seconds(60))
                return AudioFixture(
                    samples: fallback.samples,
                    source: "\(fallback.source); speech synthesis failed: \(error)"
                )
            }
        }
    }
}
