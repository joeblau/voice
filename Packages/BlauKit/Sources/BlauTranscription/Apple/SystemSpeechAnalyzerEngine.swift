#if canImport(Speech)
    import AVFAudio
    import BlauCore
    import BlauTelemetry
    import CoreMedia
    import Foundation
    import Speech
    import os

    /// `SpeechAnalyzerEngine` over Apple's `SpeechAnalyzer` with a
    /// `SpeechTranscriber` (and a `SpeechDetector`, so audio without speech
    /// isn't transcribed), entirely on device.
    ///
    /// Prepare the language's model first with `AppleSpeechAssets.prepare`,
    /// which returns the locale to pass here. Each `start` creates a new
    /// analyzer (a finished one can't be restarted); the model stays loaded
    /// between sessions (`modelRetention: .lingering`), so a restart is
    /// quick.
    ///
    /// The transcriber runs with `timeIndexedProgressiveTranscription`:
    /// volatile results as the audio arrives (`volatileResults`,
    /// `fastResults`), and a time range for every finalized word
    /// (`audioTimeRange`), which `AppleTranscriber` uses to find pauses and
    /// to keep a committed word out of the next utterance.
    public actor SystemSpeechAnalyzerEngine: SpeechAnalyzerEngine {
        /// The transcriber's settings.
        static let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription

        /// How long `finish()` waits for the last results after the analyzer
        /// finished, before ending the results stream anyway.
        static let resultsDrainTimeout: Duration = .seconds(2)

        public nonisolated let locale: Locale
        private let usesSpeechDetector: Bool
        private let priority: TaskPriority
        private var session: Session?

        /// One analysis session.
        private struct Session {
            let analyzer: SpeechAnalyzer
            let input: AsyncStream<AnalyzerInput>.Continuation
            let results: AsyncThrowingStream<SpeechAnalyzerResult, any Error>.Continuation
            let forwarding: Task<Void, Never>
            let converter: AnalyzerAudioConverter
        }

        /// - Parameters:
        ///   - locale: From `AppleSpeechAssets.prepare(for:)`.
        ///   - usesSpeechDetector: Adds a `SpeechDetector` so silence and
        ///     noise aren't transcribed (saves power on long sessions).
        ///   - priority: The analyzer's task priority.
        public init(locale: Locale, usesSpeechDetector: Bool = true, priority: TaskPriority = .userInitiated) {
            self.locale = locale
            self.usesSpeechDetector = usesSpeechDetector
            self.priority = priority
        }

        public func start(contextualStrings: [String]) async throws -> AsyncThrowingStream<
            SpeechAnalyzerResult, any Error
        > {
            if session != nil {
                await cancel()
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: Self.preset)
            var modules: [any SpeechModule] = [transcriber]
            if usesSpeechDetector {
                modules.insert(
                    SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false), at: 0)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw AppleSpeechError.noCompatibleAudioFormat
            }
            let converter = try AnalyzerAudioConverter(outputFormat: format)
            let analyzer = SpeechAnalyzer(
                modules: modules, options: .init(priority: priority, modelRetention: .lingering))
            if !contextualStrings.isEmpty {
                try await analyzer.setContext(Self.context(contextualStrings))
            }
            try await analyzer.prepareToAnalyze(in: format)

            let (inputs, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: inputs)

            let (stream, results) = AsyncThrowingStream.makeStream(of: SpeechAnalyzerResult.self)
            let forwarding = Task {
                do {
                    for try await result in transcriber.results {
                        results.yield(Self.convert(result))
                    }
                    results.finish()
                } catch {
                    results.finish(throwing: error)
                }
            }
            session = Session(
                analyzer: analyzer, input: input, results: results, forwarding: forwarding, converter: converter)
            Log.asr.notice(
                "Apple speech analyzer started: \(self.locale.identifier, privacy: .public), \(format.description, privacy: .public)"
            )
            return stream
        }

        public func append(_ frame: AudioFrame) async throws {
            guard let session else { throw AppleSpeechError.notStarted }
            let buffer = try session.converter.buffer(for: frame)
            session.input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: Self.time(frame.sampleOffset)))
        }

        public func requestFinalization(through position: Int64) async {
            guard let analyzer = session?.analyzer else { return }
            let time = Self.time(position)
            // Not awaited here: `finalize(through:)` returns only once the
            // audio after `position` has been analyzed, which needs the
            // frames our caller is about to send.
            Task {
                do {
                    try await analyzer.finalize(through: time)
                } catch {
                    Log.asr.error("Apple ASR couldn't finalize: \(String(describing: error), privacy: .public)")
                }
            }
        }

        public func setContextualStrings(_ strings: [String]) async {
            guard let analyzer = session?.analyzer else { return }
            do {
                try await analyzer.setContext(Self.context(strings))
            } catch {
                Log.asr.error(
                    "Apple ASR couldn't update its contextual strings: \(String(describing: error), privacy: .public)")
            }
        }

        public func finish() async {
            guard let session else { return }
            self.session = nil
            session.input.finish()
            do {
                try await session.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.asr.error("Apple ASR couldn't finish: \(String(describing: error), privacy: .public)")
                await session.analyzer.cancelAndFinishNow()
            }
            // The transcriber's results end once the analyzer has finished;
            // don't wait forever if they don't.
            let forwarding = session.forwarding
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await forwarding.value }
                group.addTask { try? await Task.sleep(for: Self.resultsDrainTimeout) }
                await group.next()
                group.cancelAll()
            }
            session.forwarding.cancel()
            session.results.finish()
        }

        public func cancel() async {
            guard let session else { return }
            self.session = nil
            session.input.finish()
            await session.analyzer.cancelAndFinishNow()
            session.forwarding.cancel()
            session.results.finish()
        }

        // MARK: Conversion

        private static func context(_ strings: [String]) -> AnalysisContext {
            let context = AnalysisContext()
            context.contextualStrings[.general] = strings
            return context
        }

        /// A stream offset on the analyzer's timeline.
        static func time(_ offset: Int64) -> CMTime {
            CMTime(value: offset, timescale: CMTimeScale(AudioFrame.captureSampleRate))
        }

        /// An analyzer time as a stream offset.
        static func offset(_ time: CMTime) -> Int64 {
            guard time.isNumeric else { return 0 }
            let rate = CMTimeScale(AudioFrame.captureSampleRate)
            return CMTimeConvertScale(time, timescale: rate, method: .roundHalfAwayFromZero).value
        }

        static func range(_ range: CMTimeRange) -> Range<Int64> {
            let start = offset(range.start)
            return start..<max(start, offset(range.end))
        }

        static func convert(_ result: SpeechTranscriber.Result) -> SpeechAnalyzerResult {
            var segments: [SpeechAnalyzerResult.Segment] = []
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                segments.append(.init(text: text, range: run.audioTimeRange.map(range)))
            }
            return SpeechAnalyzerResult(
                segments: segments,
                range: range(result.range),
                finalizedThrough: offset(result.resultsFinalizationTime),
                isFinal: result.isFinal
            )
        }
    }
#endif
