import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The acceptance criterion, hermetically: the labelled fixture WAVs through
/// the real segmenter, with Silero's recorded probabilities replayed (see
/// `SileroLiveTests` for the same check with the live model).
@Suite("VAD on labelled fixtures")
struct VADFixtureTests {
    @Test("Boundaries within ±100 ms of the labels", arguments: VADFixture.names)
    func boundariesMatchTheLabels(_ name: String) async throws {
        let fixture = try VADFixture.load(name)
        let model = ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities())
        let run = await SegmenterRun.run(fixture.frames(), model: model)

        let accuracy = BoundaryAccuracy(fixture: name, labels: fixture.labels, segments: run.segments)
        #expect(accuracy.errors != nil, "\(accuracy)")
        #expect(accuracy.isWithinTolerance, "\(accuracy)")
        #expect(run.segments.allSatisfy { $0.duration <= .seconds(8) })
        #expect(run.statistics.modelFailures == 0)
    }

    @Test func theLongMonologueIsSplitIntoBoundedContiguousSegments() async throws {
        let fixture = try VADFixture.load("monologue-long")
        let model = ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities())
        let run = await SegmenterRun.run(fixture.frames(), model: model)

        let segments = run.segments
        #expect(segments.count == 2)
        #expect(segments.first?.endReason == .maximumDuration)
        #expect(segments.last?.isContinuation == true)
        #expect(segments.last?.endReason == .silence)
        #expect(segments.first?.sampleRange.upperBound == segments.last?.sampleRange.lowerBound)
        #expect(run.statistics.forcedSplits == 1)
        // The split falls between words, not mid-word: the audio around it
        // is the quietest of its window.
        let split = try #require(segments.first?.sampleRange.upperBound)
        let around = fixture.samples[Int(split) - 128..<Int(split) + 128]
        let level = AudioLevelMath.decibels(of: around)
        let speechLevel = AudioLevelMath.decibels(of: fixture.samples[Int(split) - 16_000..<Int(split)])
        #expect(level < speechLevel - 10, "split at \(split): \(level) dBFS vs \(speechLevel) dBFS")
    }

    @Test func frameSizeDoesNotChangeTheResult() async throws {
        let fixture = try VADFixture.load("conversation-quiet")
        let recorded = try fixture.recordedProbabilities()
        let reference = await SegmenterRun.run(fixture.frames(), model: ReplayedSpeechProbabilityModel(recorded))
        for frameLength in [160, 1_000, 4_096, 8_000] {
            let run = await SegmenterRun.run(
                fixture.frames(frameLength: frameLength), model: ReplayedSpeechProbabilityModel(recorded))
            #expect(run.segments == reference.segments, "\(frameLength)-sample frames")
        }
    }

    @Test func segmentsIndexTheCaptureStreamWhereverItStarts() async throws {
        let fixture = try VADFixture.load("pauses")
        let start: Int64 = 7 * 60 * 16_000 + 123  // seven minutes into a session
        let model = ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities(), streamStart: start)
        let run = await SegmenterRun.run(fixture.frames(startingAt: start), model: model)
        let reference = await SegmenterRun.run(
            fixture.frames(), model: ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities()))
        #expect(
            run.segments.map(\.sampleRange)
                == reference.segments.map { ($0.sampleRange.lowerBound + start)..<($0.sampleRange.upperBound + start) })
    }

    /// Segment ranges read the exact audio back from the capture history.
    @Test func segmentsReadTheirAudioBackFromTheCaptureHistory() async throws {
        let fixture = try VADFixture.load("conversation-quiet")
        // Room for the whole fixture, which is appended faster than real time.
        let hub = CaptureHub(configuration: .init(subscriberBuffer: .seconds(60)), signposter: .disabled(.audio))
        let segmenter = VoiceActivitySegmenter(
            model: ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities()),
            signposter: .disabled(.asr))
        let events = segmenter.events()
        let running = Task { await segmenter.run(on: hub) }
        while hub.subscriberCount == 0 { await Task.yield() }

        for index in stride(from: 0, to: fixture.samples.count, by: 480) {
            hub.append(Array(fixture.samples[index..<min(index + 480, fixture.samples.count)]))
        }
        hub.flush()
        hub.finish()
        await running.value

        var segments: [SpeechSegment] = []
        for await event in events {
            if case .speechEnded(let segment) = event { segments.append(segment) }
        }
        #expect(segments.count == fixture.labels.count)
        #expect(hub.statistics.subscriberDroppedFrames == 0)
        for segment in segments {
            let audio = try #require(hub.audio(for: segment))
            #expect(audio.sampleOffset == segment.sampleRange.lowerBound)
            #expect(
                audio.samples
                    == Array(fixture.samples[Int(segment.sampleRange.lowerBound)..<Int(segment.sampleRange.upperBound)])
            )
        }
    }

    /// `speechAudio()` carries exactly the speech: each segment's audio
    /// starts at its onset, is contiguous and equals the input, and nothing
    /// is delivered in the silences.
    @Test func speechAudioIsTheSpeechOnly() async throws {
        let fixture = try VADFixture.load("conversation-noisy")
        let run = await SegmenterRun.run(
            fixture.frames(), model: ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities()))

        var current: SpeechOnset?
        var next: Int64 = 0
        var delivered: Int64 = 0
        var segmentsSeen = 0
        for event in run.audio {
            switch event {
            case .started(let onset):
                if !onset.isContinuation { next = onset.startOffset }
                current = onset
            case .audio(let frame):
                let onset = try #require(current, "Audio outside a segment")
                #expect(frame.sampleOffset == next, "segment \(onset.segmentID)")
                #expect(frame.samples == Array(fixture.samples[Int(frame.sampleOffset)..<Int(frame.nextSampleOffset)]))
                next = frame.nextSampleOffset
                delivered += Int64(frame.sampleCount)
            case .ended(let segment):
                #expect(segment.id == current?.segmentID)
                #expect(next >= segment.sampleRange.upperBound, "the whole segment was delivered")
                current = nil
                segmentsSeen += 1
            }
        }
        #expect(segmentsSeen == run.segments.count)
        // Speech plus hangovers is well under the whole file: silence is skipped.
        #expect(delivered < Int64(fixture.samples.count) * 3 / 4)
        #expect(run.statistics.droppedAudioEvents == 0)
    }

    /// The model-free fallback on the quiet fixture: it can't tell speech
    /// from noise, but in a quiet room it finds the same segments.
    @Test func theEnergyFallbackFindsTheQuietConversation() async throws {
        let fixture = try VADFixture.load("conversation-quiet")
        let run = await SegmenterRun.run(fixture.frames(), model: EnergySpeechProbabilityModel())
        let accuracy = BoundaryAccuracy(fixture: fixture.name, labels: fixture.labels, segments: run.segments)
        #expect(accuracy.isWithinTolerance, "\(accuracy)")
    }
}
