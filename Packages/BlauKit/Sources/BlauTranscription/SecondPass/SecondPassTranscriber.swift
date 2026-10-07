import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Adds the second pass (#30) to a streaming transcriber: every final
/// utterance is passed on **at once**, then re-transcribed with Parakeet TDT
/// v3 from the capture history in the background, and its punctuated,
/// capitalized text follows as a `.refined` event with the same `id`.
///
/// ```swift
/// let transcriber = SecondPassTranscriber(
///     wrapping: streaming,                       // ParakeetStreamingTranscriber
///     audio: capture.hub,                        // the same 16 kHz history
///     recognizer: ParakeetTdtRecognizer.provider(modelManager: modelManager),
///     flags: flags)                              // FeatureFlag.secondPassASR
/// for await event in transcriber.events {
///     switch event {
///     case .partial(let text, _): ...            // as before
///     case .final(let utterance): ...            // send to Grok now, store, show
///     case .refined(let utterance): ...          // replace the stored and shown text
///     }
/// }
/// ```
///
/// **Turn latency is unchanged.** `.partial` and `.final` events are
/// forwarded before anything else happens; the second pass only copies the
/// utterance's audio out of the history (a memcpy) after the final is out,
/// and transcribes it on a separate, lower-priority task. Grok gets the
/// streaming text; the refined text only replaces what is stored and shown.
///
/// **Skipped** (the utterance keeps its streaming text, see
/// `SecondPassSkipReason`) when the `secondPassASR` flag is off, the device
/// is at `.serious` thermal state or hotter, Parakeet TDT v3 isn't
/// installed, the audio has left the history, more than
/// `maximumPendingUtterances` are waiting, or the second pass returns
/// nothing or something too different (a misfire).
///
/// The recognizer is loaded on first use and kept. `events` finishes once
/// the wrapped transcriber's events have finished and the waiting
/// utterances are done.
public final class SecondPassTranscriber: Transcriber {
    public let events: AsyncStream<TranscriptEvent>
    /// The streaming transcriber whose finals are refined.
    public let base: any Transcriber
    public let configuration: SecondPassConfiguration

    private let engine: Engine
    private let forwarder: Task<Void, Never>
    private let worker: Task<Void, Never>

    /// - Parameters:
    ///   - base: The streaming transcriber.
    ///   - audio: The capture stream `base` transcribes, for its history.
    ///   - recognizer: Supplies the second-pass recognizer once its model is
    ///     installed.
    ///   - isEnabled: Read for every utterance: the `secondPassASR` flag.
    ///   - thermalState: Reads the device's thermal state; tests pass a fake.
    ///   - configuration: Padding, backlog and acceptance limits.
    ///   - signposter: Where `asr.secondPass` intervals go.
    public init(
        wrapping base: any Transcriber,
        audio: any CaptureFrameSource,
        recognizer: @escaping SecondPassRecognizerProvider,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        configuration: SecondPassConfiguration = .standard,
        signposter: Signposter = Signposts.asr
    ) {
        self.base = base
        self.configuration = configuration
        let engine = Engine(
            audio: audio, provider: recognizer, isEnabled: isEnabled, thermalState: thermalState,
            configuration: configuration, signposter: signposter)
        self.engine = engine

        let (events, output) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        let (jobs, queue) = AsyncStream.makeStream(
            of: Job.self, bufferingPolicy: .bufferingNewest(configuration.maximumPendingUtterances))

        let baseEvents = base.events
        forwarder = Task {
            for await event in baseEvents {
                // Downstream (Grok, the store, the view) gets the event first.
                output.yield(event)
                guard case .final(let utterance) = event, let job = engine.prepare(utterance) else { continue }
                if case .dropped(let oldest) = queue.yield(job) {
                    engine.skip(oldest.utterance, .backlog)
                }
            }
            queue.finish()
        }
        worker = Task(priority: .utility) {
            var recognizer = RecognizerSlot()
            for await job in jobs {
                guard !Task.isCancelled else { break }
                if let refined = await engine.run(job, recognizer: &recognizer) {
                    output.yield(.refined(refined))
                }
            }
            output.finish()
        }
    }

    /// Reads `FeatureFlag.secondPassASR` from `flags` for every utterance.
    public convenience init(
        wrapping base: any Transcriber,
        audio: any CaptureFrameSource,
        recognizer: @escaping SecondPassRecognizerProvider,
        flags: FeatureFlags,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        configuration: SecondPassConfiguration = .standard,
        signposter: Signposter = Signposts.asr
    ) {
        self.init(
            wrapping: base, audio: audio, recognizer: recognizer, isEnabled: { flags.isEnabled(.secondPassASR) },
            thermalState: thermalState, configuration: configuration, signposter: signposter)
    }

    deinit {
        forwarder.cancel()
        worker.cancel()
    }

    /// A snapshot of the counters.
    public var statistics: SecondPassStatistics { engine.statistics }

    // MARK: Transcriber

    public func start() async throws {
        try await base.start()
    }

    /// Stops the streaming transcriber. Utterances already committed are
    /// still refined.
    public func stop() async {
        await base.stop()
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        await base.appPhaseDidChange(transition)
    }

    /// Waits until every utterance committed so far has been refined or
    /// skipped and `events` has finished. Only returns once the wrapped
    /// transcriber's events have finished.
    public func waitUntilFinished() async {
        await forwarder.value
        await worker.value
    }
}

// MARK: - Engine

extension SecondPassTranscriber {
    /// One utterance waiting for the second pass, with its audio.
    struct Job: Sendable {
        let utterance: Utterance
        let samples: [Float]
    }

    /// The loaded recognizer, owned by the worker task.
    struct RecognizerSlot {
        var recognizer: (any SecondPassRecognizer)?
        /// Utterances to skip before trying to load again after a failure.
        var retryCountdown = 0
    }

    /// The policy and bookkeeping, shared by the forwarding and worker
    /// tasks. Its state is behind a mutex; the recognizer lives in the
    /// worker.
    final class Engine: Sendable {
        let audio: any CaptureFrameSource
        let provider: SecondPassRecognizerProvider
        let isEnabled: @Sendable () -> Bool
        let thermalState: @Sendable () -> ProcessInfo.ThermalState
        let configuration: SecondPassConfiguration
        let signposter: Signposter
        private let logger = Log.asr
        private let state = Mutex(State())

        private struct State {
            var statistics = SecondPassStatistics()
            /// End of the previous utterance's speech: the leading padding
            /// never reaches before it.
            var previousEnd: Int64 = 0
        }

        init(
            audio: any CaptureFrameSource,
            provider: @escaping SecondPassRecognizerProvider,
            isEnabled: @escaping @Sendable () -> Bool,
            thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState,
            configuration: SecondPassConfiguration,
            signposter: Signposter
        ) {
            self.audio = audio
            self.provider = provider
            self.isEnabled = isEnabled
            self.thermalState = thermalState
            self.configuration = configuration
            self.signposter = signposter
        }

        var statistics: SecondPassStatistics { state.withLock { $0.statistics } }

        /// Decides whether `utterance` gets a second pass and, if so, copies
        /// its audio out of the history now, before it scrolls out. Runs
        /// right after the final was forwarded.
        func prepare(_ utterance: Utterance) -> Job? {
            let rate = AudioFrame.captureSampleRate
            let start = utterance.timeRange.start.sampleCount(sampleRate: rate)
            let end = utterance.timeRange.end.sampleCount(sampleRate: rate)
            let previousEnd = state.withLock { state in
                state.statistics.utterancesSubmitted += 1
                defer { state.previousEnd = max(state.previousEnd, end) }
                return state.previousEnd
            }
            if let reason = policySkipReason() {
                skip(utterance, reason)
                return nil
            }
            let lower = max(start - configuration.leadingPaddingSamples, min(previousEnd, start), 0)
            let upper = max(end + configuration.trailingPaddingSamples, lower + 1)
            guard let frame = audio.history(in: lower..<upper), frame.sampleOffset <= start, !frame.isEmpty else {
                skip(utterance, .audioUnavailable)
                return nil
            }
            return Job(utterance: utterance, samples: frame.samples)
        }

        /// Transcribes `job` and returns the refined utterance, or `nil` when
        /// it keeps its streaming text.
        func run(_ job: Job, recognizer slot: inout RecognizerSlot) async -> Utterance? {
            let utterance = job.utterance
            // The flag or the temperature may have changed while it waited.
            if let reason = policySkipReason() {
                skip(utterance, reason)
                return nil
            }
            guard let recognizer = await loadedRecognizer(&slot) else {
                skip(utterance, .modelUnavailable)
                return nil
            }

            let interval = signposter.beginInterval(.asrSecondPass)
            let clock = ContinuousClock()
            let started = clock.now
            let transcript: SecondPassTranscript
            do {
                transcript = try await recognizer.transcribe(job.samples)
            } catch {
                record(job, time: clock.now - started)
                interval.end(message: SecondPassSkipReason.failed.rawValue)
                logger.error(
                    "Second pass failed for utterance \(utterance.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                skip(utterance, .failed)
                return nil
            }
            let elapsed = clock.now - started
            record(job, time: elapsed)

            let text = TranscriptComparison.normalized(transcript.text)
            let outcome = evaluate(text, against: utterance.text)
            interval.end(message: outcome.message)
            switch outcome {
            case .skip(let reason):
                skip(utterance, reason)
                if reason == .diverged {
                    logger.notice(
                        """
                        Second pass rejected for utterance \(utterance.id, privacy: .public) (too different): \
                        \(utterance.text, privacy: .private) → \(text, privacy: .private)
                        """
                    )
                }
                return nil
            case .unchanged:
                state.withLock { $0.statistics.utterancesUnchanged += 1 }
                return nil
            case .refined:
                state.withLock { $0.statistics.utterancesRefined += 1 }
                logger.info(
                    """
                    Second pass refined utterance \(utterance.id, privacy: .public) in \
                    \(elapsed.timeInterval * 1_000, format: .fixed(precision: 0), privacy: .public) ms: \
                    \(text, privacy: .private)
                    """
                )
                var refined = utterance
                refined.text = text
                return refined
            }
        }

        func skip(_ utterance: Utterance, _ reason: SecondPassSkipReason) {
            state.withLock { $0.statistics.skipped[reason, default: 0] += 1 }
            logger.debug(
                "Second pass skipped utterance \(utterance.id, privacy: .public): \(reason.rawValue, privacy: .public)")
        }

        // MARK: Helpers

        private enum Outcome {
            case refined
            case unchanged
            case skip(SecondPassSkipReason)

            var message: String {
                switch self {
                case .refined: "refined"
                case .unchanged: "unchanged"
                case .skip(let reason): reason.rawValue
                }
            }
        }

        private func evaluate(_ text: String, against streaming: String) -> Outcome {
            if text.isEmpty { return .skip(.blank) }
            if text == streaming { return .unchanged }
            let streamingWords = TranscriptComparison.words(streaming).count
            if streamingWords >= configuration.minimumWordsForChangeCheck,
                TranscriptComparison.changeRatio(from: streaming, to: text) > configuration.maximumWordChangeRatio
            {
                return .skip(.diverged)
            }
            return .refined
        }

        private func policySkipReason() -> SecondPassSkipReason? {
            guard isEnabled() else { return .disabled }
            if thermalState().rawValue >= configuration.skipThermalState.rawValue { return .thermalPressure }
            return nil
        }

        private func loadedRecognizer(_ slot: inout RecognizerSlot) async -> (any SecondPassRecognizer)? {
            if let recognizer = slot.recognizer { return recognizer }
            guard slot.retryCountdown == 0 else {
                slot.retryCountdown -= 1
                return nil
            }
            state.withLock { $0.statistics.recognizerLoads += 1 }
            do {
                let clock = ContinuousClock()
                let started = clock.now
                guard let recognizer = try await provider() else { return nil }
                slot.recognizer = recognizer
                logger.notice(
                    "Second pass recognizer loaded in \((clock.now - started).timeInterval, format: .fixed(precision: 2), privacy: .public) s"
                )
                return recognizer
            } catch {
                slot.retryCountdown = configuration.loadRetryInterval
                logger.error(
                    "Second pass recognizer failed to load: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        private func record(_ job: Job, time: Duration) {
            state.withLock { state in
                state.statistics.recognitions += 1
                state.statistics.samplesTranscribed += Int64(job.samples.count)
                state.statistics.modelTime += time
                state.statistics.slowestUtterance = max(state.statistics.slowestUtterance, time)
            }
        }
    }
}
