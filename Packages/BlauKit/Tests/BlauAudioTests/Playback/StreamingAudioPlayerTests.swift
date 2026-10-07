import AVFAudio
import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

/// The jitter buffer, item bookkeeping, flush, levels and telemetry, cycle
/// by cycle.
@Suite("StreamingAudioPlayer", .timeLimit(.minutes(1)))
struct StreamingAudioPlayerTests {
    static let itemA = PlaybackItemID(itemID: "item_a")
    static let itemB = PlaybackItemID(itemID: "item_b")

    final class Harness {
        let clock = ManualClock()
        let signposts = RecordingSignpostBackend()
        let player: StreamingAudioPlayer

        init(configuration: PlaybackConfiguration = .realtime) {
            player = StreamingAudioPlayer(
                configuration: configuration,
                clock: clock,
                signposter: Signposter(category: .audio, backend: signposts)
            )
        }

        /// Renders one cycle of `frames` and returns it.
        @discardableResult
        func render(_ frames: Int = 480) -> [Float] {
            var cycle = [Float](repeating: .nan, count: frames)
            cycle.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
            return cycle
        }

        /// `milliseconds` of a constant non-zero signal (24 kHz).
        static func audio(milliseconds: Int, value: Float = 0.25) -> [Float] {
            [Float](repeating: value, count: milliseconds * 24)
        }
    }

    // MARK: Jitter buffer

    @Test func idleRendersSilence() {
        let harness = Harness()
        #expect(harness.render().allSatisfy { $0 == 0 })
        #expect(harness.player.snapshot.state == .idle)
        #expect(harness.player.snapshot.level == .silent)
        #expect(harness.player.snapshot.renderedFrames == 480)
    }

    @Test func waitsForOneHundredTwentyMillisecondsBeforePlaying() {
        let harness = Harness()
        let player = harness.player
        player.enqueue(samples: Harness.audio(milliseconds: 100), item: Self.itemA)
        #expect(player.snapshot.state == .buffering)
        #expect(player.snapshot.isSpeaking == false)
        #expect(harness.render().allSatisfy { $0 == 0 })
        #expect(player.playedItem(for: Self.itemA)?.playedFrames == 0)

        player.enqueue(samples: Harness.audio(milliseconds: 20), item: Self.itemA)
        #expect(harness.render().allSatisfy { $0 == 0.25 })
        #expect(player.snapshot.state == .playing)
        #expect(player.snapshot.isSpeaking)
        #expect(player.snapshot.currentItem == Self.itemA)
        #expect(player.snapshot.bufferedDuration == .milliseconds(100))
    }

    @Test func aShortFinishedItemPlaysWithoutWaitingForThePreroll() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 30), item: Self.itemA)
        harness.player.finish(Self.itemA)
        let cycle = harness.render()
        #expect(cycle.allSatisfy { $0 == 0.25 })  // 480 of the 720 frames
        let tail = harness.render()
        #expect(tail.prefix(240).allSatisfy { $0 == 0.25 })
        #expect(tail.dropFirst(240).allSatisfy { $0 == 0 })
        #expect(harness.player.snapshot.state == .idle)
        #expect(harness.player.snapshot.underrunCount == 0)
        #expect(harness.player.playedItem(for: Self.itemA)?.playedMilliseconds == 30)
    }

    @Test func aTrickleStartsAfterTheMaximumPrerollWait() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 40), item: Self.itemA)
        // 300 ms of waiting (15 cycles of 20 ms) with 40 ms queued.
        for _ in 0..<15 {
            #expect(harness.render().allSatisfy { $0 == 0 })
        }
        #expect(harness.render().prefix(480).allSatisfy { $0 == 0.25 })
    }

    @Test func underrunRendersSilenceAndRebuffers() {
        let harness = Harness()
        let player = harness.player
        player.enqueue(samples: Harness.audio(milliseconds: 130), item: Self.itemA)
        for _ in 0..<6 { harness.render() }  // 120 ms played
        let dry = harness.render()  // 10 ms of audio, then dry
        #expect(dry.prefix(240).allSatisfy { $0 == 0.25 })
        #expect(dry.dropFirst(240).allSatisfy { $0 == 0 })
        #expect(player.snapshot.underrunCount == 1)
        #expect(player.snapshot.state == .buffering)

        // Late audio doesn't play until the buffer is primed again.
        player.enqueue(samples: Harness.audio(milliseconds: 60, value: 0.5), item: Self.itemA)
        #expect(harness.render().allSatisfy { $0 == 0 })
        player.enqueue(samples: Harness.audio(milliseconds: 60, value: 0.5), item: Self.itemA)
        #expect(harness.render().allSatisfy { $0 == 0.5 })
        #expect(player.playedItem(for: Self.itemA)?.playedMilliseconds == 150)
    }

    @Test func runningDryAfterFinishIsTheEndOfSpeechNotAnUnderrun() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 150), item: Self.itemA)
        harness.player.finish(Self.itemA)
        for _ in 0..<10 { harness.render() }
        #expect(harness.player.snapshot.state == .idle)
        #expect(harness.player.snapshot.underrunCount == 0)
        #expect(harness.player.snapshot.currentItem == nil)
    }

    @Test func consecutiveItemsPlayBackToBackAndAreCountedSeparately() {
        let harness = Harness()
        let player = harness.player
        player.enqueue(samples: Harness.audio(milliseconds: 130, value: 0.25), item: Self.itemA)
        player.finish(Self.itemA)
        player.enqueue(samples: Harness.audio(milliseconds: 50, value: 0.5), item: Self.itemB)
        player.finish(Self.itemB)

        var output: [Float] = []
        for _ in 0..<10 { output += harness.render() }
        #expect(Array(output.prefix(130 * 24)).allSatisfy { $0 == 0.25 })
        #expect(Array(output[(130 * 24)..<(180 * 24)]).allSatisfy { $0 == 0.5 })
        #expect(output.dropFirst(180 * 24).allSatisfy { $0 == 0 })
        #expect(player.playedItem(for: Self.itemA)?.playedMilliseconds == 130)
        #expect(player.playedItem(for: Self.itemB)?.playedMilliseconds == 50)
    }

    @Test func aNewResponseAfterSilenceGetsItsOwnPreroll() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 20), item: Self.itemA)
        harness.player.finish(Self.itemA)
        harness.render()
        harness.render()
        #expect(harness.player.snapshot.state == .idle)

        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemB)
        #expect(harness.player.snapshot.state == .buffering)
        #expect(harness.render().allSatisfy { $0 == 0 })
    }

    // MARK: Flush

    @Test func flushReportsWhatWasPlayedAndDropsTheRest() {
        let harness = Harness()
        let player = harness.player
        player.enqueue(samples: Harness.audio(milliseconds: 500), item: Self.itemA)
        for _ in 0..<10 { harness.render() }  // 200 ms

        let result = player.flush()
        #expect(result.interrupted.count == 1)
        let cut = result.current
        #expect(cut?.id == Self.itemA)
        // 200 ms played plus the 5 ms fade the next cycle renders.
        #expect(cut?.playedMilliseconds == 205)
        #expect(cut?.receivedFrames == Int64(500 * 24))
        #expect(result.droppedDuration == .milliseconds(295))

        let next = harness.render()
        #expect(next.prefix(120).allSatisfy { $0 > 0 && $0 < 0.25 })
        #expect(next.dropFirst(120).allSatisfy { $0 == 0 })
        #expect(harness.render().allSatisfy { $0 == 0 })
        #expect(player.playedItem(for: Self.itemA)?.playedMilliseconds == 205)
    }

    @Test func lateDeltasForAFlushedItemAreDropped() {
        let harness = Harness()
        let player = harness.player
        player.enqueue(samples: Harness.audio(milliseconds: 200), item: Self.itemA)
        for _ in 0..<7 { harness.render() }
        player.flush()

        #expect(player.enqueue(samples: Harness.audio(milliseconds: 200), item: Self.itemA) == .droppedStaleItem)
        #expect(player.snapshot.state == .idle)
        #expect(player.snapshot.bufferedDuration == .zero)

        // The next response plays normally.
        #expect(player.enqueue(samples: Harness.audio(milliseconds: 200, value: 0.5), item: Self.itemB) == .queued)
        harness.render()  // fade of item A
        #expect(harness.render().allSatisfy { $0 == 0.5 })
    }

    @Test func flushWhileBufferingHasNoFadeAndReportsZeroPlayed() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemA)
        let result = harness.player.flush()
        #expect(result.current?.playedFrames == 0)
        #expect(result.current?.playedMilliseconds == 0)
        #expect(harness.render().allSatisfy { $0 == 0 })
    }

    @Test func flushDuringAnUnderrunStillReportsTheStreamingItem() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 120), item: Self.itemA)
        for _ in 0..<7 { harness.render() }
        #expect(harness.player.snapshot.state == .buffering)
        let result = harness.player.flush()
        #expect(result.current?.id == Self.itemA)
        #expect(result.current?.playedMilliseconds == 120)
        #expect(result.droppedDuration == .zero)
    }

    @Test func flushAfterTheAgentFinishedSpeakingInterruptsNothing() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 40), item: Self.itemA)
        harness.player.finish(Self.itemA)
        for _ in 0..<3 { harness.render() }
        #expect(harness.player.flush().interrupted.isEmpty)
    }

    @Test func flushWithoutFadeCutsHard() {
        var configuration = PlaybackConfiguration.realtime
        configuration.flushFadeDuration = .zero
        let harness = Harness(configuration: configuration)
        harness.player.enqueue(samples: Harness.audio(milliseconds: 300), item: Self.itemA)
        for _ in 0..<7 { harness.render() }
        #expect(harness.player.flush().current?.playedMilliseconds == 140)
        #expect(harness.render().allSatisfy { $0 == 0 })
    }

    @Test func flushedItemsQueuedBehindTheCurrentOneAreReportedInOrder() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 200), item: Self.itemA)
        harness.player.finish(Self.itemA)
        harness.player.enqueue(samples: Harness.audio(milliseconds: 200), item: Self.itemB)
        for _ in 0..<3 { harness.render() }
        let result = harness.player.flush()
        #expect(result.interrupted.map(\.id) == [Self.itemA, Self.itemB])
        #expect(result.interrupted.map(\.playedMilliseconds) == [65, 0])
    }

    // MARK: Bookkeeping

    @Test func decodesBase64AndBinaryDeltas() throws {
        let harness = Harness()
        let pcm = [Int16](repeating: 8_192, count: 24 * 150)
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(
            try harness.player.enqueue(base64: data.prefix(1_001).base64EncodedString(), item: Self.itemA) == .queued)
        #expect(harness.player.enqueue(pcm16: data.dropFirst(1_001), item: Self.itemA) == .queued)
        #expect(harness.render().allSatisfy { $0 == 0.25 })
        #expect(throws: PlaybackError.invalidBase64) {
            try harness.player.enqueue(base64: "%%%", item: Self.itemA)
        }
        #expect(harness.player.enqueue(pcm16: Data(), item: Self.itemA) == .empty)
    }

    @Test func historyKeepsTheMostRecentItems() {
        var configuration = PlaybackConfiguration.realtime
        configuration.itemHistoryCapacity = 2
        let harness = Harness(configuration: configuration)
        for index in 0..<3 {
            let item = PlaybackItemID(itemID: "item_\(index)")
            harness.player.enqueue(samples: Harness.audio(milliseconds: 10), item: item)
            harness.player.finish(item)
            harness.render()
        }
        #expect(harness.player.playedItem(for: PlaybackItemID(itemID: "item_0")) == nil)
        #expect(harness.player.playedItem(for: PlaybackItemID(itemID: "item_2"))?.playedMilliseconds == 10)
    }

    @Test func contentIndexSeparatesItems() {
        let harness = Harness()
        let second = PlaybackItemID(itemID: "item_a", contentIndex: 1)
        harness.player.enqueue(samples: Harness.audio(milliseconds: 10), item: Self.itemA)
        harness.player.finish(Self.itemA)
        harness.player.enqueue(samples: Harness.audio(milliseconds: 20), item: second)
        harness.player.finish(second)
        harness.render(720)
        #expect(harness.player.playedItem(for: Self.itemA)?.playedMilliseconds == 10)
        #expect(harness.player.playedItem(for: second)?.playedMilliseconds == 20)
        #expect(second.description == "item_a#1")
    }

    // MARK: Level and updates

    @Test func levelFollowsTheRenderedAudio() {
        let harness = Harness()
        var samples = Harness.audio(milliseconds: 200, value: 0.5)
        for index in stride(from: 1, to: samples.count, by: 2) { samples[index] = -0.5 }
        harness.player.enqueue(samples: samples, item: Self.itemA)
        harness.render()
        let level = harness.player.snapshot.level
        #expect(abs(level.rms - 0.5) < 1e-6)
        #expect(level.peak == 0.5)
        #expect(abs(level.decibels() - -6.0206) < 0.001)
        harness.player.flush()
        #expect(harness.player.snapshot.level == .silent)
        harness.render()
        harness.render()
        #expect(harness.player.snapshot.level == .silent)
        #expect(PlaybackLevel.silent.decibels() == -80)
    }

    @Test func updatesPublishTheSpeakingStateOnTheClock() async {
        let harness = Harness()
        var iterator = harness.player.updates(every: .milliseconds(50)).makeAsyncIterator()
        #expect(await iterator.next()?.state == .idle)

        harness.player.enqueue(samples: Harness.audio(milliseconds: 300), item: Self.itemA)
        harness.render()
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .milliseconds(50))
        let speaking = await iterator.next()
        #expect(speaking?.state == .playing)
        #expect(speaking?.isSpeaking == true)
        #expect((speaking?.level.rms ?? 0) > 0)

        harness.player.flush()
        harness.render()
        harness.render()
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .milliseconds(50))
        let quiet = await iterator.next()
        #expect(quiet?.state == .idle)
        #expect(quiet?.level == .silent)
    }

    // MARK: Telemetry

    @Test func firstBufferSignpostSpansEnqueueToFirstRenderedFrame() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemA)
        #expect(harness.signposts.openIntervals == ["playback.firstBuffer"])
        harness.render()
        #expect(harness.signposts.openIntervals == ["playback.firstBuffer"])  // still buffering
        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemA)
        harness.render()
        #expect(harness.signposts.openIntervals.isEmpty)
        #expect(harness.signposts.completedIntervals == ["playback.firstBuffer"])

        // One per item.
        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemA)
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func firstBufferSignpostEndsWhenFlushedBeforePlaying() {
        let harness = Harness()
        harness.player.enqueue(samples: Harness.audio(milliseconds: 60), item: Self.itemA)
        harness.player.flush()
        #expect(harness.signposts.openIntervals.isEmpty)
        #expect(harness.signposts.completedIntervals == ["playback.firstBuffer"])
    }

    @Test func configurationDefaultsMatchTheRealtimeStream() {
        let configuration = PlaybackConfiguration.realtime
        #expect(configuration.sampleRate == 24_000)
        #expect(configuration.prerollDuration == .milliseconds(120))
        #expect(configuration.flushFadeDuration == .milliseconds(5))
        let format = StreamingAudioPlayer().makeFormat()
        #expect(format.sampleRate == 24_000)
        #expect(format.channelCount == 2)
        #expect(!format.isInterleaved)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }
}
