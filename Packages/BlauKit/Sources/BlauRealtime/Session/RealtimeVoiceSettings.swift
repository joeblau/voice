import Foundation

/// The user's choices for how Grok sounds, thinks and looks things up, from
/// Settings → Voice and Settings → Search.
///
/// They go out in every `session.update` (``RealtimeSessionConfiguration``):
/// `voice`, `audio.output.speed`, `reasoning.effort` and the built-in
/// server tools in `tools`. Values are kept valid on the way in, so whatever
/// is stored is something the server accepts.
public struct RealtimeVoiceSettings: Sendable, Hashable, Codable {
    /// `audio.output.speed`'s documented range.
    public static let speedRange: ClosedRange<Double> = 0.7...1.5
    /// Speeds are kept to this step, so a slider can't send 1.0500000001.
    public static let speedStep = 0.05

    /// The reasoning efforts xAI documents for `grok-voice-think-fast-2.0`.
    public static let reasoningEfforts: [RealtimeReasoningEffort] = [.high, .disabled]

    /// xAI's defaults: Eve, normal speed, reasoning on.
    public static let `default` = RealtimeVoiceSettings()

    /// `session.voice`. Never empty.
    public var voice: RealtimeVoice {
        didSet { voice = voice.normalized ?? Self.default.voice }
    }

    /// `session.audio.output.speed`, within ``speedRange`` and rounded to
    /// ``speedStep``.
    public var speed: Double {
        didSet { speed = Self.clampedSpeed(speed) }
    }

    /// `session.reasoning.effort`. `.high` (xAI's default) reasons before
    /// answering; `.disabled` (`"none"`) answers sooner.
    public var reasoningEffort: RealtimeReasoningEffort

    /// xAI's server-side tools Grok may use (`web_search`, `x_search`), from
    /// Settings → Search. Off by default. Only
    /// ``RealtimeBuiltInTool/available`` tools are kept.
    public var builtInTools: Set<RealtimeBuiltInTool> {
        didSet { builtInTools = Self.supported(builtInTools) }
    }

    public init(
        voice: RealtimeVoice = .eve,
        speed: Double = 1.0,
        reasoningEffort: RealtimeReasoningEffort = .high,
        builtInTools: Set<RealtimeBuiltInTool> = []
    ) {
        self.voice = voice.normalized ?? .eve
        self.speed = Self.clampedSpeed(speed)
        self.reasoningEffort = reasoningEffort
        self.builtInTools = Self.supported(builtInTools)
    }

    /// The `session.tools` entries for ``builtInTools``, in a fixed order.
    public var builtInToolDefinitions: [RealtimeTool] {
        builtInTools.sorted().map(\.definition)
    }

    private static func supported(_ tools: Set<RealtimeBuiltInTool>) -> Set<RealtimeBuiltInTool> {
        tools.filter(RealtimeBuiltInTool.available.contains)
    }

    /// Clamps to ``speedRange`` and rounds to ``speedStep``. A non-finite
    /// value becomes 1.0.
    public static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        let stepped = (speed / speedStep).rounded() * speedStep
        // Re-derive from an integer number of hundredths so the stored value
        // is the shortest decimal (1.15, not 1.1500000000000001) on the wire.
        let hundredths = (min(max(stepped, speedRange.lowerBound), speedRange.upperBound) * 100).rounded()
        return hundredths / 100
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case voice, speed
        case reasoningEffort = "reasoning_effort"
        case builtInTools = "built_in_tools"
    }

    /// Lenient: a missing or unusable field falls back to its default, so
    /// settings written by an older or newer build never fail to load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            voice: (try? container.decodeIfPresent(RealtimeVoice.self, forKey: .voice)) ?? Self.default.voice,
            speed: (try? container.decodeIfPresent(Double.self, forKey: .speed)) ?? Self.default.speed,
            reasoningEffort: (try? container.decodeIfPresent(RealtimeReasoningEffort.self, forKey: .reasoningEffort))
                ?? Self.default.reasoningEffort,
            builtInTools: (try? container.decodeIfPresent([RealtimeBuiltInTool].self, forKey: .builtInTools))
                .map(Set.init) ?? Self.default.builtInTools)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voice, forKey: .voice)
        try container.encode(speed, forKey: .speed)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(builtInTools.sorted(), forKey: .builtInTools)
    }
}
