import Foundation

/// Picks the streaming chunk size for the next utterance: the hook for the
/// thermal and power policy (#75).
///
/// `ParakeetStreamingTranscriber` asks it when it starts and whenever it
/// goes idle after an utterance, never mid-utterance (a recognizer's state
/// can't move between chunk sizes). When the answer differs from the
/// current recognizer's size, it asks its `RecognizerProvider` for a
/// recognizer of that size and switches if it gets one.
public protocol ASRChunkSizePolicy: Sendable {
    /// The chunk size to use from the next utterance on.
    func preferredChunkSize(current: ASRChunkSize) -> ASRChunkSize
}

/// Makes a recognizer for a chunk size, or returns `nil` when that size
/// isn't installed. The transcriber owns what it returns until it switches
/// to another size.
public typealias RecognizerProvider = @Sendable (ASRChunkSize) async throws -> (any StreamingSpeechRecognizer)?

/// Always the same chunk size.
public struct FixedASRChunkSizePolicy: ASRChunkSizePolicy {
    public let chunkSize: ASRChunkSize

    public init(_ chunkSize: ASRChunkSize = .ms320) {
        self.chunkSize = chunkSize
    }

    public func preferredChunkSize(current: ASRChunkSize) -> ASRChunkSize {
        chunkSize
    }
}

/// 320 ms chunks normally and 1280 ms chunks (about a quarter of the model
/// calls, at the cost of slower partials) while the device is hot.
///
/// It switches up at `ProcessInfo.ThermalState.serious` and only back down
/// once the state is `fair` or better, so a device hovering at a boundary
/// doesn't flip on every utterance.
public struct ThermalASRChunkSizePolicy: ASRChunkSizePolicy {
    /// The size while the device is cool.
    public let normal: ASRChunkSize
    /// The size under thermal pressure.
    public let reduced: ASRChunkSize
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState

    /// - Parameter thermalState: Reads the current state; tests pass a fake.
    public init(
        normal: ASRChunkSize = .ms320,
        reduced: ASRChunkSize = .ms1280,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    ) {
        self.normal = normal
        self.reduced = reduced
        self.thermalState = thermalState
    }

    public func preferredChunkSize(current: ASRChunkSize) -> ASRChunkSize {
        switch thermalState() {
        case .serious, .critical:
            reduced
        case .fair:
            // Hysteresis: keep whatever is running.
            current == reduced ? reduced : normal
        case .nominal:
            normal
        @unknown default:
            current
        }
    }
}
