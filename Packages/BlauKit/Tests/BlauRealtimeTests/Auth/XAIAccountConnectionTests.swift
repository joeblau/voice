import Foundation
import Testing

@testable import BlauRealtime

/// Settings → xAI account → Test Connection.
@Suite("XAIAccount connection test")
@MainActor
struct XAIAccountConnectionTests {
    let store = InMemoryAPIKeyStore()
    let validator = FakeValidator()
    let now = Date(timeIntervalSince1970: 1_791_363_600)

    func makeAccount(store: (any APIKeyStore)? = nil) -> XAIAccount {
        XAIAccount(store: store ?? self.store, validator: validator)
    }

    @Test func aWorkingKeyPasses() async throws {
        try await store.save(TestKeys.primary)
        let account = makeAccount()
        await account.load()
        #expect(account.connectionCheck == .notTested)

        let passed = await account.testConnection(now: now)

        #expect(passed)
        #expect(account.connectionCheck == .succeeded(at: now, realtimeVerified: true))
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: "blau-dev", verified: true)))
        #expect(validator.validatedKeys == [TestKeys.primary])
        #expect(account.activity == .idle)
        // A test never touches the main problem banner.
        #expect(account.problem == nil)
    }

    @Test func anInconclusiveRealtimeCheckIsReported() async throws {
        try await store.save(TestKeys.primary)
        validator.setOutcome(.success(XAIKeyStatus(name: nil, realtimeVerified: false)))
        let account = makeAccount()
        await account.load()
        #expect(await account.testConnection(now: now))
        #expect(account.connectionCheck == .succeeded(at: now, realtimeVerified: false))
    }

    @Test func aFailureKeepsTheKeyAndSaysWhy() async throws {
        try await store.save(TestKeys.primary)
        let account = makeAccount()
        await account.connect(apiKey: TestKeys.primaryRaw)
        validator.setOutcome(.failure(.insufficientCredits(message: nil)))

        let passed = await account.testConnection(now: now)

        #expect(!passed)
        guard case .failed(let problem) = account.connectionCheck else {
            Issue.record("Expected a failure, got \(account.connectionCheck)")
            return
        }
        #expect(problem.kind == .noCredits)
        // Still stored, with the name learned earlier, but no longer verified.
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: "blau-dev", verified: false)))
        #expect(try await store.load() == TestKeys.primary)
    }

    @Test func offlineIsAFailureToo() async throws {
        try await store.save(TestKeys.primary)
        validator.setOutcome(.failure(.network(code: URLError.notConnectedToInternet.rawValue)))
        let account = makeAccount()
        await account.load()
        #expect(!(await account.testConnection(now: now)))
        guard case .failed(let problem) = account.connectionCheck else {
            Issue.record("Expected a failure")
            return
        }
        #expect(problem.kind == .offline)
    }

    @Test func withoutAKeyThereIsNothingToTest() async {
        let account = makeAccount()
        await account.load()
        #expect(!(await account.testConnection(now: now)))
        #expect(account.connectionCheck == .notTested)
        #expect(account.status == .noKey)
        #expect(validator.validatedKeys.isEmpty)
    }

    @Test func aLockedKeychainFailsTheTest() async {
        let account = makeAccount(store: FailingAPIKeyStore(error: .locked))
        #expect(!(await account.testConnection(now: now)))
        #expect(account.status == .unavailable(.locked))
        guard case .failed(let problem) = account.connectionCheck else {
            Issue.record("Expected a failure")
            return
        }
        #expect(problem.kind == .keychainLocked)
    }

    @Test func changingTheKeyClearsTheResult() async throws {
        try await store.save(TestKeys.primary)
        let account = makeAccount()
        await account.load()
        await account.testConnection(now: now)
        #expect(account.connectionCheck != .notTested)

        await account.connect(apiKey: TestKeys.secondaryRaw)
        #expect(account.connectionCheck == .notTested)

        await account.testConnection(now: now)
        await account.removeKey()
        #expect(account.connectionCheck == .notTested)
    }
}
