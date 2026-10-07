import BlauCore
import Foundation
import os

/// Hands out realtime client secrets for the WebSocket.
public protocol RealtimeTokenProviding: Sendable {
    /// A secret that stays valid for at least the provider's refresh leeway.
    ///
    /// - Throws: ``XAIError`` (for example ``XAIError/missingAPIKey`` or
    ///   ``XAIError/invalidAPIKey(message:)``), or `CancellationError`.
    func clientSecret() async throws -> RealtimeClientSecret

    /// Drops the cached secret and any mint in flight. Call it when the API
    /// key changes or the server rejects a secret.
    func invalidate() async
}

/// Mints realtime client secrets on device, caches them and refreshes them
/// before they expire. No backend: the minter calls xAI with the user's key.
///
/// - **Caching.** A secret is reused until `refreshLeeway` (60 s by default)
///   before it expires, so a caller always gets at least that much validity
///   to open the WebSocket.
/// - **Expiry on the monotonic clock.** Expiry is tracked in
///   ``BlauClock/uptime``, starting from when the mint request was *sent*
///   (the secret can't have been minted earlier), so a wrong device clock
///   can't make a secret look fresher than it is. xAI's `expires_at` is used
///   only when it reports a shorter lifetime than requested.
/// - **One mint at a time.** Concurrent callers share the request in flight.
/// - **Retry with backoff** for network failures, rate limits and server
///   errors (``RetryPolicy/tokenMinting``). Key and account problems fail
///   immediately: retrying can't fix them.
/// - **Grace period.** If a refresh fails while the cached secret is still
///   valid, that secret is returned instead of the error.
/// - **Proactive refresh.** ``keepFresh()`` refreshes in the background so a
///   reconnect (session resumption, #39) never waits for a mint.
///
/// Should Blau ever ship on a shared xAI account, a minting proxy can be
/// plugged in as the ``RealtimeClientSecretMinting`` without changing callers.
public actor TokenProvider: RealtimeTokenProviding {
    public struct Configuration: Sendable, Equatable {
        /// Requested lifetime of each secret (`expires_after.seconds`).
        public var lifetime: Duration
        /// How long before expiry a secret is replaced.
        public var refreshLeeway: Duration
        public var retry: RetryPolicy

        public init(
            lifetime: Duration = .seconds(600),
            refreshLeeway: Duration = .seconds(60),
            retry: RetryPolicy = .tokenMinting
        ) {
            precondition(lifetime > .zero, "Lifetime must be positive")
            precondition(refreshLeeway >= .zero && refreshLeeway < lifetime, "Leeway must be shorter than the lifetime")
            self.lifetime = lifetime
            self.refreshLeeway = refreshLeeway
            self.retry = retry
        }

        /// Issue #33: 600 s secrets, refreshed 60 s before expiry.
        public static let standard = Configuration()
    }

    /// A cached secret with its deadlines on the provider's monotonic clock.
    struct CachedSecret: Sendable {
        var secret: RealtimeClientSecret
        /// When to stop handing it out and mint a new one.
        var refreshAt: Duration
        /// When it expires.
        var expiresAt: Duration
    }

    /// Below this remaining validity a cached secret isn't used as a
    /// fallback when a refresh fails.
    static let minimumFallbackValidity: Duration = .seconds(5)

    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "xai")

    private let minter: any RealtimeClientSecretMinting
    private let clock: any BlauClock
    public nonisolated let configuration: Configuration
    private let unitRandom: @Sendable () -> Double

    private var cached: CachedSecret?
    private var inFlight: Task<CachedSecret, any Error>?
    /// Bumped by `invalidate()`, so a mint that started before it is discarded.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - minter: Mints secrets, normally ``XAIClientSecretMinter``.
    ///   - clock: Source of time; tests pass a `ManualClock`.
    ///   - configuration: Lifetime, leeway and retry policy.
    ///   - unitRandom: Jitter source returning values in `0..<1`.
    public init(
        minter: any RealtimeClientSecretMinting,
        clock: any BlauClock = SystemClock(),
        configuration: Configuration = .standard,
        unitRandom: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.minter = minter
        self.clock = clock
        self.configuration = configuration
        self.unitRandom = unitRandom
    }

    // MARK: Public API

    public func clientSecret() async throws -> RealtimeClientSecret {
        while true {
            try Task.checkCancellation()
            if let cached, clock.uptime < cached.refreshAt {
                return cached.secret
            }

            let startedGeneration = generation
            let task = inFlight ?? startMint()
            let result = await task.result
            if inFlight == task {
                inFlight = nil
            }
            // Invalidated while minting (new key, rejected secret): the
            // result belongs to the old state, so mint again.
            guard generation == startedGeneration else { continue }

            switch result {
            case .success(let fresh):
                cached = fresh
                return fresh.secret
            case .failure(let error):
                if let cached, clock.uptime + Self.minimumFallbackValidity < cached.expiresAt {
                    Self.logger.error(
                        "Realtime token refresh failed; reusing the current token: \(String(describing: error), privacy: .public)"
                    )
                    return cached.secret
                }
                throw error
            }
        }
    }

    public func invalidate() {
        generation &+= 1
        cached = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Mints a secret now if none is cached, so the first WebSocket connect
    /// doesn't wait for it. Errors are swallowed; ``clientSecret()``
    /// reports them when the secret is actually needed.
    public func prefetch() async {
        _ = try? await clientSecret()
    }

    /// Keeps a fresh secret cached until the calling task is cancelled:
    /// refreshes `refreshLeeway` before each expiry. Run it for the length of
    /// a voice session. Stops early on errors only the user can fix
    /// (``XAIError/requiresUserAction``); other failures are retried after
    /// the retry policy's maximum delay.
    public func keepFresh() async {
        while !Task.isCancelled {
            do {
                _ = try await clientSecret()
            } catch let error as XAIError where error.requiresUserAction {
                Self.logger.error("Stopped refreshing realtime tokens: \(String(describing: error), privacy: .public)")
                return
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await clock.sleep(for: retryPause)
                } catch {
                    return
                }
                continue
            }

            // Past the refresh point after a successful call means the refresh
            // failed and the still-valid secret was handed out as a fallback:
            // back off instead of minting in a tight loop.
            guard let cached else { continue }  // Invalidated meanwhile: mint for the new key.
            let wait = cached.refreshAt - clock.uptime
            do {
                try await clock.sleep(for: wait > .zero ? wait : retryPause)
            } catch {
                return
            }
        }
    }

    /// How long ``keepFresh()`` waits before trying again after a failed
    /// refresh: the retry policy's longest delay, and at least a second.
    private var retryPause: Duration {
        max(configuration.retry.maximumDelay, .seconds(1))
    }

    // MARK: Minting

    private func startMint() -> Task<CachedSecret, any Error> {
        let task = Task { [minter, clock, configuration, unitRandom] in
            try await Self.mintWithRetry(
                minter: minter, clock: clock, configuration: configuration, unitRandom: unitRandom)
        }
        inFlight = task
        return task
    }

    static func mintWithRetry(
        minter: any RealtimeClientSecretMinting,
        clock: any BlauClock,
        configuration: Configuration,
        unitRandom: @Sendable () -> Double
    ) async throws -> CachedSecret {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let requestedAt = clock.uptime
            do throws(XAIError) {
                let secret = try await minter.mintClientSecret(lifetime: configuration.lifetime)
                logger.info("Minted a realtime token (attempt \(attempt, privacy: .public))")
                return cache(
                    secret, requestedAt: requestedAt, receivedAt: clock.uptime, wallClockNow: clock.now,
                    configuration: configuration)
            } catch {
                if error == .cancelled { throw CancellationError() }
                guard error.isRetryable, attempt < configuration.retry.maximumAttempts else {
                    logger.error(
                        "Realtime token mint failed (attempt \(attempt, privacy: .public)): \(String(describing: error), privacy: .public)"
                    )
                    throw error
                }
                var retryAfter: Duration?
                if case .rateLimited(let hint) = error {
                    retryAfter = hint
                }
                let delay = configuration.retry.delay(
                    beforeRetry: attempt - 1, retryAfter: retryAfter, unitRandom: unitRandom())
                logger.notice(
                    "Realtime token mint failed (attempt \(attempt, privacy: .public)); retrying in \(delay, privacy: .public)"
                )
                attempt += 1
                try await clock.sleep(for: delay)
            }
        }
    }

    /// Works out the deadlines of a freshly minted secret.
    static func cache(
        _ secret: RealtimeClientSecret,
        requestedAt: Duration,
        receivedAt: Duration,
        wallClockNow: Date,
        configuration: Configuration
    ) -> CachedSecret {
        // The secret was minted after the request was sent, so this is
        // never later than the real expiry.
        var expiresAt = requestedAt + configuration.lifetime
        if let serverExpiry = secret.expiresAt {
            let remaining = Duration.seconds(serverExpiry.timeIntervalSince(wallClockNow))
            // Only trust a shorter server lifetime when it is clearly
            // meaningful; a tiny or negative value means the device clock is
            // off, and honouring it would mint on every call.
            if remaining > configuration.refreshLeeway * 2 {
                expiresAt = min(expiresAt, receivedAt + remaining)
            }
        }
        return CachedSecret(secret: secret, refreshAt: expiresAt - configuration.refreshLeeway, expiresAt: expiresAt)
    }
}
