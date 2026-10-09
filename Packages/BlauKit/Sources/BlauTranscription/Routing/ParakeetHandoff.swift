import Synchronization

/// Hands a Parakeet transcriber loaded alongside the conversation audio to
/// `TranscriberRouter`'s first build, and points the performance HUD at the
/// Parakeet transcriber built last (#31).
///
/// ```swift
/// let parakeets = ParakeetHandoff()
/// let parakeet = TranscriberRouter.EngineProvider.parakeet(..., built: { parakeets.built($0) })
/// parakeets.preload(try? await parakeet.make() as? ParakeetStreamingTranscriber)
/// let router = TranscriberRouter(
///     parakeet: .init(isAvailable: parakeet.isAvailable,
///                     make: { try await parakeets.takePreloaded() ?? parakeet.make() }),
///     apple: ...)
/// ```
///
/// **The router owns the engines.** `latest` is a weak reference: when the
/// router switches away from Parakeet (critical memory pressure, the
/// background monitor's `systemSpeech`, the Settings toggle) it finishes
/// and drops the transcriber, and that frees Parakeet's Core ML models
/// before Apple's analyzer is loaded. The HUD's reference doesn't keep
/// them alive. Only a preloaded transcriber nobody has taken yet is held
/// strongly; `releasePreloaded()` finishes it if the router never does.
public final class ParakeetHandoff: Sendable {
    private struct State {
        var preloaded: ParakeetStreamingTranscriber?
        weak var latest: ParakeetStreamingTranscriber?
    }

    private let state = Mutex(State())

    public init() {}

    /// The Parakeet transcriber built last, while something else (the
    /// router, or the preload) still holds it.
    public var latest: ParakeetStreamingTranscriber? { state.withLock { $0.latest } }

    /// Records a transcriber the engine provider built
    /// (`TranscriberRouter.EngineProvider.parakeet(..., built:)`).
    public func built(_ transcriber: ParakeetStreamingTranscriber) {
        state.withLock { $0.latest = transcriber }
    }

    /// Keeps a transcriber loaded ahead of the router's first build.
    public func preload(_ transcriber: ParakeetStreamingTranscriber?) {
        state.withLock { $0.preloaded = transcriber }
    }

    /// The preloaded transcriber, once.
    public func takePreloaded() -> ParakeetStreamingTranscriber? {
        state.withLock { state in
            defer { state.preloaded = nil }
            return state.preloaded
        }
    }

    /// Finishes a preloaded transcriber nobody took, releasing its model.
    public func releasePreloaded() async {
        await takePreloaded()?.finish()
    }
}
