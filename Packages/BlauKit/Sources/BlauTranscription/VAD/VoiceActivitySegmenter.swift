import Accelerate
import BlauAudio
import BlauCore
import BlauTelemetry
import Synchronization

/// The streaming voice activity segmenter: finds where speech starts and
/// ends in the captured audio so ASR, voice ID and turn-taking get clean
/// segments (#28).
///
/// ```swift
/// let model = try await SileroSpeechProbabilityModel(modelDirectory: directory)
/// let vad = VoiceActivitySegmenter(model: model)
/// Task { await vad.run(on: capture.hub) }
///
/// for await event in vad.events() {
///     switch event {
///     case .speechStarted(let onset): ...            // barge-in, voice ID look-back
///     case .speechEnded(let segment):
///         let audio = capture.hub.audio(for: segment) // sample-accurate
///     }
/// }
///
/// // ASR computes only while someone speaks:
/// for await item in vad.speechAudio() { ... }        // .started, .audio, .ended
/// ```
///
/// The model (Silero VAD v6) scores 256 ms chunks; the segmenter turns its
/// probabilities into segments with a threshold and hysteresis, a minimum
/// speech duration (250 ms), a hangover (300 ms) and a maximum segment
/// length (8 s, split at the quietest point), and refines each boundary to
/// 16 ms from the signal's energy (see `SpeechSegmentationStateMachine` and
/// docs/vad.md).
///
/// **Power.** While nobody speaks, a chunk quieter than
/// `modelSkipLevelDecibels` skips the model entirely, and consumers of
/// `speechAudio()` receive nothing, so ASR does no work in silence.
///
/// **Offsets** are absolute 16 kHz sample offsets of the capture stream,
/// so `CaptureFrameSource.audio(for:)` reads a segment back from the
/// capture history. A gap in the input (capture dropped audio) up to 1 s is
/// analysed as silence, keeping offsets aligned; a longer one ends any open
/// segment (`.streamEnded`) and restarts the analysis after it.
///
/// Feed it from one producer: `run(on:)`, or `process(_:)` calls that are
/// awaited in order.
public actor VoiceActivitySegmenter: VoiceActivitySource {
    public nonisolated let configuration: VoiceActivityConfiguration

    private let model: any SpeechProbabilityModel
    private let chunkLength: Int
    private let signposter: Signposter
    private let clock: any BlauClock
    private let logger = Log.asr

    private var machine: SpeechSegmentationStateMachine
    /// Received audio not yet analysed, starting at `pendingStart`.
    private var pending: [Float] = []
    private var pendingStart: Int64 = 0
    /// End of the audio received so far; `nil` before the first frame.
    private var receivedEnd: Int64?
    private var recent: RecentAudio
    /// Where `speechAudio()` audio has been delivered up to.
    private var audioDeliveredEnd: Int64 = 0
    private var modelNeedsReset = false
    private var isDraining = false
    private var finishRequested = false
    private var isFinished = false
    private var consecutiveFailures = 0
    private var loggedRateMismatch = false

    private let eventBroadcaster = Broadcaster<VoiceActivityEvent>(bufferingPolicy: .unbounded)
    /// About 30 s of 20 ms frames for a slow consumer.
    private let audioBroadcaster = Broadcaster<SpeechAudioEvent>(bufferingPolicy: .bufferingNewest(1_500))
    private let shared = Mutex(SharedState())

    private struct SharedState {
        var isSpeechActive = false
        var statistics = VoiceActivityStatistics()
    }

    /// The longest gap in the input analysed as silence.
    static let maximumFilledGap: Int64 = Int64(AudioFrame.captureSampleRate)
    /// A partial last chunk shorter than this isn't worth a model call.
    static let minimumFinalChunk = 1_024

    /// - Parameters:
    ///   - model: The speech classifier, normally
    ///     `SileroSpeechProbabilityModel`.
    ///   - configuration: Thresholds and durations.
    ///   - signposter: Where the `vad.chunk` intervals go.
    ///   - clock: Measures the model's run time for `statistics`.
    public init(
        model: any SpeechProbabilityModel,
        configuration: VoiceActivityConfiguration = .standard,
        signposter: Signposter = Signposts.asr,
        clock: any BlauClock = SystemClock()
    ) {
        precondition(model.chunkLength > 0, "The model must take at least one sample per chunk")
        self.model = model
        self.chunkLength = model.chunkLength
        self.configuration = configuration
        self.signposter = signposter
        self.clock = clock
        self.machine = SpeechSegmentationStateMachine(configuration: configuration)
        // The onset look-back, the confirmation delay and a few chunks of
        // decision latency, with room to spare.
        self.recent = RecentAudio(capacity: AudioFrame.captureSampleRate * 4 + model.chunkLength * 2)
        pending.reserveCapacity(model.chunkLength * 2)
    }

    // MARK: VoiceActivitySource

    public nonisolated func events() -> AsyncStream<VoiceActivityEvent> {
        eventBroadcaster.subscribe()
    }

    public nonisolated func speechAudio() -> AsyncStream<SpeechAudioEvent> {
        audioBroadcaster.subscribe()
    }

    public nonisolated var isSpeechActive: Bool {
        shared.withLock { $0.isSpeechActive }
    }

    /// A snapshot of the counters.
    public nonisolated var statistics: VoiceActivityStatistics {
        shared.withLock { $0.statistics }
    }

    // MARK: Feeding

    /// Segments `source`'s live audio until its stream ends or the calling
    /// task is cancelled, then finishes (closing an open segment and
    /// ending every stream).
    public func run(on source: some CaptureFrameSource) async {
        for await frame in source.frames() {
            await process(frame)
        }
        await finish()
    }

    /// Feeds one frame of 16 kHz mono audio. Frames must arrive in stream
    /// order; audio overlapping what was already received is ignored.
    public func process(_ frame: AudioFrame) async {
        guard !isFinished, !finishRequested, !frame.isEmpty else { return }
        guard frame.sampleRate == AudioFrame.captureSampleRate else {
            if !loggedRateMismatch {
                loggedRateMismatch = true
                logger.fault("VAD dropped \(frame.sampleRate, privacy: .public) Hz audio; it takes 16 kHz frames")
            }
            return
        }
        receive(frame)
        await drain()
    }

    /// Analyses what is left, closes an open segment with `.streamEnded`
    /// and ends every stream. Later frames are ignored.
    public func finish() async {
        guard !isFinished, !finishRequested else { return }
        finishRequested = true
        await drain()
    }

    // MARK: Receiving

    private func receive(_ frame: AudioFrame) {
        var samples = frame.samples[...]
        var offset = frame.sampleOffset

        if let end = receivedEnd {
            if offset < end {
                // Overlaps audio already received (for example a replayed
                // history frame): keep only the new part.
                let overlap = Int(min(end - offset, Int64(samples.count)))
                samples = samples.dropFirst(overlap)
                offset += Int64(overlap)
                guard !samples.isEmpty else { return }
            } else if offset > end {
                handleGap(from: end, to: offset)
            }
        } else {
            start(at: offset)
        }

        append(samples, at: offset)
    }

    private func start(at offset: Int64) {
        machine.begin(at: offset)
        pending.removeAll(keepingCapacity: true)
        pendingStart = offset
        receivedEnd = offset
        recent.reset(at: offset)
        audioDeliveredEnd = offset
        modelNeedsReset = true
    }

    private func handleGap(from end: Int64, to offset: Int64) {
        let gap = offset - end
        update { $0.gaps += 1 }
        if gap <= Self.maximumFilledGap {
            logger.notice(
                "VAD input gap of \(gap, privacy: .public) samples at \(end, privacy: .public); filling with silence")
            append(ArraySlice(repeating: 0, count: Int(gap)), at: end)
        } else {
            // Too long to pretend it was silence: close what is open and
            // restart the analysis after the gap. Unanalysed audio before
            // the gap is dropped.
            logger.notice("VAD input gap of \(gap, privacy: .public) samples at \(end, privacy: .public); restarting")
            publish(machine.finish(at: end))
            start(at: offset)
        }
    }

    private func append(_ samples: ArraySlice<Float>, at offset: Int64) {
        pending.append(contentsOf: samples)
        recent.append(samples)
        let end = offset + Int64(samples.count)
        receivedEnd = end
        if machine.isSpeechActive {
            deliverAudio(upTo: end)
        }
    }

    // MARK: Analysis

    /// Analyses every complete chunk. Re-entrant calls (another frame
    /// arriving while the model runs) only queue audio; the running drain
    /// picks it up.
    private func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while pending.count >= chunkLength {
            let chunk = Array(pending[0..<chunkLength])
            pending.removeFirst(chunkLength)
            let start = pendingStart
            pendingStart += Int64(chunkLength)
            await analyze(chunk, at: start)
        }

        guard finishRequested, !isFinished else { return }
        if pending.count >= Self.minimumFinalChunk {
            let chunk = pending
            let start = pendingStart
            pending.removeAll()
            pendingStart += Int64(chunk.count)
            await analyze(chunk, at: start)
        }
        publish(machine.finish(at: receivedEnd ?? machine.processedEnd))
        isFinished = true
        eventBroadcaster.finish()
        audioBroadcaster.finish()
        let statistics = statistics
        logger.notice(
            """
            VAD finished: \(statistics.segments, privacy: .public) segments, \
            \(statistics.chunksAnalyzed, privacy: .public) chunks analysed, \
            \(statistics.chunksSkipped, privacy: .public) skipped
            """
        )
    }

    private func analyze(_ samples: [Float], at offset: Int64) async {
        let levels = Self.subframeLevels(of: samples)
        let chunkLevel = AudioLevelMath.decibels(of: samples[...])

        var probability: Float = 0
        if let skipLevel = configuration.modelSkipLevelDecibels, !machine.hasOpenSegment, chunkLevel < skipLevel {
            // Quiet enough to be silence: save the model call. The model's
            // state no longer follows the stream, so reset it before the
            // next call.
            modelNeedsReset = true
            update { $0.chunksSkipped += 1 }
        } else {
            if modelNeedsReset {
                modelNeedsReset = false
                await model.reset()
            }
            let started = clock.uptime
            do {
                probability = try await signposter.withInterval(.vadChunk) {
                    try await model.speechProbability(of: samples, at: offset)
                }
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                modelNeedsReset = true
                update { $0.modelFailures += 1 }
                if consecutiveFailures == 1 || consecutiveFailures.isMultiple(of: 100) {
                    logger.error(
                        """
                        VAD model failed at \(offset, privacy: .public) \
                        (\(self.consecutiveFailures, privacy: .public) in a row): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                }
            }
            let elapsed = clock.uptime - started
            update {
                $0.chunksAnalyzed += 1
                $0.modelTime += elapsed
            }
        }

        let events = machine.process(
            .init(
                startOffset: offset, sampleCount: samples.count, probability: min(max(probability, 0), 1),
                levels: levels)
        )
        update { $0.samplesProcessed += Int64(samples.count) }
        publish(events)
    }

    /// Sends `events` to both streams, delivering the audio of a newly
    /// started segment first.
    private func publish(_ events: [VoiceActivityEvent]) {
        let counters = machine.counters
        let isActive = machine.isSpeechActive
        shared.withLock { state in
            state.isSpeechActive = isActive
            state.statistics.segments = Int64(counters.segments)
            state.statistics.forcedSplits = Int64(counters.forcedSplits)
            state.statistics.rejectedCandidates = Int64(counters.rejectedCandidates)
            state.statistics.speechSamples = counters.speechSamples
        }

        for event in events {
            eventBroadcaster.yield(event)
            switch event {
            case .speechStarted(let onset):
                logger.debug(
                    """
                    Speech started at \(onset.startOffset, privacy: .public) \
                    (segment \(onset.segmentID, privacy: .public), \
                    detected after \(onset.detectedAt - onset.startOffset, privacy: .public) samples)
                    """
                )
                yieldAudioEvent(.started(onset))
                if !onset.isContinuation {
                    // A new segment's audio starts at its onset, even if the
                    // previous segment's hangover already carried some of it.
                    audioDeliveredEnd = onset.startOffset
                }
                deliverAudio(upTo: receivedEnd ?? onset.detectedAt)
            case .speechEnded(let segment):
                logger.info(
                    """
                    Speech segment \(segment.id, privacy: .public): \
                    \(segment.sampleRange.lowerBound, privacy: .public)..<\(segment.sampleRange.upperBound, privacy: .public) \
                    (\(segment.sampleCount / 16, privacy: .public) ms, \(segment.endReason.rawValue, privacy: .public))
                    """
                )
                yieldAudioEvent(.ended(segment))
            }
        }
    }

    /// Sends the received audio from `audioDeliveredEnd` to `end` to
    /// `speechAudio()` subscribers, once.
    private func deliverAudio(upTo end: Int64) {
        guard end > audioDeliveredEnd, let audio = recent.samples(in: audioDeliveredEnd..<end) else { return }
        audioDeliveredEnd = end
        yieldAudioEvent(.audio(AudioFrame(samples: audio.samples, sampleOffset: audio.offset)))
    }

    private func yieldAudioEvent(_ event: SpeechAudioEvent) {
        let dropped = audioBroadcaster.yield(event)
        if dropped > 0 {
            update { $0.droppedAudioEvents += Int64(dropped) }
        }
    }

    private func update(_ body: (inout VoiceActivityStatistics) -> Void) {
        shared.withLock { body(&$0.statistics) }
    }

    /// RMS level in dBFS of each 16 ms subframe.
    static func subframeLevels(of samples: [Float]) -> [Float] {
        let length = SpeechSegmentationStateMachine.subframeLength
        var levels = [Float]()
        levels.reserveCapacity((samples.count + length - 1) / length)
        var index = 0
        while index < samples.count {
            let end = min(index + length, samples.count)
            levels.append(AudioLevelMath.decibels(of: samples[index..<end]))
            index = end
        }
        return levels
    }
}
