import BlauAudio
import BlauCore
import Foundation

extension TranscriberRouter.EngineProvider {
    /// Parakeet realtime EOU (`ParakeetStreamingTranscriber`), available
    /// once its model is installed.
    ///
    /// - Parameters:
    ///   - models: The app's model manager.
    ///   - audio: The capture hub.
    ///   - voiceActivity: The Silero VAD segmenter running on the hub.
    ///   - inferenceObserver: `BackgroundInferenceMonitor`, told about every
    ///     model chunk.
    ///   - chunkSizePolicy: The thermal and power policy's chunk size (#75).
    ///   - recognizerProvider: Loads the other chunk size's export.
    ///   - built: Told about each transcriber built, for the HUD's counters.
    public static func parakeet(
        models: ModelManager,
        audio: any CaptureFrameSource,
        voiceActivity: any VoiceActivitySource,
        configuration: StreamingTranscriberConfiguration = .standard,
        inferenceObserver: (any InferenceObserver)? = nil,
        chunkSizePolicy: (any ASRChunkSizePolicy)? = nil,
        recognizerProvider: RecognizerProvider? = nil,
        built: (@Sendable (ParakeetStreamingTranscriber) -> Void)? = nil
    ) -> Self {
        Self(
            isAvailable: { await models.directory(for: .parakeetRealtimeEOU) != nil },
            make: {
                guard let directory = await models.directory(for: .parakeetRealtimeEOU) else {
                    throw TranscriberRouterError.noEngineAvailable
                }
                let transcriber = try await ParakeetStreamingTranscriber.load(
                    modelDirectory: directory, audio: audio, voiceActivity: voiceActivity,
                    configuration: configuration, chunkSizePolicy: chunkSizePolicy,
                    recognizerProvider: recognizerProvider, inferenceObserver: inferenceObserver)
                built?(transcriber)
                return transcriber
            }
        )
    }

    /// Apple's `SpeechAnalyzer` (`AppleTranscriber`), available when the
    /// device and `locale` are supported. Building it installs the
    /// language's model if the system hasn't yet (`AppleSpeechAssets`).
    ///
    /// - Parameters:
    ///   - audio: The capture hub.
    ///   - voiceActivity: The Silero VAD segmenter when its model is
    ///     installed; `nil` otherwise.
    ///   - vocabulary: Names to bias recognition toward (memory's
    ///     entities).
    ///   - locale: The user's language.
    ///   - allowsDownload: Whether building may download the language's
    ///     model.
    public static func apple(
        audio: any CaptureFrameSource,
        voiceActivity: (any VoiceActivitySource)? = nil,
        vocabulary: (any RecognitionVocabularySource)? = nil,
        locale: Locale = .current,
        allowsDownload: Bool = true,
        configuration: AppleTranscriberConfiguration = .standard
    ) -> Self {
        Self(
            isAvailable: { await AppleSpeechAssets.availability(for: locale).isSupported },
            make: {
                let resolved = try await AppleSpeechAssets.prepare(for: locale, allowsDownload: allowsDownload)
                #if canImport(Speech)
                    return AppleTranscriber(
                        engine: SystemSpeechAnalyzerEngine(locale: resolved), audio: audio,
                        voiceActivity: voiceActivity, vocabulary: vocabulary, configuration: configuration)
                #else
                    throw AppleSpeechError.unsupportedDevice
                #endif
            }
        )
    }
}
