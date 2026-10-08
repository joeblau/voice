import BlauAudio
import BlauCore
import Testing

/// Onboarding's microphone step (#44): the permission → requirement mapping
/// and the stub previews and UI tests use instead of the system prompt.
@Suite("Microphone onboarding")
struct MicrophoneOnboardingTests {
    @Test func onlyGrantedIsDone() {
        #expect(MicrophonePermission.granted.onboardingRequirement == .satisfied)
        #expect(MicrophonePermission.undetermined.onboardingRequirement == .missing)
        #expect(MicrophonePermission.denied.onboardingRequirement == .missing)
    }

    @Test func theStubAnswersAnUndeterminedPrompt() async {
        let allow = StubMicrophonePermission(.undetermined, answer: true)
        #expect(await allow.request())
        #expect(allow.status == .granted)

        let deny = StubMicrophonePermission(.undetermined, answer: false)
        #expect(await !deny.request())
        #expect(deny.status == .denied)
        #expect(deny.requests == 1)
    }

    @Test func aDecidedPermissionIsNotAskedAgain() async {
        // Like iOS: once denied, only the Settings app can change it.
        let denied = StubMicrophonePermission(.denied, answer: true)
        #expect(await !denied.request())
        #expect(denied.status == .denied)

        denied.set(.granted)
        #expect(await denied.request())
    }
}
