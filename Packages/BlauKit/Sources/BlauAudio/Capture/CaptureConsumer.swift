import BlauCore
import BlauTelemetry
import os

/// The capture thread's half of a segment: drains the producer's ring,
/// resamples to 16 kHz, timestamps the audio and hands it to the hub.
///
/// Not thread-safe: one capture thread owns it.
///
/// **Timeline.** The consumer counts hardware frames from the start of the
/// segment, including frames the producer dropped, and maps them onto the
/// hub's 16 kHz offsets (`baseOffset + position × 16 000 / hardwareRate`).
/// A drop flushes the resampler and skips the hub forward to where the
/// next audio belongs, so offsets stay aligned with real time.
///
/// **Host time.** Each chunk's host time anchors the output that follows
/// it, so timestamps track the hardware clock over an hour-long session
/// instead of drifting.
final class CaptureConsumer {
    private let producer: CaptureProducer
    private let hub: CaptureHub
    private let resampler: CaptureResampler
    private let signposter: Signposter
    private let logger = Log.audio

    private let outputSampleRate: Double
    private let ratio: Double
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    /// Hub offset where this segment started.
    private let baseOffset: Int64
    /// Hardware frames consumed so far, dropped ones included.
    private var inputPosition: Int64 = 0
    /// Hub offset of the next sample this consumer emits.
    private var emittedOffset: Int64
    /// A host time and the hub offset it belongs to.
    private var anchor: (hostTime: UInt64, offset: Int64)?
    private var chunksProcessed: Int64 = 0

    init(
        producer: CaptureProducer,
        hub: CaptureHub,
        inputSampleRate: Double,
        signposter: Signposter,
        maximumChunk: Int = 4_096
    ) throws(CaptureError) {
        self.producer = producer
        self.hub = hub
        self.signposter = signposter
        self.outputSampleRate = Double(hub.sampleRate)
        self.resampler = try CaptureResampler(
            inputSampleRate: inputSampleRate,
            outputSampleRate: Double(hub.sampleRate),
            maximumChunk: maximumChunk
        )
        self.ratio = Double(hub.sampleRate) / inputSampleRate
        self.scratchCapacity = maximumChunk
        self.scratch = .allocate(capacity: maximumChunk)
        self.baseOffset = hub.nextSampleOffset
        self.emittedOffset = baseOffset
    }

    deinit {
        scratch.deallocate()
    }

    /// Processes every chunk in the ring.
    ///
    /// - Returns: The number of chunks processed.
    @discardableResult
    func drain() -> Int {
        var processed = 0
        while let chunk = producer.chunks.pop() {
            signposter.withInterval(.captureFrame) {
                process(chunk)
            }
            processed += 1
        }
        chunksProcessed += Int64(processed)
        return processed
    }

    /// Ends the segment once the producer is closed: processes what is
    /// left, accounts for drops nothing reported yet, emits the resampler's
    /// tail and the hub's partial frame.
    func finish() {
        drain()
        let pending = producer.takePendingDrops()
        if pending.gapFrames > 0 || pending.droppedBuffers > 0 {
            skip(frames: pending.gapFrames, droppedBuffers: pending.droppedBuffers)
        }
        flushResampler()
        hub.flush()
        logger.notice(
            """
            Capture segment ended: \(self.chunksProcessed, privacy: .public) buffer(s), \
            \(self.emittedOffset - self.baseOffset, privacy: .public) samples at 16 kHz
            """
        )
    }

    private func process(_ chunk: CaptureChunk) {
        if chunk.gapFrames > 0 || chunk.droppedBuffers > 0 {
            skip(frames: chunk.gapFrames, droppedBuffers: chunk.droppedBuffers)
        }
        if chunk.hostTime != 0 {
            anchor = (chunk.hostTime, expectedOffset(at: inputPosition))
        }

        var remaining = chunk.frameCount
        var failed = false
        while remaining > 0 {
            let count = producer.samples.read(into: scratch, count: min(remaining, scratchCapacity))
            guard count > 0 else { break }
            remaining -= count
            guard !failed else { continue }
            do {
                try resampler.process(UnsafeBufferPointer(start: scratch, count: count)) { output in
                    emit(output)
                }
            } catch {
                failed = true
                hub.recordConversionFailure()
                logger.error("Capture conversion failed: \(error, privacy: .public)")
                resampler.reset()
            }
        }
        inputPosition += Int64(chunk.frameCount)
        if failed {
            realign(droppedBuffers: 0)
        }
    }

    /// Handles `frames` hardware frames the producer dropped.
    private func skip(frames: Int, droppedBuffers: Int) {
        flushResampler()
        inputPosition += Int64(max(frames, 0))
        realign(droppedBuffers: droppedBuffers)
    }

    /// Moves the hub forward to where the audio at `inputPosition` belongs.
    private func realign(droppedBuffers: Int) {
        let gap = max(0, expectedOffset(at: inputPosition) - emittedOffset)
        hub.skip(gap, droppedBuffers: droppedBuffers)
        emittedOffset += gap
    }

    private func flushResampler() {
        do {
            try resampler.flush { output in
                emit(output)
            }
        } catch {
            hub.recordConversionFailure()
            logger.error("Capture conversion failed while flushing: \(error, privacy: .public)")
        }
    }

    private func emit(_ samples: UnsafeBufferPointer<Float>) {
        let hostTime = anchor.map { anchor in
            HostTime.offset(anchor.hostTime, bySeconds: Double(emittedOffset - anchor.offset) / outputSampleRate)
        }
        hub.append(samples, hostTime: hostTime)
        emittedOffset += Int64(samples.count)
    }

    private func expectedOffset(at inputPosition: Int64) -> Int64 {
        baseOffset + Int64((Double(inputPosition) * ratio).rounded())
    }
}
