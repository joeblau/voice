import BlauAudio
import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// The gate's memory over a long session (#183): a segment's audio grows in
/// place, finished segments let their audio go, and nothing the gate keeps
/// grows with the number of segments.
///
/// The soak test caught the gate copying a segment's whole audio buffer on
/// every 20 ms frame (copy-on-write on a buffer the segment table still
/// held): gigabytes of short-lived allocations over a 20-minute session,
/// which fragmented the heap until the footprint grew. The buffer's
/// reallocations show it: a few while it doubles, or one per frame when it
/// is copied.
@Suite("Verification gate memory")
struct VerificationGateMemoryTests {
    /// VAD's audio in 20 ms frames, as the capture hub publishes it.
    static let frameSeconds = 0.02

    /// A whole segment in 20 ms frames: its start, its audio through the
    /// 300 ms hangover, and its end.
    static func segment(_ id: Int, from start: Double, to end: Double) -> [SpeechAudioEvent] {
        let frame = Int(SpeechScript.offset(frameSeconds))
        let stop = SpeechScript.offset(end + 0.3)
        var events: [SpeechAudioEvent] = [.started(SpeechScript.onset(id, at: start))]
        var position = SpeechScript.offset(start)
        while position < stop {
            let count = Int(min(Int64(frame), stop - position))
            events.append(.audio(AudioFrame(samples: [Float](repeating: 0.01, count: count), sampleOffset: position)))
            position += Int64(count)
        }
        events.append(.ended(SpeechScript.ended(id, from: start, to: end)))
        return events
    }

    /// The most reallocations one segment's buffer may need: it doubles from
    /// one frame to the 20 s it may hold (about ten times), with room to
    /// spare for the allocator's rounding. Copying it on every frame needs
    /// one per frame instead: 800 for 16 s.
    static let reallocationsPerSegment = 16

    @Test func aLongSegmentsAudioGrowsInPlace() async {
        let gate = VerificationGate(verifier: ScriptedVerifier(SpeakerTimeline([(0, 30, .owner)])))
        // 16 s of speech, 815 frames: under the 20 s the gate buffers.
        await gate.feed(Self.segment(0, from: 0, to: 16))

        let statistics = gate.statistics
        #expect(statistics.audioBufferReallocations >= 1)
        #expect(
            statistics.audioBufferReallocations <= Self.reallocationsPerSegment,
            "\(statistics.audioBufferReallocations) reallocations for one segment: its audio is being copied")
        #expect(await gate.decision(ofSegment: 0) == .accept)
        #expect(await gate.retainedAudio.samples == 0, "A finished segment keeps no audio")
    }

    /// Two hours of mixed speech would take minutes here; 120 segments of
    /// every length (too short to score, scored once, re-scored, split by
    /// VAD at 8 s), the owner's and a TV's, hold the same pattern: per
    /// segment work and memory that don't depend on how many came before.
    @Test func aLongSessionKeepsTheGateBounded() async {
        let lengths = [0.6, 1.8, 2.5, 4.0, 6.0, 8.0]
        let count = 120
        var timeline: [(start: Double, end: Double, voice: SpeakerTimeline.Voice)] = []
        var segments: [(start: Double, end: Double)] = []
        var time = 0.0
        for index in 0..<count {
            let length = lengths[index % lengths.count]
            segments.append((time, time + length))
            // From a little before the segment, so the start rounded to a
            // sample offset still falls inside its talker's part.
            timeline.append((time - 0.5, time + length + 0.3, index % 3 == 2 ? .other : .owner))
            time += length + 1
        }
        let gate = VerificationGate(verifier: ScriptedVerifier(SpeakerTimeline(timeline)))
        let retained = gate.configuration.retainedSegments

        var reallocations: [Int] = []
        var previous = 0
        for (id, segment) in segments.enumerated() {
            await gate.feed(Self.segment(id, from: segment.start, to: segment.end))
            let total = gate.statistics.audioBufferReallocations
            reallocations.append(total - previous)
            previous = total

            let memory = await gate.retainedAudio
            #expect(memory.samples == 0, "segment \(id): finished segments keep no audio")
            #expect(memory.segments <= retained, "segment \(id): \(memory.segments) segments remembered")
        }

        let statistics = gate.statistics
        #expect(statistics.segments == count)
        #expect(
            reallocations.allSatisfy { $0 <= Self.reallocationsPerSegment },
            "Most reallocations for one segment: \(reallocations.max() ?? 0)")
        // The same lengths cost the same at the end of the session as at the
        // start: no work or memory that grows with the segments before.
        let firstCycle = Array(reallocations.prefix(lengths.count))
        let lastCycle = Array(reallocations.suffix(lengths.count))
        #expect(firstCycle == lastCycle)
        #expect(await gate.decision(ofSegment: count - 1) == .reject)
        #expect(await gate.decision(ofSegment: count - 2) == .accept)
    }
}
