import BlauCore
import Testing

@testable import BlauTranscription

/// The segmentation rules on synthetic chunks: 4096-sample chunks of 16
/// subframes, each subframe either voiced (-20 dBFS) or room tone
/// (-60 dBFS).
@Suite("Speech segmentation state machine")
struct SpeechSegmentationStateMachineTests {
    typealias Machine = SpeechSegmentationStateMachine

    static let chunk: Int64 = 4_096
    static let subframe: Int64 = 256
    static let speech: Float = 0.95
    static let silence: Float = 0.02

    /// A script of chunks: per chunk, a probability and which of its 16
    /// subframes are voiced.
    struct Script {
        var chunks: [(probability: Float, voiced: Set<Int>)] = []

        mutating func silence(_ count: Int) {
            chunks += Array(repeating: (SpeechSegmentationStateMachineTests.silence, []), count: count)
        }

        mutating func speech(_ count: Int) {
            chunks += Array(repeating: (SpeechSegmentationStateMachineTests.speech, Set(0..<16)), count: count)
        }

        mutating func chunk(_ probability: Float, voiced: Range<Int>) {
            chunks.append((probability, Set(voiced)))
        }

        func run(
            _ configuration: VoiceActivityConfiguration = .standard,
            startingAt start: Int64 = 0,
            finish: Bool = true
        ) -> (events: [VoiceActivityEvent], machine: Machine) {
            var machine = Machine(configuration: configuration)
            machine.begin(at: start)
            var events: [VoiceActivityEvent] = []
            for (index, chunk) in chunks.enumerated() {
                let levels = (0..<16).map { chunk.voiced.contains($0) ? Float(-20) : Float(-60) }
                events += machine.process(
                    .init(
                        startOffset: start + Int64(index) * SpeechSegmentationStateMachineTests.chunk,
                        sampleCount: 4_096,
                        probability: chunk.probability,
                        levels: levels
                    )
                )
            }
            if finish {
                events += machine.finish(at: machine.processedEnd)
            }
            return (events, machine)
        }
    }

    static func segments(_ events: [VoiceActivityEvent]) -> [SpeechSegment] {
        events.compactMap { if case .speechEnded(let segment) = $0 { segment } else { nil } }
    }

    static func onsets(_ events: [VoiceActivityEvent]) -> [SpeechOnset] {
        events.compactMap { if case .speechStarted(let onset) = $0 { onset } else { nil } }
    }

    /// Offset of subframe `subframe` of chunk `chunk`.
    static func at(_ chunk: Int, _ subframe: Int = 0) -> Int64 {
        Int64(chunk) * Self.chunk + Int64(subframe) * Self.subframe
    }

    static let pad = Int64(480)  // 30 ms

    @Test func silenceProducesNothing() {
        var script = Script()
        script.silence(40)
        let (events, machine) = script.run()
        #expect(events.isEmpty)
        #expect(machine.noiseFloor == -60)
        #expect(machine.energyThreshold == -54)
    }

    @Test func boundariesAreRefinedInsideTheChunks() throws {
        var script = Script()
        script.silence(4)
        script.chunk(Self.speech, voiced: 5..<16)  // speech starts at subframe 5 of chunk 4
        script.speech(3)
        script.chunk(Self.speech, voiced: 0..<9)  // and ends after subframe 8 of chunk 8
        script.silence(4)
        let (events, _) = script.run()

        let segment = try #require(Self.segments(events).first)
        #expect(Self.segments(events).count == 1)
        #expect(segment.sampleRange == (Self.at(4, 5) - Self.pad)..<(Self.at(8, 9) + Self.pad))
        #expect(segment.endReason == .silence)
        #expect(!segment.isContinuation)
        #expect(segment.peakProbability == Self.speech)

        let onset = try #require(Self.onsets(events).first)
        #expect(onset.segmentID == segment.id)
        #expect(onset.startOffset == segment.sampleRange.lowerBound)
        // 11 voiced subframes (176 ms) in the first chunk are not enough:
        // confirmed at the end of the second.
        #expect(onset.detectedAt == Self.at(6))
        // Ended once 300 ms of silence followed the last voiced subframe.
        #expect(segment.detectedAt == Self.at(10))
        #expect(events.first == .speechStarted(onset))
    }

    @Test func onsetLooksBackIntoTheChunkBeforeTheTrigger() throws {
        var script = Script()
        script.silence(4)
        script.chunk(0.3, voiced: 12..<16)  // speech begins, model not yet sure
        script.speech(3)
        script.silence(4)
        let (events, _) = script.run()
        let segment = try #require(Self.segments(events).first)
        #expect(segment.sampleRange.lowerBound == Self.at(4, 12) - Self.pad)
    }

    @Test func onsetLookBackBridgesShortGapsButStopsAtLongOnes() throws {
        var script = Script()
        script.silence(4)
        // A click at subframe 2, a long gap, then speech from subframe 10;
        // the model triggers on the next chunk.
        script.chunks.append((0.2, Set([2]).union(10..<16)))
        script.speech(3)
        script.silence(4)
        let (events, _) = script.run()
        let segment = try #require(Self.segments(events).first)
        // Seven quiet subframes (112 ms) between the click and the speech:
        // more than the 80 ms bridged.
        #expect(segment.sampleRange.lowerBound == Self.at(4, 10) - Self.pad)
    }

    @Test func burstsShorterThanTheMinimumAreDropped() {
        var script = Script()
        script.silence(4)
        script.chunk(Self.speech, voiced: 6..<14)  // 8 subframes: 128 ms
        script.silence(6)
        let (events, machine) = script.run()
        #expect(events.isEmpty)
        #expect(machine.counters.rejectedCandidates == 1)
        #expect(machine.counters.segments == 0)
    }

    @Test func aBurstThatReachesTheMinimumIsKept() throws {
        var script = Script()
        script.silence(4)
        script.chunk(Self.speech, voiced: 0..<16)  // 256 ms
        script.silence(4)
        let (events, _) = script.run()
        let segment = try #require(Self.segments(events).first)
        #expect(segment.sampleRange == (Self.at(4) - Self.pad)..<(Self.at(5) + Self.pad))
    }

    @Test func pausesShorterThanTheHangoverStayInOneSegment() {
        var script = Script()
        script.silence(4)
        script.speech(2)
        script.chunk(Self.speech, voiced: 0..<4)  // a pause from subframe 4 ...
        script.chunk(Self.silence, voiced: 0..<0)
        script.speech(3)  // ... to here: 12 + 16 subframes, 448 ms
        script.silence(4)
        // Longer than the 300 ms hangover: two segments.
        #expect(Self.segments(script.run().events).count == 2)

        var short = Script()
        short.silence(4)
        short.speech(2)
        short.chunk(Self.speech, voiced: 0..<12)  // 4 quiet subframes ...
        short.chunk(Self.speech, voiced: 8..<16)  // ... and 8 more: 192 ms, then speech again
        short.speech(2)
        short.silence(4)
        let segments = Self.segments(short.run().events)
        #expect(segments.count == 1)
        #expect(segments.first?.sampleRange == (Self.at(4) - Self.pad)..<(Self.at(10) + Self.pad))
    }

    @Test func probabilitiesBetweenTheThresholdsKeepTheSpeechOpen() {
        var script = Script()
        script.silence(4)
        script.speech(2)
        // 0.4 is below the 0.5 threshold but above the 0.35 negative
        // threshold: with energy, the speech continues.
        for _ in 0..<4 { script.chunk(0.4, voiced: 0..<16) }
        script.silence(4)
        let segments = Self.segments(script.run().events)
        #expect(segments.count == 1)
        #expect(segments.first?.sampleRange.upperBound == Self.at(10) + Self.pad)
    }

    @Test func modelSmoothingAfterTheWordsDoesNotExtendTheEnd() {
        var script = Script()
        script.silence(4)
        script.speech(2)
        script.chunk(Self.speech, voiced: 0..<3)
        // The model is still sure for a chunk after the words end.
        script.chunk(0.9, voiced: 0..<0)
        script.silence(4)
        let segments = Self.segments(script.run().events)
        #expect(segments.first?.sampleRange.upperBound == Self.at(6, 3) + Self.pad)
    }

    @Test func speechTooQuietToRefineUsesChunkEdges() {
        var script = Script()
        script.silence(4)
        for _ in 0..<3 { script.chunk(Self.speech, voiced: 0..<0) }
        script.silence(4)
        let segments = Self.segments(script.run().events)
        #expect(segments.first?.sampleRange == (Self.at(4) - Self.pad)..<(Self.at(7) + Self.pad))
    }

    @Test func longSpeechIsSplitAtTheMaximumDuration() throws {
        var script = Script()
        script.silence(2)
        script.speech(80)  // 20.5 s of speech
        // A quiet subframe 7.5 s into the speech, inside the split window.
        let dip = Self.at(2) + 7 * 16_000 + 8_000
        let dipChunk = Int(dip / Self.chunk)
        let dipSubframe = Int((dip % Self.chunk) / Self.subframe)
        script.chunks[dipChunk].voiced.remove(dipSubframe)
        script.silence(4)
        let (events, machine) = script.run()

        let segments = Self.segments(events)
        #expect(segments.count == 3)
        #expect(machine.counters.forcedSplits == 2)
        let maximum = Int64(8 * 16_000)
        for segment in segments {
            #expect(segment.sampleCount <= maximum)
        }
        // Contiguous: each continuation starts where the split was.
        for (previous, next) in zip(segments, segments.dropFirst()) {
            #expect(previous.endReason == .maximumDuration)
            #expect(next.isContinuation)
            #expect(next.sampleRange.lowerBound == previous.sampleRange.upperBound)
        }
        // The first split lands mid-dip.
        let dipStart = Self.at(dipChunk, dipSubframe)
        #expect(segments[0].sampleRange.upperBound == dipStart + 128)
        #expect(segments[2].endReason == .silence)
        #expect(segments[2].sampleRange.upperBound == Self.at(82) + Self.pad)

        // Every split is announced as ended, then started again.
        let kinds = events.map { event -> String in
            if case .speechStarted(let onset) = event { onset.isContinuation ? "continue" : "start" } else { "end" }
        }
        #expect(kinds == ["start", "end", "continue", "end", "continue", "end"])
        #expect(Set(segments.map(\.id)).count == 3)
    }

    @Test func endOfStreamClosesTheOpenSegment() throws {
        var script = Script()
        script.silence(2)
        script.speech(3)
        let (events, _) = script.run()
        let segment = try #require(Self.segments(events).first)
        #expect(segment.endReason == .streamEnded)
        #expect(segment.sampleRange.upperBound == Self.at(5))
    }

    @Test func offsetsAreAbsolute() throws {
        var script = Script()
        script.silence(2)
        script.chunk(Self.speech, voiced: 4..<16)
        script.speech(1)
        script.silence(3)
        let start: Int64 = 1_000_003
        let segment = try #require(Self.segments(script.run(startingAt: start).events).first)
        #expect(segment.sampleRange.lowerBound == start + Self.at(2, 4) - Self.pad)
        #expect(segment.timeRange.start == .samples(segment.sampleRange.lowerBound, sampleRate: 16_000))
    }

    @Test func aNewSegmentNeverOverlapsThePreviousOne() throws {
        var script = Script()
        script.silence(2)
        script.speech(2)
        script.chunk(Self.silence, voiced: 0..<0)
        script.chunk(Self.silence, voiced: 0..<0)
        // Speech again right away; its look-back must stop at the previous end.
        script.chunk(Self.speech, voiced: 0..<16)
        script.speech(1)
        script.silence(3)
        var configuration = VoiceActivityConfiguration.standard
        configuration.speechPadding = .milliseconds(300)
        let segments = Self.segments(script.run(configuration).events)
        #expect(segments.count == 2)
        #expect(segments[1].sampleRange.lowerBound >= segments[0].sampleRange.upperBound)
    }

    @Test func noiseFloorFollowsTheRoom() {
        var machine = Machine(configuration: .standard)
        machine.begin(at: 0)
        #expect(machine.energyThreshold == Machine.defaultNoiseFloor + 6)
        for index in 0..<20 {
            _ = machine.process(
                .init(
                    startOffset: Int64(index) * 4_096, sampleCount: 4_096, probability: 0.01,
                    levels: Array(repeating: -45, count: 16)))
        }
        #expect(abs(machine.energyThreshold - -39) < 0.01)
    }
}
