import AVFAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauAudio

@Suite("CaptureProducer")
struct CaptureProducerTests {
    @Test func copiesMonoAndRecordsHostTime() {
        let producer = CaptureProducer(sampleCapacity: 4_096, chunkCapacity: 8, downmix: .average)
        let buffer = makeBuffer(frames: 480) { frame, _ in Float(frame) }
        #expect(write(buffer, to: producer, hostTime: 1_000) == .written)

        let (chunks, samples) = drainSamples(producer)
        #expect(chunks == [CaptureChunk(frameCount: 480, hostTime: 1_000, gapFrames: 0, droppedBuffers: 0)])
        #expect(samples == (0..<480).map(Float.init))
    }

    @Test(arguments: [false, true])
    func averagesChannels(interleaved: Bool) {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .average)
        let buffer = makeBuffer(frames: 64, channels: 2, interleaved: interleaved) { frame, channel in
            channel == 0 ? Float(frame) : -0.5
        }
        write(buffer, to: producer)
        #expect(drainSamples(producer).samples == (0..<64).map { (Float($0) - 0.5) / 2 })
    }

    @Test func voiceProcessedInputUsesTheFirstChannelOnly() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .firstChannel)
        let buffer = makeBuffer(frames: 32, channels: 3) { frame, channel in
            channel == 0 ? Float(frame) : 100
        }
        write(buffer, to: producer)
        #expect(drainSamples(producer).samples == (0..<32).map(Float.init))
    }

    @Test func framesMissingFromAShortBufferAreSilence() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .average)
        let buffer = makeBuffer(frames: 10) { _, _ in 1 }
        // Claim more frames than the buffer list holds.
        producer.receive(buffer.audioBufferList, frameCount: 16, hostTime: 0)
        #expect(drainSamples(producer).samples == Array(repeating: 1, count: 10) + Array(repeating: 0, count: 6))
    }

    @Test func dropsWhenFullAndReportsTheGapWithTheNextBuffer() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .average)
        let buffer = makeBuffer(frames: 400) { _, _ in 0.25 }
        #expect(write(buffer, to: producer) == .written)
        #expect(write(buffer, to: producer) == .written)
        // 224 slots left: the next two buffers are dropped.
        #expect(write(buffer, to: producer) == .dropped)
        #expect(write(buffer, to: producer) == .dropped)
        _ = drainSamples(producer)

        #expect(write(buffer, to: producer, hostTime: 77) == .written)
        let (chunks, samples) = drainSamples(producer)
        #expect(chunks == [CaptureChunk(frameCount: 400, hostTime: 77, gapFrames: 800, droppedBuffers: 2)])
        #expect(samples.count == 400)
        #expect(producer.takePendingDrops() == (0, 0))
    }

    @Test func dropsWhenTheChunkQueueIsFull() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 2, downmix: .average)
        let buffer = makeBuffer(frames: 10) { _, _ in 0 }
        #expect(write(buffer, to: producer) == .written)
        #expect(write(buffer, to: producer) == .written)
        #expect(write(buffer, to: producer) == .dropped)
        #expect(producer.takePendingDrops() == (10, 1))
    }

    @Test func ignoresEmptyBuffersAndEverythingAfterClose() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .average)
        let buffer = makeBuffer(frames: 10) { _, _ in 0 }
        #expect(producer.receive(buffer.audioBufferList, frameCount: 0, hostTime: 0) == .ignored)
        producer.close()
        #expect(producer.isClosed)
        #expect(write(buffer, to: producer) == .ignored)
        #expect(producer.chunks.count == 0)
        // A closed producer doesn't count drops either.
        #expect(producer.takePendingDrops() == (0, 0))
    }

    @Test func sinkReceiverPassesHostTimeOnlyWhenValid() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 8, downmix: .average)
        let receiver = MicrophoneCapture.sinkReceiver(producer: producer)
        let buffer = makeBuffer(frames: 16) { _, _ in 0.5 }

        var valid = AudioTimeStamp()
        valid.mHostTime = 123_456
        valid.mFlags = .hostTimeValid
        var invalid = AudioTimeStamp()
        invalid.mHostTime = 999
        #expect(receiver(&valid, 16, buffer.audioBufferList) == noErr)
        #expect(receiver(&invalid, 16, buffer.audioBufferList) == noErr)

        let chunks = drainSamples(producer).chunks
        #expect(chunks.map(\.hostTime) == [123_456, 0])
    }
}

/// The run-time half of "no allocations on the audio thread": the
/// compile-time half is `@_noLocks` on `CaptureProducer.write`. This counts
/// every heap allocation the calling thread makes (via libmalloc's
/// `malloc_logger` hook) while it plays the audio I/O thread, with the real
/// capture thread draining and resampling concurrently.
@Suite("Capture real-time path allocations", .serialized)
struct CaptureAllocationTests {
    @Test(.enabled(if: AllocationCounter.isAvailable))
    func theCounterSeesAllocations() {
        // Positive control: proves the hook works on this OS, so the zero
        // counts below mean something.
        let count = AllocationCounter.allocations {
            let array = [Int](repeating: 1, count: Int.random(in: 100...200))
            precondition(array.count >= 100)
        }
        #expect((count ?? 0) > 0)
    }

    @Test(.enabled(if: AllocationCounter.isAvailable), .timeLimit(.minutes(1)))
    func sinkReceiverNeverAllocates() async throws {
        let hub = CaptureHub(signposter: .disabled(.audio))
        let producer = CaptureProducer(sampleCapacity: 4_096, chunkCapacity: 64, downmix: .firstChannel)
        let segment = CaptureSegment(producer: producer, inputSampleRate: 48_000)
        segment.start(hub: hub, signposter: .disabled(.audio), after: nil)
        let frames = hub.frames()
        let received = collect(frames)

        let receiver = MicrophoneCapture.sinkReceiver(producer: producer)
        // 20 ms hardware buffers, stereo, as VPIO on some routes delivers.
        let buffer = makeBuffer(frames: 960, channels: 2, fill: sine(frequency: 440, sampleRate: 48_000))
        let bufferList = buffer.audioBufferList
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .hostTimeValid

        // Warm up once outside the measurement (first-call lazy binding).
        _ = receiver(&timestamp, 960, bufferList)

        var allocations = 0
        var written = 1
        for round in 0..<500 {
            timestamp.mHostTime = UInt64(round) * 480_000
            let count = AllocationCounter.allocations {
                // Faster than real time, so the ring fills now and then and
                // the drop path is exercised too. Unrolled: an unoptimized
                // `for` loop in test code allocates its iterator.
                _ = receiver(&timestamp, 960, bufferList)
                _ = receiver(&timestamp, 960, bufferList)
                _ = receiver(&timestamp, 960, bufferList)
                _ = receiver(&timestamp, 960, bufferList)
            }
            allocations += count ?? 0
            written += 4
            if round % 50 == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(allocations == 0)

        segment.close()
        segment.waitUntilFinished()
        hub.finish()
        let samples = await received.value.reduce(0) { $0 + $1.sampleCount }
        let statistics = hub.statistics
        // Every buffer is accounted for: delivered at 16 kHz or dropped.
        let expected = Double(written * 960) / 3
        let accounted = Double(Int64(samples) + statistics.droppedSamples)
        #expect(abs(accounted - expected) <= 4)
        #expect(samples > 0)
    }

    @Test(.enabled(if: AllocationCounter.isAvailable))
    func ringOperationsNeverAllocate() {
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 16, downmix: .average)
        let buffer = makeBuffer(frames: 300, channels: 2, interleaved: true) { frame, _ in Float(frame) }
        let bufferList = buffer.audioBufferList
        _ = producer.write(bufferList, frameCount: 300, hostTime: 1)
        _ = drainSamples(producer)

        var allocations = 0
        for _ in 0..<200 {
            allocations +=
                AllocationCounter.allocations {
                    _ = producer.write(bufferList, frameCount: 300, hostTime: 1)
                    _ = producer.write(bufferList, frameCount: 300, hostTime: 2)
                    _ = producer.write(bufferList, frameCount: 300, hostTime: 3)
                    _ = producer.write(bufferList, frameCount: 300, hostTime: 4)  // dropped: ring full
                } ?? 0
            _ = drainSamples(producer)
        }
        #expect(allocations == 0)
    }
}
