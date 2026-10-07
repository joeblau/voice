import AVFAudio
import BlauCore
import BlauTelemetry
import Synchronization
import os

/// A source of captured 16 kHz mono audio. VAD, voice ID and ASR take one
/// of these rather than `CaptureHub` itself, so their tests can feed
/// fixtures.
public protocol CaptureFrameSource: Sendable {
    /// A new, independent stream of frames. It starts with up to `lookback`
    /// of audio from the rolling history (contiguous with the live frames
    /// that follow), then yields every frame as it is captured.
    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame>

    /// The retained audio in `range` (absolute sample offsets), clipped to
    /// the rolling history, or `nil` if none of it is retained.
    func history(in range: Range<Int64>) -> AudioFrame?
}

extension CaptureFrameSource {
    /// A new stream of live frames, from the next captured frame on.
    public func frames() -> AsyncStream<AudioFrame> {
        frames(replaying: .zero)
    }
}

/// Fans captured 16 kHz mono audio out to any number of consumers and
/// keeps a rolling history.
///
/// ```swift
/// let capture = MicrophoneCapture()
/// await audio.register(capture)
/// await audio.start()
///
/// let hub = capture.hub
/// Task { for await frame in hub.frames() { vad.process(frame) } }
/// Task { for await frame in hub.frames() { asr.process(frame) } }
/// Task { for await level in hub.levels() { meter.level = level.normalized() } }
///
/// // When VAD reports speech start, voice ID looks back 1.5 s:
/// let clip = hub.history(in: (speechStart - 24_000)..<speechStart)
/// ```
///
/// **Frames.** Audio is re-chunked into frames of
/// `configuration.frameLength` samples (20 ms by default) whatever the
/// hardware buffer size, so every consumer sees the same cadence on every
/// route. A frame is shorter only right before a gap or at the end of a
/// capture segment (the graph is rebuilt or stopped).
///
/// **Sample-accurate fan-out.** Every subscriber gets the very same
/// `AudioFrame` values (the sample arrays are shared, not copied) with
/// `sampleOffset` counting 16 kHz samples from the start of capture. Offsets
/// are contiguous (`frame.sampleOffset == previous.nextSampleOffset`) except
/// where audio was lost: when the capture ring overflowed (see
/// `CaptureStatistics.droppedBuffers`) offsets jump by the lost duration,
/// so positions stay aligned with real time. Capture that stops and resumes
/// (an interruption, a route change) continues contiguously; `hostTime`
/// shows the real-time jump.
///
/// **Backpressure.** Each subscriber buffers up to
/// `configuration.subscriberBuffer` of audio. A subscriber that falls
/// further behind loses its oldest frames (counted in
/// `CaptureStatistics.subscriberDroppedFrames`); nobody else is slowed down.
///
/// **History.** The last `configuration.historyDuration` (30 s) of audio is
/// kept for look-back. Audio lost to a drop reads back as silence.
///
/// Thread-safe. The capture thread calls `append`, `skip` and `flush`;
/// consumers call everything else from anywhere.
public final class CaptureHub: CaptureFrameSource {
    public struct Configuration: Sendable, Hashable {
        /// Samples per frame. 320 is 20 ms at 16 kHz.
        public var frameLength: Int
        /// How much audio `history(in:)` and `frames(replaying:)` can reach
        /// back.
        public var historyDuration: Duration
        /// How far a subscriber can fall behind before it loses frames.
        public var subscriberBuffer: Duration

        public init(
            frameLength: Int = 320,
            historyDuration: Duration = .seconds(30),
            subscriberBuffer: Duration = .seconds(10)
        ) {
            precondition(frameLength > 0, "Frames must hold at least one sample")
            precondition(historyDuration > .zero, "History must hold some audio")
            precondition(subscriberBuffer > .zero, "Subscribers need some buffer")
            self.frameLength = frameLength
            self.historyDuration = historyDuration
            self.subscriberBuffer = subscriberBuffer
        }

        /// 20 ms frames, 30 s of history, 10 s of slack per subscriber.
        public static let standard = Configuration()
    }

    private struct Subscriber<Element> {
        let continuation: AsyncStream<Element>.Continuation
        var isDropping = false
    }

    private struct State {
        var nextSampleOffset: Int64 = 0
        /// The frame being filled, and the offset and host time of its first
        /// sample.
        var pending: [Float]
        var pendingOffset: Int64 = 0
        var pendingHostTime: UInt64?
        var history: AudioHistory
        var frameSubscribers: [UInt64: Subscriber<AudioFrame>] = [:]
        var levelSubscribers: [UInt64: Subscriber<AudioLevel>] = [:]
        var nextSubscriberID: UInt64 = 0
        var statistics = CaptureStatistics()
        var isFinished = false
    }

    public let configuration: Configuration
    /// The rate of every frame: 16 kHz.
    public let sampleRate = AudioFrame.captureSampleRate

    private let state: Mutex<State>
    private let ticksPerSample: Double
    private let signposter: Signposter
    private let logger = Log.audio

    /// - Parameters:
    ///   - configuration: Frame size, history length and subscriber slack.
    ///   - signposter: Where the `capture.drop` event goes.
    public init(configuration: Configuration = .standard, signposter: Signposter = Signposts.audio) {
        self.configuration = configuration
        self.signposter = signposter
        let rate = AudioFrame.captureSampleRate
        let historyCapacity = Int(configuration.historyDuration.sampleCount(sampleRate: rate))
        var pending = [Float]()
        pending.reserveCapacity(configuration.frameLength)
        state = Mutex(State(pending: pending, history: AudioHistory(capacity: max(historyCapacity, 1))))
        ticksPerSample = HostTime.ticksPerSecond / Double(rate)
    }

    deinit {
        finish()
    }

    // MARK: Consuming

    public func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        let frameLength = configuration.frameLength
        let replaySamples = max(Int64(0), lookback.sampleCount(sampleRate: sampleRate))
        let replayFrames = Int((replaySamples + Int64(frameLength) - 1) / Int64(frameLength))
        let bufferFrames = Self.frames(in: configuration.subscriberBuffer, frameLength: frameLength) + replayFrames
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioFrame.self,
            bufferingPolicy: .bufferingNewest(max(bufferFrames, 1))
        )

        let id: UInt64? = state.withLock { state in
            guard !state.isFinished else { return nil }
            // Replay inside the lock so no live frame can slip in ahead of
            // it: the replay ends exactly where the next live frame starts.
            if replaySamples > 0,
                let replay = state.history.samples(
                    in: (state.history.endOffset - replaySamples)..<state.history.endOffset)
            {
                var offset = replay.offset
                var index = 0
                while index < replay.samples.count {
                    let end = min(index + frameLength, replay.samples.count)
                    continuation.yield(AudioFrame(samples: Array(replay.samples[index..<end]), sampleOffset: offset))
                    offset += Int64(end - index)
                    index = end
                }
            }
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.frameSubscribers[id] = Subscriber(continuation: continuation)
            return id
        }

        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.frameSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// A new stream of input levels, one per frame, for metering. Only the
    /// newest level is buffered: a slow reader skips levels rather than
    /// falling behind.
    public func levels() -> AsyncStream<AudioLevel> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
        let id: UInt64? = state.withLock { state in
            guard !state.isFinished else { return nil }
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.levelSubscribers[id] = Subscriber(continuation: continuation)
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.levelSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func history(in range: Range<Int64>) -> AudioFrame? {
        state.withLock { state in
            state.history.samples(in: range).map { AudioFrame(samples: $0.samples, sampleOffset: $0.offset) }
        }
    }

    /// The most recent `duration` of retained audio (or less, if less is
    /// retained), or `nil` if nothing is.
    public func recentHistory(_ duration: Duration) -> AudioFrame? {
        state.withLock { state in
            let count = duration.sampleCount(sampleRate: sampleRate)
            let end = state.history.endOffset
            return state.history.samples(in: (end - count)..<end).map {
                AudioFrame(samples: $0.samples, sampleOffset: $0.offset)
            }
        }
    }

    /// The sample offsets `history(in:)` can currently return.
    public var historyRange: Range<Int64> {
        state.withLock { $0.history.range }
    }

    /// Offset the next captured sample will get.
    public var nextSampleOffset: Int64 {
        state.withLock { $0.nextSampleOffset }
    }

    /// A snapshot of the counters.
    public var statistics: CaptureStatistics {
        state.withLock { $0.statistics }
    }

    /// Live frame and level subscriptions.
    public var subscriberCount: Int {
        state.withLock { $0.frameSubscribers.count + $0.levelSubscribers.count }
    }

    /// Ends every stream. Later subscriptions finish immediately; captured
    /// audio still goes into the history.
    public func finish() {
        let (frames, levels) = state.withLock { state in
            state.isFinished = true
            defer {
                state.frameSubscribers.removeAll()
                state.levelSubscribers.removeAll()
            }
            return (
                state.frameSubscribers.values.map(\.continuation), state.levelSubscribers.values.map(\.continuation)
            )
        }
        // Outside the lock: `finish()` runs `onTermination`, which takes it.
        for continuation in frames {
            continuation.finish()
        }
        for continuation in levels {
            continuation.finish()
        }
    }

    // MARK: Producing

    /// Adds captured 16 kHz mono samples that follow the previous ones.
    ///
    /// - Parameter hostTime: Host time of `samples[0]`, if known.
    public func append(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64?) {
        guard !samples.isEmpty else { return }
        let frameLength = configuration.frameLength
        state.withLock { state in
            var index = 0
            while index < samples.count {
                if state.pending.isEmpty {
                    state.pendingOffset = state.nextSampleOffset
                    state.pendingHostTime = hostTime.map { self.advance($0, bySamples: index) }
                }
                let take = min(frameLength - state.pending.count, samples.count - index)
                state.pending.append(contentsOf: UnsafeBufferPointer(rebasing: samples[index..<(index + take)]))
                index += take
                state.nextSampleOffset += Int64(take)
                if state.pending.count == frameLength {
                    emitPending(&state)
                }
            }
        }
    }

    public func append(_ samples: [Float], hostTime: UInt64? = nil) {
        samples.withUnsafeBufferPointer { append($0, hostTime: hostTime) }
    }

    /// Records that `sampleCount` samples were lost (the capture ring
    /// overflowed): emits the partial frame, then moves the stream position
    /// forward so later frames stay aligned with real time.
    ///
    /// - Parameter droppedBuffers: Hardware buffers behind the loss.
    public func skip(_ sampleCount: Int64, droppedBuffers: Int) {
        guard sampleCount > 0 || droppedBuffers > 0 else { return }
        let totals = state.withLock { state in
            emitPending(&state)
            let gap = max(sampleCount, 0)
            state.nextSampleOffset += gap
            state.history.appendSilence(gap)
            state.statistics.droppedBuffers += Int64(droppedBuffers)
            state.statistics.droppedSamples += gap
            state.statistics.gaps += 1
            return (state.statistics.droppedBuffers, state.nextSampleOffset)
        }
        signposter.event("capture.drop")
        logger.error(
            """
            Capture dropped \(droppedBuffers, privacy: .public) buffer(s), \
            \(sampleCount, privacy: .public) samples at 16 kHz (\(totals.0, privacy: .public) buffers in total); \
            resuming at sample \(totals.1, privacy: .public)
            """
        )
    }

    /// Emits the partial frame, if any. Called at the end of a capture
    /// segment so no audio waits for a restart that may never come.
    public func flush() {
        state.withLock { emitPending(&$0) }
    }

    /// Counts one capture segment (a graph build).
    func beginSegment() {
        state.withLock { $0.statistics.segments += 1 }
    }

    /// Counts a buffer the converter rejected.
    func recordConversionFailure() {
        state.withLock { $0.statistics.conversionFailures += 1 }
    }

    // MARK: Internals

    private func emitPending(_ state: inout State) {
        guard !state.pending.isEmpty else { return }
        let frame = AudioFrame(
            samples: state.pending, sampleOffset: state.pendingOffset, hostTime: state.pendingHostTime)
        state.pending.removeAll(keepingCapacity: true)
        state.pendingHostTime = nil

        state.history.append(frame.samples)
        state.statistics.framesPublished += 1
        state.statistics.samplesPublished += Int64(frame.sampleCount)

        // Yield while holding the lock, so frames reach every subscriber in
        // order and a subscription that replays history can't interleave.
        // `yield` never calls `onTermination`, so this can't re-enter.
        for (id, subscriber) in state.frameSubscribers {
            switch subscriber.continuation.yield(frame) {
            case .enqueued:
                if subscriber.isDropping {
                    state.frameSubscribers[id]?.isDropping = false
                    logger.notice("Capture subscriber \(id, privacy: .public) caught up")
                }
            case .dropped:
                state.statistics.subscriberDroppedFrames += 1
                if !subscriber.isDropping {
                    state.frameSubscribers[id]?.isDropping = true
                    logger.error("Capture subscriber \(id, privacy: .public) fell behind; dropping its oldest frames")
                }
            case .terminated:
                state.frameSubscribers[id] = nil
            @unknown default:
                break
            }
        }

        guard !state.levelSubscribers.isEmpty else { return }
        let level = AudioLevel(rms: frame.rms, peak: frame.peak, sampleOffset: frame.sampleOffset)
        for (id, subscriber) in state.levelSubscribers {
            if case .terminated = subscriber.continuation.yield(level) {
                state.levelSubscribers[id] = nil
            }
        }
    }

    private func advance(_ hostTime: UInt64, bySamples samples: Int) -> UInt64 {
        hostTime &+ UInt64((Double(samples) * ticksPerSample).rounded())
    }

    private static func frames(in duration: Duration, frameLength: Int) -> Int {
        let samples = duration.sampleCount(sampleRate: AudioFrame.captureSampleRate)
        return Int((samples + Int64(frameLength) - 1) / Int64(frameLength))
    }
}

/// Host time (`mach_absolute_time` ticks) conversions.
enum HostTime {
    /// Ticks per second: 24 MHz on Apple silicon, 1 GHz on Intel.
    static let ticksPerSecond = Double(AVAudioTime.hostTime(forSeconds: 1))

    /// `hostTime` moved by `seconds`, which may be negative.
    static func offset(_ hostTime: UInt64, bySeconds seconds: Double) -> UInt64 {
        let ticks = (seconds * ticksPerSecond).rounded()
        if ticks >= 0 {
            return hostTime &+ UInt64(ticks)
        }
        let back = UInt64(-ticks)
        return hostTime > back ? hostTime - back : 0
    }
}
