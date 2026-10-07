import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// Token refresh, driven entirely by a `ManualClock`: no real waiting, no
/// network.
@Suite("TokenProvider")
struct TokenProviderTests {
    let clock = ManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))

    /// 600 s secrets, refreshed 60 s early, retries after 1 s, 2 s, 4 s with
    /// no jitter.
    static let configuration = TokenProvider.Configuration(
        lifetime: .seconds(600),
        refreshLeeway: .seconds(60),
        retry: RetryPolicy(maximumAttempts: 4, initialDelay: .seconds(1), multiplier: 2, maximumDelay: .seconds(8))
    )

    func makeProvider(
        _ minter: FakeMinter, configuration: TokenProvider.Configuration = configuration
    ) -> TokenProvider {
        TokenProvider(minter: minter, clock: clock, configuration: configuration, unitRandom: { 0.5 })
    }

    // MARK: Caching and refresh

    @Test func standardConfigurationMatchesTheIssue() {
        #expect(TokenProvider.Configuration.standard.lifetime == .seconds(600))
        #expect(TokenProvider.Configuration.standard.refreshLeeway == .seconds(60))
        #expect(TokenProvider.Configuration.standard.retry == .tokenMinting)
    }

    @Test func mintsOnFirstUseWithTheConfiguredLifetime() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)

        let secret = try await provider.clientSecret()

        #expect(secret.value == "secret-1")
        #expect(minter.lifetimes == [.seconds(600)])
    }

    @Test func reusesTheSecretUntilSixtySecondsBeforeExpiry() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        _ = try await provider.clientSecret()

        clock.advance(by: .seconds(539))
        #expect(try await provider.clientSecret().value == "secret-1")
        clock.advance(by: .milliseconds(999))
        #expect(try await provider.clientSecret().value == "secret-1")
        #expect(minter.calls == 1)

        clock.advance(by: .milliseconds(1))  // t = 540 s = expiry - 60 s
        #expect(try await provider.clientSecret().value == "secret-2")
        #expect(minter.calls == 2)

        // The new secret is good for another 540 s from its own request.
        clock.advance(by: .seconds(539))
        #expect(try await provider.clientSecret().value == "secret-2")
        clock.advance(by: .seconds(1))
        #expect(try await provider.clientSecret().value == "secret-3")
    }

    @Test func expiryCountsFromWhenTheRequestWasSent() async throws {
        // Minting takes 2 s; the secret can't outlive request time + lifetime.
        let minter = FakeMinter(clock: clock, latency: .seconds(2))
        let provider = makeProvider(minter)
        let first = Task { try await provider.clientSecret() }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(2))
        #expect(try await first.value.value == "secret-1")

        clock.advance(by: .seconds(537))  // t = 539 s
        #expect(try await provider.clientSecret().value == "secret-1")

        clock.advance(by: .seconds(1))  // t = 540 s
        let second = Task { try await provider.clientSecret() }
        await minter.waitForCalls(2)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(2))
        #expect(try await second.value.value == "secret-2")
    }

    @Test func honoursAShorterLifetimeReportedByXAI() async throws {
        let minter = FakeMinter(clock: clock)
        minter.reportServerLifetime(.seconds(300))
        let provider = makeProvider(minter)
        _ = try await provider.clientSecret()

        clock.advance(by: .seconds(239))
        #expect(try await provider.clientSecret().value == "secret-1")
        clock.advance(by: .seconds(1))  // 300 s - 60 s
        #expect(try await provider.clientSecret().value == "secret-2")
    }

    @Test func ignoresAServerExpiryThatOnlyAWrongDeviceClockExplains() {
        let secret = RealtimeClientSecret(value: "s", expiresAt: clock.now.addingTimeInterval(-3_600))
        let cached = TokenProvider.cache(
            secret, requestedAt: .seconds(10), receivedAt: .seconds(11), wallClockNow: clock.now,
            configuration: Self.configuration)
        #expect(cached.expiresAt == .seconds(610))
        #expect(cached.refreshAt == .seconds(550))
    }

    @Test func neverExtendsBeyondTheRequestedLifetime() {
        let secret = RealtimeClientSecret(value: "s", expiresAt: clock.now.addingTimeInterval(3_600))
        let cached = TokenProvider.cache(
            secret, requestedAt: .zero, receivedAt: .seconds(1), wallClockNow: clock.now,
            configuration: Self.configuration)
        #expect(cached.expiresAt == .seconds(600))
    }

    @Test func invalidateForcesANewSecret() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        _ = try await provider.clientSecret()

        await provider.invalidate()

        #expect(try await provider.clientSecret().value == "secret-2")
    }

    @Test func aSecretMintedBeforeInvalidationIsDiscarded() async throws {
        // The key changes while a mint with the old key is in flight.
        let minter = FakeMinter(clock: clock, latency: .seconds(1))
        let provider = makeProvider(minter)
        let caller = Task { try await provider.clientSecret() }
        await minter.waitForCalls(1)
        await clock.waitForSleepers()

        await provider.invalidate()
        await minter.waitForCalls(2)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))

        #expect(try await caller.value.value == "secret-2")
        #expect(minter.calls == 2)
    }

    @Test func concurrentCallersShareOneMint() async throws {
        let minter = FakeMinter(clock: clock, latency: .seconds(1))
        let provider = makeProvider(minter)

        let callers = (0..<5).map { _ in Task { try await provider.clientSecret() } }
        await minter.waitForCalls(1)
        await clock.waitForSleepers()
        // Give the other callers every chance to start a second mint.
        for _ in 0..<100 { await Task.yield() }
        clock.advance(by: .seconds(1))

        for caller in callers {
            #expect(try await caller.value.value == "secret-1")
        }
        #expect(minter.calls == 1)
    }

    // MARK: Retry with backoff

    @Test func retriesTransientFailuresWithExponentialBackoff() async throws {
        let offline = XAIError.network(code: URLError.notConnectedToInternet.rawValue)
        let minter = FakeMinter(clock: clock, script: [offline, .server(status: 503, message: nil), offline])
        let provider = makeProvider(minter)
        let caller = Task { try await provider.clientSecret() }

        // Attempt 1 fails at t = 0; the retry waits 1 s.
        await clock.waitForSleepers()
        #expect(minter.calls == 1)
        clock.advance(by: .milliseconds(999))
        for _ in 0..<100 { await Task.yield() }
        #expect(minter.calls == 1)
        clock.advance(by: .milliseconds(1))

        // Attempt 2 fails at t = 1 s; the retry waits 2 s.
        await minter.waitForCalls(2)
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(1_999))
        for _ in 0..<100 { await Task.yield() }
        #expect(minter.calls == 2)
        clock.advance(by: .milliseconds(1))

        // Attempt 3 fails at t = 3 s; the retry waits 4 s, then succeeds.
        await minter.waitForCalls(3)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(4))

        #expect(try await caller.value.value == "secret-4")
        #expect(minter.calls == 4)
        #expect(clock.uptime == .seconds(7))

        // The secret's lifetime counts from the successful request (t = 7 s).
        clock.advance(by: .seconds(539))
        #expect(try await provider.clientSecret().value == "secret-4")
    }

    @Test func waitsAsLongAsARateLimitAsks() async throws {
        let minter = FakeMinter(clock: clock, script: [.rateLimited(retryAfter: .seconds(5))])
        let provider = makeProvider(minter)
        let caller = Task { try await provider.clientSecret() }

        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(4_999))
        for _ in 0..<100 { await Task.yield() }
        #expect(minter.calls == 1)
        clock.advance(by: .milliseconds(1))

        #expect(try await caller.value.value == "secret-2")
    }

    @Test func givesUpAfterTheLastAttempt() async throws {
        let failure = XAIError.server(status: 500, message: nil)
        let minter = FakeMinter(clock: clock, script: Array(repeating: failure, count: 4))
        let provider = makeProvider(minter)
        let caller = Task { try await provider.clientSecret() }

        for (attempt, delay) in [(1, 1), (2, 2), (3, 4)] {
            await minter.waitForCalls(attempt)
            await clock.waitForSleepers()
            clock.advance(by: .seconds(delay))
        }

        await #expect(throws: failure) { try await caller.value }
        #expect(minter.calls == 4)
    }

    @Test(arguments: [
        XAIError.invalidAPIKey(message: nil), .missingAPIKey, .insufficientCredits(message: nil),
        .permissionDenied(message: nil), .keyDisabled(.keyBlocked),
    ])
    func doesNotRetryKeyOrAccountProblems(error: XAIError) async {
        let minter = FakeMinter(clock: clock, script: [error])
        let provider = makeProvider(minter)

        await #expect(throws: error) { try await provider.clientSecret() }
        #expect(minter.calls == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aFailedRefreshFallsBackToTheStillValidSecret() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        _ = try await provider.clientSecret()

        clock.advance(by: .seconds(540))
        minter.enqueue([.invalidAPIKey(message: nil)])
        #expect(try await provider.clientSecret().value == "secret-1")

        // Too close to expiry to be useful: the error surfaces.
        clock.advance(by: .seconds(56))  // 4 s left
        minter.enqueue([.invalidAPIKey(message: nil)])
        await #expect(throws: XAIError.invalidAPIKey(message: nil)) { try await provider.clientSecret() }
    }

    // MARK: Proactive refresh

    @Test func keepFreshRefreshesSixtySecondsBeforeEachExpiry() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        let refresher = Task { await provider.keepFresh() }
        defer { refresher.cancel() }

        await minter.waitForCalls(1)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(539))
        for _ in 0..<100 { await Task.yield() }
        #expect(minter.calls == 1)

        clock.advance(by: .seconds(1))
        await minter.waitForCalls(2)
        await clock.waitForSleepers()
        // Callers get the refreshed secret without waiting for a mint.
        #expect(try await provider.clientSecret().value == "secret-2")
        #expect(minter.calls == 2)

        clock.advance(by: .seconds(540))
        await minter.waitForCalls(3)

        refresher.cancel()
        await refresher.value
    }

    @Test func keepFreshBacksOffWhileFallingBackToTheCurrentSecret() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        let refresher = Task { await provider.keepFresh() }
        await minter.waitForCalls(1)
        await clock.waitForSleepers()

        // Refreshes fail with a non-retryable error while the secret is
        // still valid, so callers get the fallback instead of an error.
        minter.enqueue([.permissionDenied(message: nil), .permissionDenied(message: nil)])
        clock.advance(by: .seconds(540))
        await minter.waitForCalls(2)
        await clock.waitForSleepers()
        for _ in 0..<100 { await Task.yield() }
        #expect(minter.calls == 2, "keepFresh must not spin while past the refresh point")

        clock.advance(by: .seconds(8))  // The retry policy's longest delay.
        await minter.waitForCalls(3)

        refresher.cancel()
        await refresher.value
    }

    @Test func keepFreshStopsWhenTheKeyIsUnusable() async {
        let minter = FakeMinter(clock: clock, script: [.invalidAPIKey(message: nil)])
        let provider = makeProvider(minter)
        await provider.keepFresh()  // Returns on its own.
        #expect(minter.calls == 1)
    }

    @Test func keepFreshKeepsTryingThroughOutages() async {
        let failure = XAIError.server(status: 503, message: nil)
        let minter = FakeMinter(clock: clock, script: [failure])
        let provider = makeProvider(minter, configuration: .init(retry: .noRetries))
        let refresher = Task { await provider.keepFresh() }

        await minter.waitForCalls(1)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))  // `RetryPolicy.noRetries` has no delay, so the loop waits 1 s.
        await minter.waitForCalls(2)

        refresher.cancel()
        await refresher.value
    }

    @Test func prefetchFillsTheCache() async throws {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        await provider.prefetch()
        #expect(minter.calls == 1)
        #expect(try await provider.clientSecret().value == "secret-1")
        #expect(minter.calls == 1)
    }

    @Test func aCancelledCallerThrowsCancellationError() async {
        let minter = FakeMinter(clock: clock)
        let provider = makeProvider(minter)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.clientSecret()
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(minter.calls == 0)
    }
}
