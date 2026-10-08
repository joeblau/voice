import BlauPersistence
import BlauVoiceID
import Foundation
import SwiftData
import Testing

@testable import Blau

/// Voice enrollment (#46) in the app: the composition root's services, the
/// enrollment writing to the app's store (what Settings reads), and the
/// wording.
@MainActor
struct VoiceEnrollmentAppTests {
    @Test func anEnrollmentWritesTheVoiceprintSettingsReads() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(environment.makeVoiceEnrollment(plan: .enrollment) == nil, "No store open yet")
        await environment.persistence.start()
        let enrollment = try #require(environment.makeVoiceEnrollment(plan: .enrollment))
        await enrollment.start()
        guard case .finished(let voiceprint) = enrollment.phase else {
            Issue.record("Expected finished, got \(enrollment.phase)")
            return
        }

        // Settings reads the profile from the main context.
        let context = try #require(environment.modelContainer).mainContext
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.map(\.id) == [voiceprint.id])
        let profile = try #require(profiles.first)
        #expect(VoiceIDStatus(profile: profile).kind == .enrolled)
        #expect(profile.embeddingModelVersion == VoiceIDConfig.calibrated.modelIdentifier)
        #expect(VoiceIDSettingsView.devices(in: profile) == [environment.voiceEnrollment.deviceModel])
        #expect(VoiceIDSettingsView.hasSet(for: environment.voiceEnrollment.deviceModel, in: profile))
        #expect((profile.enrollmentSets ?? []).first?.clipCount == 4)

        // A model change shows as "Re-enroll needed".
        #expect(VoiceIDStatus(profile: profile, currentModel: "wespeaker-resnet34-lm@next").kind == .needsReenrollment)

        // Deleting (Settings → Voice ID or Privacy) removes it.
        try DataEraser.erase(.voiceprint, in: context)
        #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<VoiceEnrollmentSet>()) == 0)
    }

    @Test func nonLiveEnvironmentsNeverTouchTheMicrophone() {
        #expect(AppEnvironment.scriptedEnrollmentSpeed(.unitTest) == nil)
        #expect(AppEnvironment.scriptedEnrollmentSpeed(.uiTest) == 8)
        #expect(AppEnvironment.scriptedEnrollmentSpeed(.preview) == 1)
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(environment.voiceEnrollment.makeAudio() is ScriptedEnrollmentAudio)
    }

    @Test func everyPromptIssueAndFailureHasWording() {
        for prompt in EnrollmentPrompt.allCases {
            let copy = EnrollmentPromptCopy(prompt)
            #expect(!copy.title.isEmpty && !copy.text.isEmpty)
        }
        let issues: [EnrollmentClipIssue] = [
            .tooShort(speech: .seconds(1), minimum: .seconds(3)), .tooQuiet(level: -60, minimum: -45),
            .tooNoisy(signalToNoise: 3, minimum: 12), .clipped(fraction: 0.1),
            .inconsistent(similarity: 0.1, minimum: 0.4), .doesNotMatchVoiceprint(similarity: 0, minimum: 0.27),
            .unusable,
        ]
        #expect(Set(issues.map(EnrollmentMessages.issue)).count == issues.count)
        let errors: [VoiceEnrollmentError] = [
            .modelUnavailable(""), .microphoneUnavailable(""), .microphoneBusy, .microphoneStopped, .notEnrolled,
            .needsReenrollment, .saveFailed(""),
        ]
        #expect(Set(errors.map(EnrollmentMessages.failure)).count == errors.count)
        #expect(EnrollmentMessages.failure(.microphoneBusy) == "Stop the conversation first, then enroll.")
    }

    @Test func qualityChecks() {
        let analysis = EnrollmentClipAnalysis(
            duration: .seconds(7), speechDuration: .seconds(5), speechLevel: -25, noiseLevel: -70,
            clippedFraction: 0, speechRange: 0..<1)
        let accepted = VoiceEnrollment.ClipResult(
            prompt: .readSentence, analysis: analysis, similarity: 0.9, issues: [])
        #expect(
            EnrollmentQualityChecks(result: accepted)
                == EnrollmentQualityChecks(
                    result: VoiceEnrollment.ClipResult(
                        prompt: .armsLength, analysis: analysis, similarity: nil, issues: [])))
        let checks = EnrollmentQualityChecks(result: accepted)
        #expect(checks.duration == .passed && checks.signal == .passed && checks.consistency == .passed)

        let noisy = EnrollmentQualityChecks(
            result: VoiceEnrollment.ClipResult(
                prompt: .readSentence, analysis: analysis, similarity: nil,
                issues: [
                    .tooNoisy(signalToNoise: 4, minimum: 12), .tooShort(speech: .seconds(2), minimum: .seconds(3)),
                ]
            ))
        #expect(noisy.duration == .failed && noisy.signal == .failed && noisy.consistency == .pending)

        let someoneElse = EnrollmentQualityChecks(
            result: VoiceEnrollment.ClipResult(
                prompt: .readSentence, analysis: analysis, similarity: 0.1,
                issues: [.inconsistent(similarity: 0.1, minimum: 0.4)]))
        #expect(someoneElse.duration == .passed && someoneElse.consistency == .failed)

        let live = EnrollmentQualityChecks(
            meter: EnrollmentMeter(speech: .seconds(2), speechTarget: .seconds(5), signalToNoise: 30),
            minimumSignalToNoise: 12)
        #expect(live.duration == .pending && live.signal == .passed && live.consistency == .pending)
    }

    @Test func deviceNames() {
        #expect(VoiceIDSettingsView.deviceName("iPhone18,1") == "iPhone 17 Pro")
        #expect(VoiceIDSettingsView.deviceName("iPad99,9") == "iPad99,9")
        #expect(VoiceIDSettingsView.devices(in: nil).isEmpty)
    }
}
