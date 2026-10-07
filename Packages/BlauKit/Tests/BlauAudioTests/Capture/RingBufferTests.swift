import Foundation
import Testing

@testable import BlauAudio

// The rings are noncopyable, and `#expect` can't take apart a method call
// on a noncopyable base, so results go into locals first.

@Suite("Capture ring buffers")
struct RingBufferTests {
    @Test func capacityRoundsUpToAPowerOfTwo() {
        let capacities = [
            SampleRingBuffer(minimumCapacity: 1).capacity,
            SampleRingBuffer(minimumCapacity: 1_000).capacity,
            SampleRingBuffer(minimumCapacity: 1_024).capacity,
            CaptureChunkQueue(minimumCapacity: 3).capacity,
        ]
        #expect(capacities == [1, 1_024, 1_024, 4])
    }

    @Test func writesAreAllOrNothing() {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        let six: [Float] = [1, 2, 3, 4, 5, 6]
        let first = six.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) }
        // Only two slots left: a three-sample write is refused whole.
        let second = six.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        let readable = ring.readableCount
        let tooBig = ring.writeRegions(count: 3) == nil
        let empty = ring.writeRegions(count: 0) == nil
        #expect(first)
        #expect(!second)
        #expect(readable == 6)
        #expect(tooBig)
        #expect(empty)
    }

    @Test func wrapsAroundAndPreservesOrder() {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        var next: Float = 0
        var received: [Float] = []
        var output = [Float](repeating: 0, count: 8)
        // Odd sizes walk the write position across the end many times.
        for size in [5, 3, 7, 1, 6, 2, 8, 4, 5, 7] {
            let input = (0..<size).map { _ -> Float in
                defer { next += 1 }
                return next
            }
            let written = input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: size) }
            #expect(written)
            let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }
            #expect(read == size)
            received += output[0..<read]
        }
        let remaining = ring.readableCount
        #expect(received == (0..<Int(next)).map(Float.init))
        #expect(remaining == 0)
    }

    @Test func writeRegionsSplitAtTheEnd() throws {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        let filler = [Float](repeating: 0, count: 6)
        _ = filler.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) }
        var sink = [Float](repeating: 0, count: 6)
        _ = sink.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 6) }

        let maybeRegions = ring.writeRegions(count: 5)
        let regions = try #require(maybeRegions)
        #expect(regions.firstCount == 2)
        #expect(regions.secondCount == 3)
        for index in 0..<2 { regions.first[index] = Float(index) }
        for index in 0..<3 { regions.second[index] = Float(index + 2) }
        ring.commitWrite(5)

        var output = [Float](repeating: -1, count: 5)
        _ = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 5) }
        #expect(output == [0, 1, 2, 3, 4])
    }

    @Test func skipDiscardsUnreadSamples() {
        let ring = SampleRingBuffer(minimumCapacity: 4)
        let input: [Float] = [1, 2, 3]
        _ = input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        let skipped = [ring.skip(2), ring.skip(5)]
        let remaining = ring.readableCount
        #expect(skipped == [2, 1])
        #expect(remaining == 0)
    }

    @Test func chunkQueueIsFIFOAndBounded() {
        let queue = CaptureChunkQueue(minimumCapacity: 2)
        let first = CaptureChunk(frameCount: 1, hostTime: 10, gapFrames: 0, droppedBuffers: 0)
        let second = CaptureChunk(frameCount: 2, hostTime: 20, gapFrames: 5, droppedBuffers: 1)
        let pushes = [queue.push(first), queue.push(second)]
        let hasSpace = queue.hasSpace()
        let overflow = queue.push(first)
        let popped = [queue.pop(), queue.pop(), queue.pop()]
        #expect(pushes == [true, true])
        #expect(!hasSpace)
        #expect(!overflow)
        #expect(popped == [first, second, nil])
    }

    /// One producer thread and one consumer thread hammer a small ring; the
    /// consumer must see every sample exactly once, in order.
    @Test(.timeLimit(.minutes(1)))
    func concurrentProducerAndConsumerAgree() {
        // The producer owns its ring; the threads' closures capture it.
        let owner = CaptureProducer(sampleCapacity: 256, chunkCapacity: 1, downmix: .average)
        let total = 2_000_000
        let producerDone = DispatchSemaphore(value: 0)

        let producer = Thread {
            var next = 0
            var block = [Float](repeating: 0, count: 37)
            while next < total {
                let count = min(block.count, total - next)
                for index in 0..<count { block[index] = Float(next + index) }
                if block.withUnsafeBufferPointer({ owner.samples.write($0.baseAddress!, count: count) }) {
                    next += count
                }
            }
            producerDone.signal()
        }
        producer.start()

        // This thread is the consumer.
        var expected = 0
        var mismatches = 0
        var buffer = [Float](repeating: 0, count: 53)
        while expected < total {
            let read = buffer.withUnsafeMutableBufferPointer { owner.samples.read(into: $0.baseAddress!, count: 53) }
            for value in buffer[0..<read] {
                if value != Float(expected) { mismatches += 1 }
                expected += 1
            }
        }

        producerDone.wait()
        let remaining = owner.samples.readableCount
        #expect(mismatches == 0)
        #expect(remaining == 0)
    }
}
