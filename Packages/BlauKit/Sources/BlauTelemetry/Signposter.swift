import Synchronization

/// Emits signpost intervals and events for one `LogCategory`.
///
/// ```swift
/// let samples = Signposts.audio.withInterval("capture.frame") { resample(buffer) }
/// let text = try await Signposts.asr.withInterval(.asrChunk) { try await asr.process(chunk) }
/// Signposts.realtime.event("realtime.reconnect")
/// ```
///
/// Use the canonical `PipelineInterval` names for pipeline stages (see
/// docs/performance.md); ad-hoc names are fine for local investigations.
///
/// Every helper is safe to call when signposting is disabled: the measured
/// work still runs and its result or error is passed through unchanged.
/// Intervals always end, including when the work throws or is cancelled.
///
/// Components that want their instrumentation tested take a `Signposter` in
/// their initializer, defaulting to the `Signposts` static for their
/// category, and tests pass one backed by `RecordingSignpostBackend`.
public struct Signposter: Sendable {
    public let category: LogCategory
    public let backend: any SignpostBackend

    public init(category: LogCategory, backend: any SignpostBackend) {
        self.category = category
        self.backend = backend
    }

    /// A signposter that emits real `os_signpost` records in Blau's
    /// subsystem under `category`.
    public init(category: LogCategory) {
        self.init(category: category, backend: OSSignpostBackend(category: category))
    }

    /// A signposter that never emits anything.
    public static func disabled(_ category: LogCategory) -> Signposter {
        Signposter(category: category, backend: OSSignpostBackend.disabled)
    }

    /// Whether intervals and events are currently being recorded.
    public var isEnabled: Bool { backend.isEnabled }

    // MARK: Intervals around work

    /// Runs `body` inside an interval named `name` and returns its result.
    public func withInterval<T, E: Error>(_ name: StaticString, _ body: () throws(E) -> T) throws(E) -> T {
        guard backend.isEnabled else { return try body() }
        let token = backend.beginInterval(name)
        defer { backend.endInterval(name, token) }
        return try body()
    }

    /// Runs async `body` inside an interval named `name` and returns its
    /// result. The interval spans every suspension, so it measures wall time
    /// from start to finish, and it ends even if the task is cancelled.
    ///
    /// `body` runs on the caller's actor (`isolation`), so it can touch the
    /// caller's state and return non-`Sendable` values.
    public func withInterval<T, E: Error>(
        _ name: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(E) -> T
    ) async throws(E) -> T {
        guard backend.isEnabled else { return try await body() }
        let token = backend.beginInterval(name)
        defer { backend.endInterval(name, token) }
        return try await body()
    }

    /// Runs `body` inside the canonical interval `interval`.
    public func withInterval<T, E: Error>(_ interval: PipelineInterval, _ body: () throws(E) -> T) throws(E) -> T {
        try withInterval(interval.name, body)
    }

    /// Runs async `body` inside the canonical interval `interval`.
    public func withInterval<T, E: Error>(
        _ interval: PipelineInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(E) -> T
    ) async throws(E) -> T {
        try await withInterval(interval.name, isolation: isolation, body)
    }

    // MARK: Manual intervals

    /// Begins an interval that ends when you call `end()` on the result.
    ///
    /// For spans that don't fit in one closure, such as `realtime.firstAudio`
    /// (from committing a turn to the first audio delta arriving in a later
    /// callback) or `asr.eou`.
    public func beginInterval(_ name: StaticString) -> SignpostInterval {
        guard backend.isEnabled else { return SignpostInterval(name: name, category: category, backend: nil) }
        return SignpostInterval(name: name, category: category, backend: backend)
    }

    /// Begins the canonical interval `interval`. See `beginInterval(_:)`.
    public func beginInterval(_ interval: PipelineInterval) -> SignpostInterval {
        beginInterval(interval.name)
    }

    // MARK: Events

    /// Emits a point-in-time event named `name`, such as a reconnect or a
    /// barge-in.
    public func event(_ name: StaticString) {
        guard backend.isEnabled else { return }
        backend.emitEvent(name)
    }
}

/// An interval begun with `Signposter.beginInterval(_:)`. It stays open until
/// `end()` is called; ending it again does nothing.
///
/// Safe to pass between tasks and actors: `end()` can be called from any
/// thread, and exactly one call ends the interval.
public final class SignpostInterval: Sendable {
    public let name: StaticString
    public let category: LogCategory

    /// `nil` when signposting was disabled at `begin`; then `end()` only
    /// flips `isEnded`.
    private let backend: (any SignpostBackend)?
    private let token: SignpostIntervalToken?
    private let ended = Atomic<Bool>(false)

    init(name: StaticString, category: LogCategory, backend: (any SignpostBackend)?) {
        self.name = name
        self.category = category
        self.backend = backend
        self.token = backend?.beginInterval(name)
    }

    /// Whether `end()` has been called.
    public var isEnded: Bool { ended.load(ordering: .acquiring) }

    /// Ends the interval.
    ///
    /// - Returns: `true` if this call ended it, `false` if it had already
    ///   ended.
    @discardableResult
    public func end() -> Bool {
        guard ended.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            return false
        }
        if let backend, let token {
            backend.endInterval(name, token)
        }
        return true
    }
}
