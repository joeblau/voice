import Foundation
import Testing

@testable import BlauRealtime

/// The model behind Settings → xAI account and the onboarding key step.
@Suite("XAIAccount")
@MainActor
struct XAIAccountTests {
    let store = InMemoryAPIKeyStore()
    let validator = FakeValidator()
    let keyChanges = CallCounter()

    func makeAccount(store: (any APIKeyStore)? = nil) -> XAIAccount {
        let counter = keyChanges
        return XAIAccount(store: store ?? self.store, validator: validator, onKeyChange: { counter.increment() })
    }

    // MARK: Loading

    @Test func startsUnknownAndLoadsAMissingKey() async {
        let account = makeAccount()
        #expect(account.status == .unknown)
        await account.load()
        #expect(account.status == .noKey)
        #expect(!account.hasKey)
        #expect(account.activity == .idle)
    }

    @Test func loadsAStoredKeyRedacted() async throws {
        try await store.save(TestKeys.primary)
        let account = makeAccount()
        await account.load()
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: nil, verified: false)))
    }

    @Test func reloadingPicksUpAKeyFromAnotherDevice() async throws {
        let account = makeAccount()
        await account.load()
        #expect(account.status == .noKey)

        // iCloud Keychain delivers the key entered on another device.
        try await store.save(TestKeys.secondary)
        await account.load()
        #expect(account.status == .connected(.init(redacted: "•••• z9y8", name: nil, verified: false)))

        // ...and removing it there removes it here.
        try await store.delete()
        await account.load()
        #expect(account.status == .noKey)
    }

    @Test func reloadingKeepsWhatWasLearnedAboutTheSameKey() async {
        let account = makeAccount()
        await account.connect(apiKey: TestKeys.primaryRaw)
        await account.load()
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: "blau-dev", verified: true)))
    }

    @Test func aLockedKeychainIsReported() async {
        let account = makeAccount(store: FailingAPIKeyStore(error: .locked))
        await account.load()
        #expect(account.status == .unavailable(.locked))
    }

    // MARK: Connecting

    @Test func aWorkingKeyIsValidatedThenStored() async throws {
        let account = makeAccount()
        let stored = await account.connect(apiKey: "  \(TestKeys.primaryRaw)\n")

        #expect(stored)
        #expect(validator.validatedKeys == [TestKeys.primary])
        #expect(try await store.load() == TestKeys.primary)
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: "blau-dev", verified: true)))
        #expect(account.problem == nil)
        #expect(keyChanges.value == 1)
    }

    @Test func malformedInputIsRejectedWithoutCallingXAI() async throws {
        let account = makeAccount()
        let stored = await account.connect(apiKey: "sk-123")

        #expect(!stored)
        #expect(account.problem?.kind == .malformedKey)
        #expect(validator.validatedKeys.isEmpty)
        #expect(try await store.load() == nil)
    }

    @Test func anInvalidKeyShowsARecoverableErrorAndKeepsTheWorkingKey() async throws {
        try await store.save(TestKeys.secondary)
        let account = makeAccount()
        await account.load()
        validator.setOutcome(.failure(.invalidAPIKey(message: "Incorrect API key provided")))

        let stored = await account.connect(apiKey: TestKeys.primaryRaw)

        #expect(!stored)
        let problem = try #require(account.problem)
        #expect(problem.kind == .invalidKey)
        #expect(problem.title == "xAI didn't accept this key")
        #expect(!problem.canSaveAnyway)
        #expect(!problem.message.contains(TestKeys.primaryRaw))
        #expect(try await store.load() == TestKeys.secondary)
        #expect(account.status == .connected(.init(redacted: "•••• z9y8", name: nil, verified: false)))
        #expect(account.activity == .idle)
        #expect(keyChanges.value == 0)

        // Recover: fix the key and try again.
        validator.setOutcome(.success(XAIKeyStatus(name: "fixed")))
        #expect(await account.connect(apiKey: TestKeys.primaryRaw))
        #expect(account.problem == nil)
        #expect(try await store.load() == TestKeys.primary)
    }

    @Test(arguments: [
        (XAIError.insufficientCredits(message: nil), XAIAccountProblem.Kind.noCredits),
        (.keyDisabled(.teamBlocked), .keyDisabled),
        (.permissionDenied(message: nil), .notPermitted),
        (.keyStore(.locked), .keychainLocked),
    ])
    func keyAndAccountProblemsAreNotSaved(error: XAIError, kind: XAIAccountProblem.Kind) async throws {
        validator.setOutcome(.failure(error))
        let account = makeAccount()
        #expect(await !account.connect(apiKey: TestKeys.primaryRaw))
        #expect(account.problem?.kind == kind)
        #expect(account.problem?.canSaveAnyway == false)
        #expect(await !account.saveWithoutVerifying())
        #expect(try await store.load() == nil)
    }

    @Test(arguments: [
        (XAIError.network(code: URLError.notConnectedToInternet.rawValue), XAIAccountProblem.Kind.offline),
        (.rateLimited(retryAfter: nil), .rateLimited),
        (.server(status: 502, message: nil), .serverError),
    ])
    func whenTheKeyCantBeCheckedItCanBeSavedAnyway(error: XAIError, kind: XAIAccountProblem.Kind) async throws {
        validator.setOutcome(.failure(error))
        let account = makeAccount()
        #expect(await !account.connect(apiKey: TestKeys.primaryRaw))
        #expect(account.problem?.kind == kind)
        #expect(account.problem?.canSaveAnyway == true)

        #expect(await account.saveWithoutVerifying())
        #expect(try await store.load() == TestKeys.primary)
        #expect(account.status == .connected(.init(redacted: "•••• a1b2", name: nil, verified: false)))
        #expect(account.problem == nil)
        #expect(keyChanges.value == 1)
    }

    @Test func dismissingTheProblemForgetsTheUnverifiedKey() async throws {
        validator.setOutcome(.failure(.network(code: URLError.timedOut.rawValue)))
        let account = makeAccount()
        await account.connect(apiKey: TestKeys.primaryRaw)
        account.dismissProblem()
        #expect(account.problem == nil)
        #expect(await !account.saveWithoutVerifying())
        #expect(try await store.load() == nil)
    }

    @Test func aKeychainWriteFailureIsShown() async {
        let account = makeAccount(store: FailingAPIKeyStore(error: .keychain(status: -34018)))
        #expect(await !account.connect(apiKey: TestKeys.primaryRaw))
        #expect(account.problem?.kind == .keychainFailure)
        #expect(account.problem?.message.contains("-34018") == true)
    }

    // MARK: Removing

    @Test func removingTheKeyDeletesItAndInvalidatesTokens() async throws {
        let account = makeAccount()
        await account.connect(apiKey: TestKeys.primaryRaw)

        await account.removeKey()

        #expect(try await store.load() == nil)
        #expect(account.status == .noKey)
        #expect(keyChanges.value == 2)
    }

    // MARK: Problems reported while in use

    @Test func problemsHitDuringASessionAreSurfaced() async {
        let account = makeAccount()
        account.report(.insufficientCredits(message: nil))
        #expect(account.problem?.kind == .noCredits)

        account.dismissProblem()
        account.report(.network(code: URLError.timedOut.rawValue))  // Transient: not the account's problem.
        #expect(account.problem == nil)
    }

    @Test func everyProblemHasUserFacingText() {
        let errors: [XAIError] = [
            .missingAPIKey, .keyStore(.corruptItem), .keyStore(.keychain(status: 1)), .invalidAPIKey(message: nil),
            .keyDisabled(.keyBlocked), .keyDisabled(.keyDisabled), .keyDisabled(.teamBlocked),
            .insufficientCredits(message: nil), .permissionDenied(message: nil), .rateLimited(retryAfter: nil),
            .badRequest(status: 400, message: nil), .server(status: 500, message: nil), .network(code: -1009),
            .invalidResponse("x"), .cancelled,
        ]
        for error in errors {
            let problem = XAIAccountProblem(error)
            #expect(!problem.title.isEmpty && !problem.message.isEmpty, "\(error)")
        }
        let formatErrors: [XAIAPIKey.FormatError] = [
            .empty, .containsWhitespace, .invalidCharacters, .tooShort(minimum: 1), .tooLong(maximum: 1),
        ]
        for error in formatErrors {
            #expect(XAIAccountProblem(error).kind == .malformedKey)
        }
    }
}
