import AVFAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauAudio

/// The capture path from the audio thread's producer, through the capture
/// thread's resampling, to the hub's subscribers.
@Suite("Capture pipeline")
struct CapturePipelineTests {
    private let disabled = Signposter.disabled(.audio)

    // MARK: Consumer, driven synchronously

    @Test func sixteenKilohertzInputArrivesSampleForSample() throws {
        let hub = CaptureHub(signposter: disabled)
        let producer = CaptureProducer(sampleCapacity: 8_192, chunkCapacity: 32, downmix: .average)
        let consumer = try CaptureConsumer(producer: producer, hub: hub, inputSampleRate: 16_000, signposter: disabled)

        var next = 0
        for size in [320, 160, 999, 1] {
            let start = next
            write(makeBuffer(frames: size, sampleRate: 16_000) { frame, _ in Float(start + frame) }, to: producer)
            next += size
        }
        consumer.drain()
        producer.close()
        consumer.finish()

        let audio = try #require(hub.history(in: 0..<Int64(next)))
        #expect(audio.samples == (0..<next).map(Float.init))
        #expect(hub.nextSampleOffset == Int64(next))
    }

    @Test func eachChunkIsOneCaptureFrameInterval() throws {
        let backend = RecordingSignpostBackend()
        let signposter = Signposter(category: .audio, backend: backend)
        let hub = CaptureHub(signposter: signposter)
        let producer = CaptureProducer(sampleCapacity: 8_192, chunkCapacity: 32, downmix: .average)
        let consumer = try CaptureConsumer(
            producer: producer, hub: hub, inputSampleRate: 48_000, signposter: signposter)
        let buffer = makeBuffer(frames: 960, fill: sine(frequency: 440, sampleRate: 48_000))
        for _ in 0..<5 {
            write(buffer, to: producer)
        }
        #expect(consumer.drain() == 5)
        #expect(backend.completedIntervals == Array(repeating: "capture.frame", count: 5))
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func hostTimesFollowTheHardwareTimestamps() async throws {
        let hub = CaptureHub(signposter: disabled)
        let frames = collect(hub.frames())
        let producer = CaptureProducer(sampleCapacity: 8_192, chunkCapacity: 32, downmix: .average)
        let consumer = try CaptureConsumer(producer: producer, hub: hub, inputSampleRate: 16_000, signposter: disabled)
        let ticksPer20ms = UInt64((0.02 * HostTime.ticksPerSecond).rounded())
        let start: UInt64 = 10_000_000
        for index in 0..<3 {
            // Hardware clock running slightly fast: each buffer's own
            // timestamp wins over extrapolation.
            write(
                makeBuffer(frames: 320, sampleRate: 16_000) { _, _ in 0 },
                to: producer,
                hostTime: start + UInt64(index) * (ticksPer20ms + 7)
            )
        }
        consumer.drain()
        producer.close()
        consumer.finish()
        hub.finish()

        let received = await frames.value
        #expect(received.map(\.hostTime) == (0..<3).map { start + UInt64($0) * (ticksPer20ms + 7) })
    }

    @Test func dropsLeaveAGapAlignedWithRealTime() async throws {
        let backend = RecordingSignpostBackend()
        let signposter = Signposter(category: .audio, backend: backend)
        let hub = CaptureHub(signposter: signposter)
        let frames = collect(hub.frames())
        // Room for two 20 ms buffers at 48 kHz.
        let producer = CaptureProducer(sampleCapacity: 2_048, chunkCapacity: 32, downmix: .average)
        let consumer = try CaptureConsumer(
            producer: producer, hub: hub, inputSampleRate: 48_000, signposter: signposter)
        let buffer = makeBuffer(frames: 960, fill: sine(frequency: 440, sampleRate: 48_000))

        #expect(write(buffer, to: producer) == .written)
        #expect(write(buffer, to: producer) == .written)
        #expect(write(buffer, to: producer) == .dropped)  // the capture thread "stalled"
        #expect(write(buffer, to: producer) == .dropped)
        consumer.drain()
        #expect(write(buffer, to: producer) == .written)
        consumer.drain()
        producer.close()
        consumer.finish()
        hub.finish()

        let statistics = hub.statistics
        #expect(statistics.droppedBuffers == 2)
        #expect(statistics.gaps == 1)
        // The audio after the drop starts where it belongs in real time: two
        // buffers kept plus two dropped is 80 ms, sample 1 280 at 16 kHz.
        let received = await frames.value
        let afterGap = try #require(received.last { $0.sampleOffset >= 1_280 })
        #expect(received.contains { $0.sampleOffset == 1_280 })
        #expect(afterGap.nextSampleOffset == hub.nextSampleOffset)
        #expect(abs(hub.nextSampleOffset - 1_600) <= 2)
        #expect(abs(Int(statistics.samplesPublished) + Int(statistics.droppedSamples) - 1_600) <= 2)
        #expect(backend.events == ["capture.drop"])
    }

    @Test func dropsAfterTheLastBufferAreReportedOnFinish() throws {
        let hub = CaptureHub(signposter: disabled)
        let producer = CaptureProducer(sampleCapacity: 1_024, chunkCapacity: 32, downmix: .average)
        let consumer = try CaptureConsumer(producer: producer, hub: hub, inputSampleRate: 16_000, signposter: disabled)
        let buffer = makeBuffer(frames: 1_000, sampleRate: 16_000) { _, _ in 0.1 }
        write(buffer, to: producer)
        #expect(write(buffer, to: producer) == .dropped)
        producer.close()
        consumer.finish()

        #expect(hub.statistics.droppedBuffers == 1)
        #expect(hub.statistics.droppedSamples == 1_000)
        #expect(hub.nextSampleOffset == 2_000)
    }

    // MARK: Threads

    /// Acceptance: three concurrent consumers receive identical,
    /// sample-accurate streams. A feeder thread plays the audio I/O thread
    /// (20 ms buffers at 48 kHz), the real capture thread resamples, and
    /// three tasks consume concurrently.
    @Test(.timeLimit(.minutes(1)))
    func threeConcurrentConsumersGetIdenticalSampleAccurateStreams() async throws {
        let hub = CaptureHub(signposter: disabled)
        let consumers = (0..<3).map { _ in collect(hub.frames()) }
        let producer = CaptureProducer(sampleCapacity: 96_000, chunkCapacity: 256, downmix: .firstChannel)
        let segment = CaptureSegment(producer: producer, inputSampleRate: 48_000)
        segment.start(hub: hub, signposter: disabled, after: nil)

        let seconds = 3
        let signal = sine(frequency: 523.25, sampleRate: 48_000)
        let input = (0..<(48_000 * seconds)).map(signal)
        let ticksPerBuffer = UInt64((0.02 * HostTime.ticksPerSecond).rounded())
        let feeder = Thread {
            for index in 0..<(input.count / 960) {
                let buffer = makeBuffer(frames: 960, channels: 2) { frame, channel in
                    channel == 0 ? input[index * 960 + frame] : 0.9
                }
                while write(buffer, to: producer, hostTime: 1_000_000 + UInt64(index) * ticksPerBuffer) == .dropped {
                    // Never happens with this ring size; keep the test honest if it does.
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if index % 10 == 0 {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            segment.close()
        }
        feeder.start()
        await Task.detached { segment.waitUntilFinished() }.value
        hub.finish()

        let streams = await [consumers[0].value, consumers[1].value, consumers[2].value]
        #expect(streams[0] == streams[1])
        #expect(streams[1] == streams[2])

        let frames = streams[0]
        #expect(frames.first?.sampleOffset == 0)
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(next.sampleOffset == previous.nextSampleOffset)
            #expect(previous.sampleCount == 320)
        }
        #expect(frames.allSatisfy { $0.sampleRate == 16_000 && $0.hostTime != nil })

        // Sample accurate: streaming through the ring and the capture thread
        // gives the same samples as converting the whole signal at once.
        let streamed = frames.flatMap(\.samples)
        let reference = try CaptureResampler(inputSampleRate: 48_000)
        var expected: [Float] = []
        try input.withUnsafeBufferPointer { try reference.process($0) { expected += $0 } }
        try reference.flush { expected += $0 }
        #expect(streamed.count == expected.count)
        let maxDifference = zip(streamed, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDifference < 1e-5)
        #expect(abs(streamed.count - 16_000 * seconds) <= 2)
        #expect(hub.statistics.droppedBuffers == 0)
        #expect(hub.statistics.subscriberDroppedFrames == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func segmentsFollowEachOtherAcrossAFormatChange() async throws {
        let hub = CaptureHub(signposter: disabled)
        let frames = collect(hub.frames())

        // Built-in speaker at 48 kHz, then AirPods (HFP) at 16 kHz.
        let first = CaptureSegment(
            producer: CaptureProducer(sampleCapacity: 65_536, chunkCapacity: 128, downmix: .firstChannel),
            inputSampleRate: 48_000
        )
        let second = CaptureSegment(
            producer: CaptureProducer(sampleCapacity: 16_384, chunkCapacity: 128, downmix: .firstChannel),
            inputSampleRate: 16_000
        )
        first.start(hub: hub, signposter: disabled, after: nil)
        let speaker = makeBuffer(frames: 960, fill: sine(frequency: 440, sampleRate: 48_000))
        for _ in 0..<50 {
            write(speaker, to: first.producer)
        }
        // The second segment starts before the first has drained; it must
        // wait its turn.
        second.start(hub: hub, signposter: disabled, after: first)
        let headset = makeBuffer(frames: 320, sampleRate: 16_000) { frame, _ in Float(frame) / 320 }
        for _ in 0..<50 {
            write(headset, to: second.producer)
        }
        first.close()
        second.close()
        await Task.detached { second.waitUntilFinished() }.value
        hub.finish()

        let received = await frames.value
        for (previous, next) in zip(received, received.dropFirst()) {
            #expect(next.sampleOffset == previous.nextSampleOffset)
        }
        #expect(abs(hub.nextSampleOffset - 32_000) <= 2)
        #expect(hub.statistics.segments == 2)
        // The headset audio is last and unchanged (pass-through).
        let tail = Array(received.flatMap(\.samples).suffix(16_000))
        #expect(tail == Array((0..<50).flatMap { _ in (0..<320).map { Float($0) / 320 } }))
    }
}
