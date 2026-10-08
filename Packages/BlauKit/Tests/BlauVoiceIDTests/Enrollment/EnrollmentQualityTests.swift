import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// The quality meter: analysis of a clip, the live tracker, the recorder
/// and the policy.
@Suite("Enrollment quality")
struct EnrollmentQualityTests {
    // MARK: Analysis

    @Test func cleanSpeechHasTalkingTimeLevelAndSNR() {
        let analysis = EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(.owner, duration: .seconds(8)))
        #expect(analysis.duration == .seconds(8))
        // 6 s of syllables with the pauses between them bridged.
        #expect(abs(analysis.speechDuration.timeInterval - 6) < 0.25, "\(analysis.speechDuration)")
        #expect(analysis.speechLevel > -35 && analysis.speechLevel < -15, "\(analysis.speechLevel)")
        #expect(analysis.noiseLevel < -60, "\(analysis.noiseLevel)")
        #expect(analysis.signalToNoise > 30)
        #expect(analysis.clippedFraction == 0)
        // The speech range drops the 600 ms lead-in and the trailing
        // silence, keeping 100 ms on each side.
        let start = Double(analysis.speechRange.lowerBound) / 16_000
        let end = Double(analysis.speechRange.upperBound) / 16_000
        #expect(abs(start - 0.5) < 0.05, "\(start)")
        #expect(abs(end - 6.7) < 0.15, "\(end)")
        #expect(EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .readSentence).isEmpty)
    }

    @Test func silenceHasNoSpeech() {
        let analysis = EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(.silence, duration: .seconds(4)))
        #expect(!analysis.hasSpeech)
        #expect(analysis.speechRange.isEmpty)
        #expect(analysis.signalToNoise == 0)
        let issues = EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .readSentence)
        #expect(issues == [.tooShort(speech: .zero, minimum: .seconds(3))])
    }

    @Test func digitalSilenceAndEmptyClips() {
        let zeros = EnrollmentClipAnalysis(
            analyzing: AudioFrame(samples: [Float](repeating: 0, count: 16_000), sampleOffset: 0))
        #expect(!zeros.hasSpeech)
        #expect(zeros.noiseLevel == EnrollmentLevelAnalyzer.floorDecibels)
        let empty = EnrollmentClipAnalysis(analyzing: AudioFrame(samples: [], sampleOffset: 0))
        #expect(empty.duration == .zero)
        #expect(!empty.hasSpeech)
    }

    @Test func shortSpeechIsTooShort() {
        let voice = ScriptedEnrollmentAudio.Voice(speech: .seconds(2))
        let analysis = EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(voice, duration: .seconds(4)))
        let issues = EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .answerQuestion)
        guard case .tooShort(let speech, _) = issues.first else {
            Issue.record("Expected tooShort, got \(issues)")
            return
        }
        #expect(abs(speech.timeInterval - 2) < 0.25)
    }

    @Test func quietSpeechFailsANormalPromptButNotTheQuietOne() {
        let voice = ScriptedEnrollmentAudio.Voice(amplitude: 0.006, noise: 0.00003)
        let analysis = EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(voice))
        #expect(analysis.speechLevel < -45 && analysis.speechLevel > -55, "\(analysis.speechLevel)")
        let normal = EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .readSentence)
        #expect(normal.contains { if case .tooQuiet = $0 { true } else { false } }, "\(normal)")
        #expect(EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .speakQuietly).isEmpty)
        #expect(EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .armsLength).isEmpty)
    }

    @Test func noisyBackgroundIsTooNoisy() {
        // Speech barely above loud noise (a TV, a café).
        let voice = ScriptedEnrollmentAudio.Voice(amplitude: 0.1, noise: 0.06)
        let analysis = EnrollmentClipAnalysis(analyzing: EnrollmentAudio.clip(voice))
        #expect(analysis.signalToNoise < 12, "\(analysis.signalToNoise)")
        let issues = EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .readSentence)
        #expect(
            issues.contains {
                switch $0 {
                case .tooNoisy, .tooShort: true
                default: false
                }
            }, "\(issues)")
    }

    @Test func clippingIsReported() {
        let voice = ScriptedEnrollmentAudio.Voice(amplitude: 1.6)
        let clip = EnrollmentAudio.clip(voice)
        let clamped = AudioFrame(samples: clip.samples.map { min(1, max(-1, $0)) }, sampleOffset: 0)
        let analysis = EnrollmentClipAnalysis(analyzing: clamped)
        #expect(analysis.clippedFraction > 0.005)
        let issues = EnrollmentQualityPolicy.standard.audioIssues(analysis, prompt: .readSentence)
        #expect(issues.contains { if case .clipped = $0 { true } else { false } })
    }

    @Test func bridgingFillsShortGapsOnly() {
        let flags = [true, false, false, true, false, false, false, false, true]
        #expect(
            EnrollmentLevelAnalyzer.bridge(flags, maximumGap: 2) == [
                true, true, true, true, false, false, false, false, true,
            ])
        #expect(EnrollmentLevelAnalyzer.bridge([false, true, false], maximumGap: 5) == [false, true, false])
    }

    /// Real speech: every CMU ARCTIC fixture clip is a clean read sentence.
    @Test func realSpeechFixturesPass() throws {
        for clip in try SpeakerFixtures.load() {
            #expect(clip.audio.sampleRate == 16_000)
            let analysis = EnrollmentClipAnalysis(analyzing: clip.audio)
            #expect(analysis.speechDuration > .seconds(2), "\(clip.name): \(analysis.speechDuration)")
            #expect(analysis.speechDuration <= analysis.duration)
            #expect(analysis.signalToNoise > 15, "\(clip.name): \(analysis.signalToNoise)")
            #expect(analysis.clippedFraction < 0.001)
        }
    }

    // MARK: Live tracking and recording

    @Test func theTrackerFollowsTheAnalysis() {
        let clip = EnrollmentAudio.clip()
        var tracker = EnrollmentLevelTracker()
        // Odd-sized chunks: the tracker re-frames them.
        for start in stride(from: 0, to: clip.sampleCount, by: 1_000) {
            tracker.append(Array(clip.samples[start..<min(start + 1_000, clip.sampleCount)]))
        }
        let analysis = EnrollmentClipAnalysis(analyzing: clip)
        #expect(abs(tracker.speechDuration.timeInterval - analysis.speechDuration.timeInterval) < 0.2)
        #expect(tracker.silenceSinceSpeech > .seconds(1))
        #expect((tracker.signalToNoise ?? 0) > 30)
        #expect(tracker.noiseFloor ?? 0 < -60)
    }

    @Test func aClipStopsAfterEnoughSpeechAndAPause() {
        var recorder = EnrollmentClipRecorder(plan: .enrollment)
        #expect(recorder.meter.progress == 0)
        for frame in EnrollmentAudio.frames(of: EnrollmentAudio.clip(duration: .seconds(10))) {
            recorder.append(frame)
            if recorder.isComplete { break }
        }
        #expect(recorder.completion == .enoughSpeech)
        // 0.6 s lead-in, 6 s of talking (the target is 5 s, but the voice
        // goes on), then the 0.5 s pause.
        #expect(abs(recorder.duration.timeInterval - 7.1) < 0.2, "\(recorder.duration)")
        #expect(recorder.meter.progress == 1)
        #expect(recorder.meter.signalToNoise != nil)
        #expect(recorder.clip.sampleCount == Int(recorder.duration.sampleCount(sampleRate: 16_000)))
        // Frames after completion are ignored.
        let before = recorder.duration
        recorder.append(AudioFrame(samples: [Float](repeating: 0.1, count: 320), sampleOffset: 999_999))
        #expect(recorder.duration == before)
    }

    @Test func aClipWithoutSpeechStopsAtTheTimeLimit() {
        var recorder = EnrollmentClipRecorder(plan: .enrollment)
        for frame in EnrollmentAudio.frames(of: EnrollmentAudio.clip(.silence, duration: .seconds(15))) {
            recorder.append(frame)
            if recorder.isComplete { break }
        }
        #expect(recorder.completion == .timeLimit)
        #expect(recorder.duration == EnrollmentPlan.enrollment.maximumClipDuration)
        #expect(recorder.meter.signalToNoise == nil)
    }

    @Test func theClipKeepsItsStreamPosition() {
        var recorder = EnrollmentClipRecorder(plan: .enrollment)
        recorder.append(AudioFrame(samples: [Float](repeating: 0, count: 320), sampleOffset: 48_000))
        #expect(recorder.clip.sampleOffset == 48_000)
    }

    // MARK: Plans

    @Test func plansFitTheOneMinuteBudget() {
        let full = EnrollmentPlan.enrollment
        #expect(full.prompts == [.readSentence, .answerQuestion, .speakQuietly, .armsLength])
        #expect(full.totalSpeech == .seconds(20))
        // Even if every clip runs to its limit, recording stays under 60 s.
        #expect(full.maximumRecordingDuration < .seconds(60))
        let topUp = EnrollmentPlan.topUp
        #expect(topUp.purpose == .topUp)
        #expect(topUp.totalSpeech == .seconds(15))
        #expect(topUp.maximumRecordingDuration < .seconds(60))
        #expect(EnrollmentPrompt.speakQuietly.expectsLowLevel && EnrollmentPrompt.armsLength.expectsLowLevel)
        #expect(!EnrollmentPrompt.readSentence.expectsLowLevel)
    }

    @Test func theConsistencyBarIsTheGatesAcceptThreshold() {
        #expect(EnrollmentQualityPolicy.standard.minimumConsistency == VoiceIDConfig.calibrated.long.accept)
        #expect(EnrollmentQualityPolicy.standard.minimumVoiceprintMatch == VoiceIDConfig.calibrated.long.reject)
    }
}
