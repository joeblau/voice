import AVFAudio
import BlauCore
import Darwin
import Foundation
import Synchronization

@testable import BlauAudio

// MARK: - Audio buffers

/// A Float32 PCM buffer to hand to the producer, as the sink node or tap
/// would. `fill(frame, channel)` gives each sample's value.
func makeBuffer(
    frames: Int,
    channels: Int = 1,
    sampleRate: Double = 48_000,
    interleaved: Bool = false,
    fill: (Int, Int) -> Float
) -> AVAudioPCMBuffer {
    // More than two channels need an explicit layout, as VPIO's
    // multichannel Mac input has.
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        interleaved: interleaved,
        channelLayout: layout
    )
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    for frame in 0..<frames {
        for channel in 0..<channels {
            if interleaved {
                data[0][frame * channels + channel] = fill(frame, channel)
            } else {
                data[channel][frame] = fill(frame, channel)
            }
        }
    }
    return buffer
}

/// A buffer with the same signal on every channel.
func makeBuffer(
    frames: Int,
    channels: Int = 1,
    sampleRate: Double = 48_000,
    interleaved: Bool = false,
    fill signal: (Int) -> Float
) -> AVAudioPCMBuffer {
    makeBuffer(frames: frames, channels: channels, sampleRate: sampleRate, interleaved: interleaved) { frame, _ in
        signal(frame)
    }
}

/// Hands `buffer` to `producer` the way the audio thread does.
@discardableResult
func write(_ buffer: AVAudioPCMBuffer, to producer: CaptureProducer, hostTime: UInt64 = 0) -> CaptureWriteResult {
    producer.receive(buffer.audioBufferList, frameCount: Int(buffer.frameLength), hostTime: hostTime)
}

/// Everything in the producer's ring, as the consumer would read it.
func drainSamples(_ producer: CaptureProducer) -> (chunks: [CaptureChunk], samples: [Float]) {
    var chunks: [CaptureChunk] = []
    var samples: [Float] = []
    while let chunk = producer.chunks.pop() {
        chunks.append(chunk)
        var piece = [Float](repeating: 0, count: chunk.frameCount)
        let read = piece.withUnsafeMutableBufferPointer {
            producer.samples.read(into: $0.baseAddress!, count: chunk.frameCount)
        }
        samples += piece[0..<read]
    }
    return (chunks, samples)
}

func sine(frequency: Double, sampleRate: Double, amplitude: Float = 0.5) -> (Int) -> Float {
    { index in amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate)) }
}

/// Frequency estimated from rising zero crossings.
func estimatedFrequency(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double {
    var crossings: [Int] = []
    var previous = samples.first ?? 0
    for (index, sample) in zip(samples.indices, samples) {
        if previous < 0 && sample >= 0 {
            crossings.append(index)
        }
        previous = sample
    }
    guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
    return Double(crossings.count - 1) * sampleRate / Double(last - first)
}

// MARK: - Collecting streams

/// Collects a stream on its own task until it finishes.
func collect<Element: Sendable>(_ stream: AsyncStream<Element>) -> Task<[Element], Never> {
    Task {
        var elements: [Element] = []
        for await element in stream {
            elements.append(element)
        }
        return elements
    }
}

// MARK: - Allocation counting

/// Counts heap allocations made by one thread, using libmalloc's
/// `malloc_logger` hook (the one `malloc_history` and Instruments' stack
/// logging use). Every `malloc`, `calloc`, `realloc` and Swift object
/// allocation goes through it, from any library.
///
/// Process-wide state, so measurements are serialized.
enum AllocationCounter {
    typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Address of libmalloc's `malloc_logger` variable, `0` if it isn't
    /// exported. Kept as an integer so the static is `Sendable`.
    private static let hookAddress: UInt = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return 0 }
        return UInt(bitPattern: symbol)
    }()

    private static var hook: UnsafeMutablePointer<MallocLogger?>? {
        UnsafeMutableRawPointer(bitPattern: hookAddress)?.assumingMemoryBound(to: MallocLogger?.self)
    }
    private static let serial = Mutex(())

    /// Whether this libmalloc exports the hook.
    static var isAvailable: Bool { hook != nil }

    /// Runs `body` on the calling thread and returns how many allocations
    /// that thread made meanwhile, or `nil` if the hook isn't available.
    static func allocations(during body: () -> Void) -> Int? {
        guard let hook else { return nil }
        return serial.withLock { _ in
            allocationCount.store(0, ordering: .sequentiallyConsistent)
            targetThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            hook.pointee = { type, _, _, _, _, _ in
                guard type & 2 != 0,  // MALLOC_LOG_TYPE_ALLOCATE
                    UInt(bitPattern: pthread_self()) == targetThread.load(ordering: .relaxed)
                else { return }
                allocationCount.wrappingAdd(1, ordering: .relaxed)
            }
            body()
            hook.pointee = nil
            targetThread.store(0, ordering: .sequentiallyConsistent)
            return allocationCount.load(ordering: .sequentiallyConsistent)
        }
    }
}

private let allocationCount = Atomic<Int>(0)
private let targetThread = Atomic<UInt>(0)
