import Accelerate
import BlauCore
import Synchronization
import Testing

@testable import BlauAudio

@Suite struct ConversationAudioScriptTests {
    let script = ConversationAudioScript(conversation: ScriptedConversation(exchanges: 6, exchangesPerTopic: 3))

    @Test func linesAreLaidOutInOrderWithRoomForTheReply() {
        #expect(script.lines.count == 6)
        let timing = ConversationAudioScript.Timing.standard
        #expect(script.lines[0].sampleRange.lowerBound == timing.leadIn.sampleCount(sampleRate: 16_000))
        for (line, next) in zip(script.lines, script.lines.dropFirst()) {
            let gap = next.sampleRange.lowerBound - line.sampleRange.upperBound
            let expected = (timing.responseDelay + line.replyDuration + timing.turnGap).sampleCount(sampleRate: 16_000)
            #expect(gap == expected)
            #expect(line.replyDuration > .seconds(3))
        }
        #expect(script.totalSamples > script.lines.last!.sampleRange.upperBound)
    }

    @Test func wordsAreAlignedInsideTheirLine() {
        for line in script.lines {
            #expect(line.words.map(\.text).joined(separator: " ") == line.text)
            #expect(line.words.last?.end == line.sampleRange.upperBound)
            #expect(line.words.filter(\.endsLine).count == 1)
            #expect(line.words.allSatisfy { line.sampleRange.contains($0.end - 1) })
        }
        #expect(script.words.count == script.lines.reduce(0) { $0 + $1.words.count })
    }

    @Test func speechIsLoudAndTheGapsAreQuiet() {
        let line = script.lines[1]
        let speech = script.samples(in: line.sampleRange)
        let gapStart = line.sampleRange.upperBound + 1_600
        let gap = script.samples(in: gapStart..<(gapStart + 16_000))
        let speechLevel = 20 * log10(vDSP.rootMeanSquare(speech))
        let gapLevel = 20 * log10(vDSP.rootMeanSquare(gap))
        #expect(speechLevel > -25)
        #expect(gapLevel < -50 && gapLevel > -58, "noise floor \(gapLevel) dBFS")
        #expect(script.line(at: line.sampleRange.lowerBound + 10)?.exchange == line.exchange)
        #expect(script.line(at: gapStart) == nil)
    }

    @Test func framesTileTheTimeline() {
        let range: Range<Int64> = 15_000..<(15_000 + 320 * 50)
        var tiled: [Float] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let frame = script.frame(at: offset, length: 320)
            #expect(frame.sampleOffset == offset)
            tiled += frame.samples
            offset = frame.nextSampleOffset
        }
        #expect(tiled == script.samples(in: range))
        // Clamped at both ends.
        #expect(script.samples(in: -100..<0).isEmpty)
        #expect(script.frame(at: script.totalSamples - 100, length: 320).sampleCount == 100)
    }

    @Test func sessionLastsAtLeastTheRequestedDuration() {
        let session = ConversationAudioScript.session(lasting: .seconds(120))
        #expect(session.duration >= .seconds(120))
        #expect(session.duration < .seconds(150))
        #expect(session.lines.count > 6)
        #expect(session.source.hasPrefix("synthetic signal"))
    }

    @Test func feederPlaysEverySampleAndWaitsBeforeEachLine() async throws {
        let hub = CaptureHub()
        let frames = hub.frames()
        let received = Mutex<Int64>(0)
        let collector = Task {
            for await frame in frames { received.withLock { $0 += Int64(frame.sampleCount) } }
            return received.withLock { $0 }
        }
        let calls = Mutex<[(line: Int, position: Int64)]>([])
        let feeder = CaptureReplayFeeder(script: script, speed: nil)
        // Paced by the subscriber, so it never falls far enough behind to
        // lose frames however slow the machine.
        try await feeder.feed(
            into: hub, consumed: { received.withLock { $0 } },
            beforeLine: { line in calls.withLock { $0.append((line, hub.nextSampleOffset)) } })
        hub.finish()

        #expect(await collector.value == script.totalSamples)
        let recorded = calls.withLock { $0 }
        #expect(recorded.map(\.line) == Array(1..<script.lines.count))
        // Called before the line's first sample went out.
        for (line, position) in recorded {
            #expect(position <= script.lines[line].sampleRange.lowerBound)
            #expect(position > script.lines[line].sampleRange.lowerBound - 320)
        }
    }
}
