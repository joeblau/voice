import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauAudio

@Suite("CaptureHub")
struct CaptureHubTests {
    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map { Float($0) }
    }

    private func hub(
        frameLength: Int = 320,
        history: Duration = .seconds(30),
        subscriberBuffer: Duration = .seconds(10),
        signposter: Signposter = .disabled(.audio)
    ) -> CaptureHub {
        CaptureHub(
            configuration: .init(
                frameLength: frameLength, historyDuration: history, subscriberBuffer: subscriberBuffer),
            signposter: signposter
        )
    }

    @Test func standardConfigurationIs20msFramesAnd30sOfHistory() {
        let configuration = CaptureHub.Configuration.standard
        #expect(configuration.frameLength == 320)
        #expect(configuration.historyDuration == .seconds(30))
        #expect(CaptureHub().sampleRate == 16_000)
    }

    @Test func rechunksIntoFixedFramesWithContiguousOffsets() async {
        let hub = hub()
        let frames = collect(hub.frames())
        for size in [100, 500, 7, 333, 960] {
            hub.append(ramp(Int(hub.nextSampleOffset)..<(Int(hub.nextSampleOffset) + size)))
        }
        hub.flush()
        hub.finish()

        let received = await frames.value
        #expect(received.map(\.sampleCount) == [320, 320, 320, 320, 320, 300])
        #expect(received.first?.sampleOffset == 0)
        for (previous, next) in zip(received, received.dropFirst()) {
            #expect(next.sampleOffset == previous.nextSampleOffset)
        }
        #expect(received.flatMap(\.samples) == ramp(0..<1_900))
        #expect(hub.statistics.framesPublished == 6)
        #expect(hub.statistics.samplesPublished == 1_900)
    }

    @Test func framesCarryTheHostTimeOfTheirFirstSample() async {
        let hub = hub()
        let frames = collect(hub.frames())
        let start: UInt64 = 1_000_000_000
        hub.append(ramp(0..<1_000), hostTime: start)
        hub.flush()
        hub.finish()

        let received = await frames.value
        let ticksPerSample = HostTime.ticksPerSecond / 16_000
        for frame in received {
            let expected = start + UInt64((Double(frame.sampleOffset) * ticksPerSample).rounded())
            #expect(frame.hostTime == expected)
        }
    }

    @Test func aFrameSpanningTwoAppendsKeepsItsFirstSamplesTime() async {
        let hub = hub()
        let frames = collect(hub.frames())
        hub.append(ramp(0..<100), hostTime: 5_000)
        hub.append(ramp(100..<640), hostTime: 9_999_999)
        hub.finish()

        let received = await frames.value
        #expect(received.first?.hostTime == 5_000)
        // The second frame starts 220 samples into the second append.
        let ticks = UInt64((220 * HostTime.ticksPerSecond / 16_000).rounded())
        #expect(received.last?.hostTime == 9_999_999 + ticks)
    }

    /// Acceptance: three concurrent consumers receive identical,
    /// sample-accurate streams.
    @Test func threeConsumersReceiveIdenticalStreams() async {
        let hub = hub()
        let consumers = (0..<3).map { _ in collect(hub.frames()) }
        #expect(hub.subscriberCount == 3)

        let total = 16_000 * 3
        var offset = 0
        while offset < total {
            let size = [160, 441, 960, 1_024][offset % 4]
            let end = min(offset + size, total)
            hub.append(ramp(offset..<end), hostTime: UInt64(offset))
            offset = end
        }
        hub.flush()
        hub.finish()

        let streams = await [consumers[0].value, consumers[1].value, consumers[2].value]
        #expect(streams[0] == streams[1])
        #expect(streams[1] == streams[2])
        #expect(streams[0].flatMap(\.samples) == ramp(0..<total))
        #expect(hub.statistics.subscriberDroppedFrames == 0)
    }

    @Test func replaysHistoryContiguousWithLiveFrames() async {
        let hub = hub()
        hub.append(ramp(0..<16_000))
        // Half a second of look-back, then live frames.
        let frames = collect(hub.frames(replaying: .milliseconds(500)))
        hub.append(ramp(16_000..<16_640))
        hub.finish()

        let received = await frames.value
        #expect(received.first?.sampleOffset == 8_000)
        #expect(received.flatMap(\.samples) == ramp(8_000..<16_640))
        for (previous, next) in zip(received, received.dropFirst()) {
            #expect(next.sampleOffset == previous.nextSampleOffset)
        }
        // Replayed frames come from history and have no host time.
        #expect(received.first?.hostTime == nil)
    }

    @Test func historyKeepsTheMostRecentWindow() throws {
        let hub = hub(frameLength: 100, history: .milliseconds(100))  // 1 600 samples
        hub.append(ramp(0..<5_000))
        #expect(hub.historyRange == 3_400..<5_000)

        let recent = try #require(hub.recentHistory(.milliseconds(50)))
        #expect(recent.sampleOffset == 4_200)
        #expect(recent.samples == ramp(4_200..<5_000))

        let clipped = try #require(hub.history(in: 0..<3_500))
        #expect(clipped.sampleOffset == 3_400)
        #expect(clipped.samples == ramp(3_400..<3_500))

        #expect(hub.history(in: 0..<3_000) == nil)
        #expect(hub.history(in: 5_000..<6_000) == nil)
    }

    @Test func aGapMovesOffsetsForwardAndIsCounted() async throws {
        let backend = RecordingSignpostBackend()
        let hub = hub(signposter: Signposter(category: .audio, backend: backend))
        let frames = collect(hub.frames())
        hub.append(ramp(0..<500))
        hub.skip(1_000, droppedBuffers: 2)
        hub.append(ramp(1_500..<1_820))
        hub.flush()
        hub.finish()

        let received = await frames.value
        #expect(received.map(\.sampleOffset) == [0, 320, 1_500])
        #expect(received.map(\.sampleCount) == [320, 180, 320])
        let statistics = hub.statistics
        #expect(statistics.droppedBuffers == 2)
        #expect(statistics.droppedSamples == 1_000)
        #expect(statistics.gaps == 1)
        #expect(statistics.droppedFrames(frameLength: 320) == 4)
        #expect(backend.events == ["capture.drop"])

        // The lost audio reads back as silence, so offsets stay valid.
        let around = try #require(hub.history(in: 400..<1_600))
        #expect(around.samples[0..<100] == ramp(400..<500)[...])
        #expect(around.samples[100..<1_100].allSatisfy { $0 == 0 })
        #expect(around.samples[1_100...] == ramp(1_500..<1_600)[...])
    }

    @Test func aSlowSubscriberLosesItsOldestFramesWithoutSlowingOthers() async {
        let hub = hub(subscriberBuffer: .milliseconds(40))  // two frames
        let slow = hub.frames()
        var fast = hub.frames().makeAsyncIterator()
        var fastFrames: [AudioFrame] = []
        // Ten frames; `fast` keeps up, nobody reads `slow`.
        for index in 0..<10 {
            hub.append(ramp((index * 320)..<((index + 1) * 320)))
            if let frame = await fast.next() {
                fastFrames.append(frame)
            }
        }
        hub.finish()

        var slowFrames: [AudioFrame] = []
        for await frame in slow {
            slowFrames.append(frame)
        }
        #expect(slowFrames.map(\.sampleOffset) == [2_560, 2_880])
        #expect(fastFrames.count == 10)
        #expect(hub.statistics.subscriberDroppedFrames == 8)
    }

    @Test func levelsFollowTheAudio() async throws {
        let hub = hub()
        var levels = hub.levels().makeAsyncIterator()
        hub.append([Float](repeating: 0.5, count: 320))
        let level = try #require(await levels.next())
        #expect(abs(level.rms - 0.5) < 1e-6)
        #expect(level.peak == 0.5)
        #expect(level.sampleOffset == 0)
        #expect(abs(level.rmsDecibels - -6.0206) < 0.001)
    }

    @Test func finishEndsStreamsAndLaterSubscriptions() async {
        let hub = hub()
        let before = collect(hub.frames())
        let levels = collect(hub.levels())
        hub.finish()
        #expect(await before.value.isEmpty)
        #expect(await levels.value.isEmpty)
        #expect(hub.subscriberCount == 0)

        let after = collect(hub.frames())
        hub.append(ramp(0..<640))
        #expect(await after.value.isEmpty)
        // History still records.
        #expect(hub.historyRange == 0..<640)
    }

    @Test func cancellingAConsumerUnsubscribes() async {
        let hub = hub()
        let consumer = Task {
            for await _ in hub.frames() {}
        }
        while hub.subscriberCount == 0 {
            await Task.yield()
        }
        consumer.cancel()
        await consumer.value
        while hub.subscriberCount > 0 {
            await Task.yield()
        }
        #expect(hub.subscriberCount == 0)
    }
}

@Suite("AudioLevel")
struct AudioLevelTests {
    @Test func decibelsAndMeterMapping() {
        let silence = AudioLevel(rms: 0, peak: 0, sampleOffset: 0)
        #expect(silence.rmsDecibels == AudioLevel.floorDecibels)
        #expect(silence.normalized() == 0)

        let fullScale = AudioLevel(rms: 1, peak: 1, sampleOffset: 0)
        #expect(fullScale.rmsDecibels == 0)
        #expect(fullScale.normalized() == 1)

        let quiet = AudioLevel(rms: 0.001, peak: 0.01, sampleOffset: 0)  // -60 dBFS
        #expect(abs(quiet.rmsDecibels - -60) < 0.001)
        #expect(abs(quiet.normalized(floor: -60)) < 0.001)
        #expect(abs(quiet.normalized(floor: -80) - 0.25) < 0.001)
        #expect(abs(quiet.peakDecibels - -40) < 0.001)
    }
}

@Suite("AudioHistory")
struct AudioHistoryTests {
    @Test func wrapsAndReadsAcrossTheSeam() throws {
        var history = AudioHistory(capacity: 5)
        history.append([0, 1, 2])
        history.append([3, 4, 5, 6])
        #expect(history.range == 2..<7)
        let read = try #require(history.samples(in: 0..<100))
        #expect(read.offset == 2)
        #expect(read.samples == [2, 3, 4, 5, 6])
        #expect(history.samples(in: 4..<6)?.samples == [4, 5])
    }

    @Test func anAppendLargerThanTheCapacityKeepsItsTail() {
        var history = AudioHistory(capacity: 3)
        history.append([0, 1, 2, 3, 4, 5, 6])
        #expect(history.range == 4..<7)
        #expect(history.samples(in: 0..<7)?.samples == [4, 5, 6])
    }

    @Test func silenceKeepsOffsetsAligned() {
        var history = AudioHistory(capacity: 4)
        history.append([1, 2])
        history.appendSilence(1)
        history.append([3])
        #expect(history.samples(in: 0..<4)?.samples == [1, 2, 0, 3])
        // A gap longer than the history clears it.
        history.appendSilence(10)
        #expect(history.range == 14..<14)
        #expect(history.samples(in: 0..<20) == nil)
        history.append([9])
        #expect(history.samples(in: 0..<20)?.offset == 14)
    }
}
