import CoreAudioTypes
import Dispatch
import Synchronization

/// How the producer turns multichannel input into mono.
enum CaptureDownmix: Sendable, Hashable {
    /// Use only the first channel. Voice processing puts its processed
    /// signal there; on some Macs it reports extra channels that carry no
    /// speech, so averaging them in would only add noise.
    case firstChannel
    /// Average every channel: the right choice for an unprocessed
    /// multi-mic or stereo input.
    case average
}

/// What happened to one hardware buffer handed to the producer.
enum CaptureWriteResult: Sendable, Hashable {
    /// Copied into the ring.
    case written
    /// The ring (or the chunk queue) was full; the buffer was counted as
    /// dropped and the gap will be reported with the next written chunk.
    case dropped
    /// Empty buffer, or the producer was closed.
    case ignored
}

/// The real-time half of capture: copies each hardware buffer, downmixed to
/// mono, into a preallocated lock-free ring and wakes the capture thread.
///
/// `write` runs on the audio I/O thread. It never allocates, locks, retains
/// or releases, and never calls into code the compiler can't see (it is
/// `@_noLocks`). If the ring is full it drops the buffer, counts it, and
/// tells the consumer how many frames went missing with the next buffer
/// that fits, so the timeline stays aligned.
///
/// `@unchecked Sendable`: shared between the audio thread (the only caller
/// of `write` / `receive`) and the capture thread (the only reader of the
/// rings and of `takePendingDrops()`). All shared state is in atomics or in
/// the SPSC rings, which synchronize themselves.
final class CaptureProducer: @unchecked Sendable {
    let samples: SampleRingBuffer
    let chunks: CaptureChunkQueue
    let downmix: CaptureDownmix
    /// Signalled after every write so the capture thread wakes up.
    let wake = DispatchSemaphore(value: 0)

    private let firstChannelOnly: Bool
    /// Byte offset of `AudioBufferList.mBuffers`, computed without key
    /// paths so the real-time code doesn't need them.
    private let buffersOffset: Int
    private let closed = Atomic<Bool>(false)
    private let pendingGapFrames = Atomic<Int>(0)
    private let pendingDroppedBuffers = Atomic<Int>(0)

    /// - Parameters:
    ///   - sampleCapacity: Mono hardware-rate samples the ring holds
    ///     (rounded up to a power of two).
    ///   - chunkCapacity: Hardware buffers the ring can describe at once.
    ///   - downmix: How to reduce multichannel input to mono.
    init(sampleCapacity: Int, chunkCapacity: Int, downmix: CaptureDownmix) {
        samples = SampleRingBuffer(minimumCapacity: sampleCapacity)
        chunks = CaptureChunkQueue(minimumCapacity: chunkCapacity)
        self.downmix = downmix
        firstChannelOnly = downmix == .firstChannel
        let alignment = MemoryLayout<AudioBuffer>.alignment
        buffersOffset = (MemoryLayout<UInt32>.size + alignment - 1) / alignment * alignment
    }

    // MARK: Audio thread

    /// Writes one hardware buffer and wakes the capture thread. This is
    /// what the sink node's receiver block and the tap block call.
    ///
    /// `DispatchSemaphore.signal()` is an atomic increment plus, when the
    /// capture thread is waiting, a `semaphore_signal` Mach trap. It doesn't
    /// allocate or block, which is why it is the one call outside the
    /// compiler-checked `write`.
    @discardableResult
    func receive(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, hostTime: UInt64)
        -> CaptureWriteResult
    {
        let result = write(bufferList, frameCount: frameCount, hostTime: hostTime)
        if result == .written {
            wake.signal()
        }
        return result
    }

    /// Copies `frameCount` frames of Float32 audio from `bufferList`
    /// (planar or interleaved, any channel count) into the ring as mono.
    ///
    /// - Parameter hostTime: Host time of the first frame, `0` if unknown.
    @_noLocks
    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, hostTime: UInt64)
        -> CaptureWriteResult
    {
        if closed.load(ordering: .acquiring) || frameCount <= 0 {
            return .ignored
        }
        guard chunks.hasSpace(), let regions = samples.writeRegions(count: frameCount) else {
            pendingGapFrames.wrappingAdd(frameCount, ordering: .relaxed)
            pendingDroppedBuffers.wrappingAdd(1, ordering: .relaxed)
            return .dropped
        }
        mix(bufferList, into: regions.first, count: regions.firstCount, sourceOffset: 0)
        if regions.secondCount > 0 {
            mix(bufferList, into: regions.second, count: regions.secondCount, sourceOffset: regions.firstCount)
        }
        samples.commitWrite(frameCount)
        let gapFrames = pendingGapFrames.exchange(0, ordering: .relaxed)
        let droppedBuffers = pendingDroppedBuffers.exchange(0, ordering: .relaxed)
        let chunk = CaptureChunk(
            frameCount: frameCount,
            hostTime: hostTime,
            gapFrames: gapFrames,
            droppedBuffers: droppedBuffers
        )
        // Can't fail: `hasSpace()` was true and only this thread pushes.
        _ = chunks.push(chunk)
        return .written
    }

    /// Writes frames `sourceOffset ..< sourceOffset + count` of every
    /// channel in `bufferList`, mixed to mono, to `destination`. Channels
    /// that are shorter than `frameCount` (a malformed list) contribute
    /// silence for the missing frames.
    @_noLocks
    private func mix(
        _ bufferList: UnsafePointer<AudioBufferList>,
        into destination: UnsafeMutablePointer<Float>,
        count: Int,
        sourceOffset: Int
    ) {
        var cleared = 0
        while cleared < count {
            destination[cleared] = 0
            cleared += 1
        }
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        let buffers = UnsafeRawPointer(bufferList)
            .advanced(by: buffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        var channelsMixed = 0

        bufferLoop: for bufferIndex in 0..<bufferCount {
            let buffer = buffers[bufferIndex]
            let interleave = Int(buffer.mNumberChannels)
            guard interleave > 0, let data = buffer.mData else { continue }
            let source = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            let framesInBuffer = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * interleave)
            let usable = max(0, min(count, framesInBuffer - sourceOffset))

            for channel in 0..<interleave {
                if firstChannelOnly && channelsMixed == 1 {
                    break bufferLoop
                }
                var frame = 0
                while frame < usable {
                    destination[frame] += source[(sourceOffset + frame) * interleave + channel]
                    frame += 1
                }
                channelsMixed += 1
            }
        }

        if channelsMixed > 1 {
            let scale = 1 / Float(channelsMixed)
            var frame = 0
            while frame < count {
                destination[frame] *= scale
                frame += 1
            }
        }
    }

    // MARK: Lifecycle

    /// Stops accepting audio. Buffers already in the ring are still read.
    func close() {
        closed.store(true, ordering: .releasing)
        wake.signal()
    }

    var isClosed: Bool { closed.load(ordering: .acquiring) }

    /// Drops the producer counted that no written chunk has reported yet
    /// (they happened after the last successful write). Capture thread
    /// only, after `close()`.
    func takePendingDrops() -> (gapFrames: Int, droppedBuffers: Int) {
        (
            pendingGapFrames.exchange(0, ordering: .relaxed),
            pendingDroppedBuffers.exchange(0, ordering: .relaxed)
        )
    }
}
