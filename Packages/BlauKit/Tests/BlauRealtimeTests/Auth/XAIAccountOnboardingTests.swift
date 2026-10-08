import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

/// Onboarding's xAI step (#44): which account states need the user.
@Suite("XAIAccount onboarding")
@MainActor
struct XAIAccountOnboardingTests {
    @Test func statusesMapToRequirements() {
        let key = XAIAccount.ConnectedKey(redacted: "•••• a1b2", name: nil, verified: false)
        #expect(XAIAccount.Status.unknown.onboardingRequirement == .unknown)
        #expect(XAIAccount.Status.noKey.onboardingRequirement == .missing)
        #expect(XAIAccount.Status.connected(key).onboardingRequirement == .satisfied)
        #expect(XAIAccount.Status.unavailable(.corruptItem).onboardingRequirement == .missing)
        // Locked or failing Keychains may well hold a key.
        #expect(XAIAccount.Status.unavailable(.locked).onboardingRequirement == .unknown)
        #expect(XAIAccount.Status.unavailable(.keychain(status: -34018)).onboardingRequirement == .unknown)
    }

    @Test func missingMatchesWhenKeyEntryIsOffered() async throws {
        // The onboarding step and the main screen's Connect button agree.
        let store = InMemoryAPIKeyStore()
        let account = XAIAccount(store: store, validator: FakeValidator())
        #expect((account.status.onboardingRequirement == .missing) == account.needsKeyEntry)
        await account.load()
        #expect(account.status.onboardingRequirement == .missing)
        #expect(account.needsKeyEntry)

        #expect(await account.connect(apiKey: TestKeys.primaryRaw))
        #expect(account.status.onboardingRequirement == .satisfied)
        #expect(!account.needsKeyEntry)
    }
}
