import Foundation

/// The `session.update` Blau sends: manual turns, the user's voice, speed
/// and reasoning effort, Blau's instructions, and 24 kHz PCM16 output.
///
/// | Field | Value | Why |
/// | ----- | ----- | --- |
/// | `turn_detection` | `{"type": null}` | Manual turns: only verified utterances reach Grok, and a manual session is billed for the audio exchanged, not for the time it is open (issue #1) |
/// | `voice` | Settings, default `eve` | |
/// | `audio.output.format` | `audio/pcm` @ 24 000 Hz | What the playback engine plays (#25) |
/// | `audio.output.transport` | `json` | Base64 deltas; set explicitly because output is strict about transport |
/// | `audio.output.speed` | Settings, 0.7–1.5, default 1.0 | |
/// | `reasoning.effort` | Settings, `high` or `none`, default `high` | |
/// | `instructions` | ``RealtimeInstructions`` | Persona, style, memory |
/// | `tools` | The registry's function tools (#38), then the built-in tools on in Settings | Omitted when there are none |
/// | `resumption` | `{"enabled": true}` | The server keeps the conversation so a dropped connection resumes it with `?conversation_id=` (#39). Both the first and the resuming session must opt in |
///
/// `audio.input` is not sent: Blau sends the *text* of each utterance, never
/// audio. The model is chosen on the WebSocket URL (`?model=`), so
/// `session.model` is not sent either.
public struct RealtimeSessionConfiguration: Sendable, Hashable {
    public var outputFormat: RealtimeSession.Audio.Format
    public var outputTransport: RealtimeAudioTransport
    public var instructions: RealtimeInstructions
    /// Opts every session in to resumption (`resumption.enabled`).
    public var resumption: Bool

    public init(
        outputFormat: RealtimeSession.Audio.Format = .pcm24kHz,
        outputTransport: RealtimeAudioTransport = .json,
        instructions: RealtimeInstructions = .blau,
        resumption: Bool = true
    ) {
        self.outputFormat = outputFormat
        self.outputTransport = outputTransport
        self.instructions = instructions
        self.resumption = resumption
    }

    /// Blau's configuration.
    public static let blau = RealtimeSessionConfiguration()

    /// The session to send in `session.update`.
    ///
    /// - Parameters:
    ///   - settings: The user's voice settings.
    ///   - memory: What Blau remembers, for the instructions.
    ///   - tools: The client-side function tools
    ///     (``RealtimeToolRegistry/definitions``). The built-in server tools
    ///     the user turned on (``RealtimeVoiceSettings/builtInTools``) are
    ///     added after them. With neither, `tools` is not sent.
    ///   - now: Today's date, for the instructions.
    ///   - timeZone: The user's time zone.
    public func session(
        settings: RealtimeVoiceSettings,
        memory: RealtimeMemoryContext = .empty,
        tools: [RealtimeTool] = [],
        now: Date,
        timeZone: TimeZone
    ) -> RealtimeSession {
        let tools = tools + settings.builtInToolDefinitions
        return RealtimeSession(
            instructions: instructions.render(memory: memory, tools: tools, now: now, timeZone: timeZone),
            reasoning: .init(effort: settings.reasoningEffort),
            voice: settings.voice.rawValue,
            turnDetection: .manual,
            resumption: resumption ? .init(enabled: true) : nil,
            audio: .init(output: .init(format: outputFormat, transport: outputTransport, speed: settings.speed)),
            tools: tools.isEmpty ? nil : tools
        )
    }
}
