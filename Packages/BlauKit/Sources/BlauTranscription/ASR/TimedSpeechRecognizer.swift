import BlauCore

/// Wraps a recognizer that doesn't time itself so its calls are timed: when
/// the inner recognizer reports no model time for an `append(_:)` or
/// `finish(keepingTokensThrough:)` that ran chunks, the call's own duration
/// is reported instead.
///
/// `ParakeetEouRecognizer` measures its Core ML time and passes through
/// unchanged. `AlignedTranscriptRecognizer` runs no model and reports zero;
/// wrapped, its chunk bookkeeping shows up in
/// `StreamingTranscriberStatistics.modelTime`, so the long-session soak test
/// (#76) can tell whether per-chunk work grows over an hour on the hermetic
/// path too.
public struct TimedSpeechRecognizer: StreamingSpeechRecognizer {
    public let recognizer: any StreamingSpeechRecognizer
    private let clock: any BlauClock

    public init(_ recognizer: any StreamingSpeechRecognizer, clock: any BlauClock = SystemClock()) {
        self.recognizer = recognizer
        self.clock = clock
    }

    public var chunkSize: ASRChunkSize { recognizer.chunkSize }

    public func append(_ frame: AudioFrame) async throws -> RecognizerOutput {
        let started = clock.uptime
        let output = try await recognizer.append(frame)
        return timed(output, since: started)
    }

    public func finish(keepingTokensThrough cutoff: Int64?) async throws -> RecognizerOutput {
        let started = clock.uptime
        let output = try await recognizer.finish(keepingTokensThrough: cutoff)
        return timed(output, since: started)
    }

    public func reset() async {
        await recognizer.reset()
    }

    public func unload() async {
        await recognizer.unload()
    }

    public func startNextUtterance() async -> Bool {
        await recognizer.startNextUtterance()
    }

    private func timed(_ output: RecognizerOutput, since started: Duration) -> RecognizerOutput {
        guard output.chunks > 0, output.modelTime == .zero else { return output }
        var output = output
        output.modelTime = clock.uptime - started
        return output
    }
}
