/// One hop of a turn's conversational latency (#74): the path from the end
/// of what the user said to the first frame of Grok's reply going out to
/// the speaker. docs/performance.md, "Latency budget", has the table.
///
/// ```
/// end of speech ─▶ EOU ─▶ commit ─▶ first audio delta ─▶ first buffer out
///   endOfUtterance   voiceGate  firstAudio          firstBuffer
/// └────────────────────────────── total ──────────────────────────────┘
/// ```
public enum LatencyHop: String, CaseIterable, Codable, Sendable, Hashable {
    /// The last speech sample captured → the end-of-utterance decision:
    /// the model's EOU debounce, or the transcriber's silence fallback when
    /// the model doesn't decide.
    case endOfUtterance
    /// The end-of-utterance decision → the utterance committed to Grok: the
    /// voice ID gate's hold on the final (#47).
    case voiceGate
    /// Committed → the first `response.output_audio.delta`: network and
    /// model. The `realtime.firstAudio` span.
    case firstAudio
    /// The first audio delta → its first frame rendered for the output: the
    /// jitter buffer's preroll. The `playback.firstBuffer` span.
    case firstBuffer
    /// End of speech → the reply's first frame rendered: everything above.
    case total

    /// The hop as the latency budget names it.
    public var title: String {
        switch self {
        case .endOfUtterance: "End of speech → EOU"
        case .voiceGate: "Voice gate"
        case .firstAudio: "Commit → first audio delta"
        case .firstBuffer: "First buffer scheduled"
        case .total: "End of speech → first audio out"
        }
    }

    /// The short label the performance HUD shows.
    public var shortTitle: String {
        switch self {
        case .endOfUtterance: "Speech → EOU"
        case .voiceGate: "Voice gate"
        case .firstAudio: "Commit → audio"
        case .firstBuffer: "First buffer"
        case .total: "Speech → audio"
        }
    }

    /// The canonical interval Instruments shows for the hop, when there is
    /// one. `asr.eou` begins at VAD's end-of-speech decision, VAD's 300 ms
    /// hangover after the speech really ended, so it is shorter than
    /// `endOfUtterance`, and the total has no interval: its start is only
    /// known in hindsight (see docs/performance.md).
    public var interval: PipelineInterval? {
        switch self {
        case .endOfUtterance: .asrEndOfUtterance
        case .voiceGate: .voiceIDGate
        case .firstAudio: .realtimeFirstAudio
        case .firstBuffer: .playbackFirstBuffer
        case .total: nil
        }
    }
}

/// The p50 targets for each hop of a turn (#74). A release is within budget
/// when every hop's median over a session of real turns is at or below its
/// target.
///
/// The hop targets add up to more than the total's: the end-of-utterance
/// hop is a range set by the debounce (300–800 ms), so a turn whose EOU
/// takes the full 800 ms has only 700 ms left for the rest.
public struct LatencyBudget: Codable, Sendable, Hashable {
    /// One hop's target.
    public struct Target: Codable, Sendable, Hashable {
        /// The p50 must be at or below this, in milliseconds.
        public var p50Milliseconds: Double
        /// The lowest p50 the design allows (the EOU debounce), in
        /// milliseconds. Informational: a lower median is not a failure.
        public var expectedMinimumMilliseconds: Double?

        public init(p50Milliseconds: Double, expectedMinimumMilliseconds: Double? = nil) {
            self.p50Milliseconds = p50Milliseconds
            self.expectedMinimumMilliseconds = expectedMinimumMilliseconds
        }

        /// `≤ 700 ms`, or `300–800 ms` for a range.
        public var description: String {
            let maximum = Int(p50Milliseconds.rounded())
            if let minimum = expectedMinimumMilliseconds {
                return "\(Int(minimum.rounded()))–\(maximum) ms"
            }
            return "≤ \(maximum) ms"
        }
    }

    public var endOfUtterance: Target
    public var voiceGate: Target
    public var firstAudio: Target
    public var firstBuffer: Target
    public var total: Target

    public init(endOfUtterance: Target, voiceGate: Target, firstAudio: Target, firstBuffer: Target, total: Target) {
        self.endOfUtterance = endOfUtterance
        self.voiceGate = voiceGate
        self.firstAudio = firstAudio
        self.firstBuffer = firstBuffer
        self.total = total
    }

    /// Blau's budget (#74): end of speech → EOU 300–800 ms, the voice gate
    /// at most 100 ms more, commit → first audio delta 700 ms (network and
    /// model), the first buffer scheduled within 50 ms; 1.5 s in total.
    public static let standard = LatencyBudget(
        endOfUtterance: Target(p50Milliseconds: 800, expectedMinimumMilliseconds: 300),
        voiceGate: Target(p50Milliseconds: 100),
        firstAudio: Target(p50Milliseconds: 700),
        firstBuffer: Target(p50Milliseconds: 50),
        total: Target(p50Milliseconds: 1_500))

    public subscript(hop: LatencyHop) -> Target {
        switch hop {
        case .endOfUtterance: endOfUtterance
        case .voiceGate: voiceGate
        case .firstAudio: firstAudio
        case .firstBuffer: firstBuffer
        case .total: total
        }
    }

    /// Whether a median of `p50Milliseconds` for `hop` is within budget.
    public func isWithinBudget(_ hop: LatencyHop, p50Milliseconds: Double) -> Bool {
        p50Milliseconds <= self[hop].p50Milliseconds
    }
}
