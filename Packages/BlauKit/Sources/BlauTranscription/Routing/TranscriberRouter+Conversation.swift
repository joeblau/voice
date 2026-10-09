import BlauCore
import BlauTelemetry
import Foundation

extension TranscriberRouter {
    /// The speech-to-text of one conversation as the app runs it (#31):
    /// a router over `parakeet` and `apple` that
    ///
    /// - starts on the engine the Settings toggle (and the chosen language)
    ///   asks for, and follows `settings.preferenceChanges()`, so flipping
    ///   "Use Apple Speech Recognition" mid-conversation switches engines
    ///   at the next utterance boundary;
    /// - follows `memoryPressure`, moving to Apple's engine at `critical`;
    /// - is registered with `backgroundInference` as the `"asr"` stage, so
    ///   the monitor can hand speech-to-text to Apple's engine off screen.
    ///
    /// Not started yet. When the conversation ends, `finish()` it and
    /// unregister ``inferenceStage`` from the monitor.
    ///
    /// - Parameters:
    ///   - budget: The time one inference may take, for the monitor.
    @MainActor
    public static func conversation(
        parakeet: EngineProvider,
        apple: EngineProvider,
        settings: TranscriptionSettings,
        memoryPressure: AsyncStream<MemoryPressureLevel>,
        backgroundInference: BackgroundInferenceMonitor?,
        budget: Duration = .milliseconds(320),
        configuration: Configuration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.asr
    ) async -> TranscriberRouter {
        let router = TranscriberRouter(
            parakeet: parakeet, apple: apple, preference: settings.effectiveEnginePreference,
            configuration: configuration, clock: clock, signposter: signposter)
        await router.followPreferences(settings.preferenceChanges())
        await router.followMemoryPressure(memoryPressure)
        await backgroundInference?.register(router, budget: budget)
        return router
    }
}
