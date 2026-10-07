/// A realtime session's configuration: what the client sends in
/// `session.update` and what the server echoes in `session.created` and
/// `session.updated`.
///
/// Every field is optional and omitted when `nil`, so a `session.update`
/// changes only what it sets. The server-only fields (`id`, `object`,
/// `modalities`) are `nil` on client updates. Blau's own session settings
/// (manual turns, voice, instructions, 24 kHz PCM output) are chosen in #35;
/// this type only models the wire format, per
/// https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech.
public struct RealtimeSession: Sendable, Hashable, Codable {
    /// Server-assigned session id.
    public var id: String?
    /// `realtime.session` on server events.
    public var object: String?
    /// `grok-voice-latest` or a pinned version. Usually chosen on the
    /// WebSocket URL instead.
    public var model: String?
    /// The system prompt.
    public var instructions: String?
    public var reasoning: Reasoning?
    /// A built-in voice (`eve`, `ara`, …) or a custom voice id.
    public var voice: String?
    /// Output modalities the server reports.
    public var modalities: [RealtimeModality]?
    /// `nil` leaves turn detection unchanged; ``TurnDetection/manual`` turns
    /// it off (Blau's mode: the client commits text turns itself).
    public var turnDetection: TurnDetection?
    /// Session resumption (xAI extension), keyed by the `conversation_id`
    /// query parameter on reconnect (#39).
    public var resumption: Resumption?
    public var audio: Audio?
    public var tools: [RealtimeTool]?
    /// Spoken-text replacements applied before TTS (xAI extension). Changes
    /// the audio only, not the transcript.
    public var replace: [String: String]?

    public init(
        id: String? = nil,
        object: String? = nil,
        model: String? = nil,
        instructions: String? = nil,
        reasoning: Reasoning? = nil,
        voice: String? = nil,
        modalities: [RealtimeModality]? = nil,
        turnDetection: TurnDetection? = nil,
        resumption: Resumption? = nil,
        audio: Audio? = nil,
        tools: [RealtimeTool]? = nil,
        replace: [String: String]? = nil
    ) {
        self.id = id
        self.object = object
        self.model = model
        self.instructions = instructions
        self.reasoning = reasoning
        self.voice = voice
        self.modalities = modalities
        self.turnDetection = turnDetection
        self.resumption = resumption
        self.audio = audio
        self.tools = tools
        self.replace = replace
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, model, instructions, reasoning, voice, modalities, resumption, audio, tools, replace
        case turnDetection = "turn_detection"
    }

    // MARK: Nested types

    public struct Reasoning: Sendable, Hashable, Codable {
        public var effort: RealtimeReasoningEffort?

        public init(effort: RealtimeReasoningEffort?) {
            self.effort = effort
        }
    }

    /// `turn_detection`. Its `type` is always written, as `null` for manual
    /// turns, which is how xAI documents turning server VAD off
    /// (`"turn_detection": {"type": null}`).
    public struct TurnDetection: Sendable, Hashable, Codable {
        /// `nil` for manual turns.
        public var type: RealtimeTurnDetectionType?
        /// With server VAD: re-engage the user after this much silence.
        public var idleTimeoutMilliseconds: Int?

        public init(type: RealtimeTurnDetectionType?, idleTimeoutMilliseconds: Int? = nil) {
            self.type = type
            self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        }

        /// No server VAD: the client commits each turn.
        public static let manual = TurnDetection(type: nil)
        /// Server VAD.
        public static let serverVAD = TurnDetection(type: .serverVAD)

        private enum CodingKeys: String, CodingKey {
            case type
            case idleTimeoutMilliseconds = "idle_timeout_ms"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(RealtimeTurnDetectionType.self, forKey: .type)
            idleTimeoutMilliseconds = try container.decodeIfPresent(Double.self, forKey: .idleTimeoutMilliseconds)
                .map { Int($0) }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(idleTimeoutMilliseconds, forKey: .idleTimeoutMilliseconds)
        }
    }

    public struct Resumption: Sendable, Hashable, Codable {
        public var enabled: Bool

        public init(enabled: Bool) {
            self.enabled = enabled
        }
    }

    public struct Audio: Sendable, Hashable, Codable {
        public var input: Input?
        public var output: Output?

        public init(input: Input? = nil, output: Output? = nil) {
            self.input = input
            self.output = output
        }

        public struct Input: Sendable, Hashable, Codable {
            public var format: Format?
            /// Preferred wire path for input audio. The server accepts both
            /// JSON appends and binary frames for the configured format.
            public var transport: RealtimeAudioTransport?
            public var transcription: Transcription?

            public init(
                format: Format? = nil, transport: RealtimeAudioTransport? = nil, transcription: Transcription? = nil
            ) {
                self.format = format
                self.transport = transport
                self.transcription = transcription
            }
        }

        public struct Output: Sendable, Hashable, Codable {
            public var format: Format?
            /// Wire path for assistant audio. Output is strict: audio arrives
            /// only on this transport, switching at the next response.
            public var transport: RealtimeAudioTransport?
            /// Playback speed, 0.7…1.5.
            public var speed: Double?

            public init(format: Format? = nil, transport: RealtimeAudioTransport? = nil, speed: Double? = nil) {
                self.format = format
                self.transport = transport
                self.speed = speed
            }
        }

        public struct Format: Sendable, Hashable, Codable {
            public var type: RealtimeAudioFormatType
            /// Sample rate in Hz (PCM only). The server default is 24 000.
            public var rate: Int?

            public init(type: RealtimeAudioFormatType, rate: Int? = nil) {
                self.type = type
                self.rate = rate
            }

            /// Little-endian PCM16 at 24 kHz, Blau's playback format (#25).
            public static let pcm24kHz = Format(type: .pcm, rate: 24_000)
        }

        public struct Transcription: Sendable, Hashable, Codable {
            /// BCP-47 language hint.
            public var languageHint: String?
            public var keyterms: [String]?

            public init(languageHint: String? = nil, keyterms: [String]? = nil) {
                self.languageHint = languageHint
                self.keyterms = keyterms
            }

            private enum CodingKeys: String, CodingKey {
                case keyterms
                case languageHint = "language_hint"
            }
        }
    }
}

// MARK: - Tools

/// A tool the model may call. Function tools are typed; the server-side
/// tools (`web_search`, `x_search`, `file_search`, `mcp`) are passed through
/// as JSON until Blau needs them (#38).
public enum RealtimeTool: Sendable, Hashable, Codable {
    /// A client-side function. `parameters` is a JSON Schema object.
    case function(name: String, description: String?, parameters: JSONValue?)
    /// Any other tool, as its full JSON object (including `type`).
    case other(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, function, name, description, parameters
    }

    private struct Function: Decodable {
        var name: String
        var description: String?
        var parameters: JSONValue?
    }

    public init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decodeIfPresent(String.self, forKey: .type) == "function" else {
            self = .other(json)
            return
        }
        // xAI's guide (and the OpenAI GA format) put the definition flat on
        // the tool; the AsyncAPI reference nests it under `function`. Accept
        // both.
        let function =
            try container.decodeIfPresent(Function.self, forKey: .function)
            ?? Function(
                name: try container.decode(String.self, forKey: .name),
                description: try container.decodeIfPresent(String.self, forKey: .description),
                parameters: try container.decodeIfPresent(JSONValue.self, forKey: .parameters))
        self = .function(name: function.name, description: function.description, parameters: function.parameters)
    }

    /// Function tools are written flat, as in the "Custom Function Tools"
    /// examples of xAI's speech-to-speech guide (the OpenAI GA shape):
    /// `{"type": "function", "name", "description", "parameters"}`.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .function(let name, let description, let parameters):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(parameters, forKey: .parameters)
        case .other(let json):
            try json.encode(to: encoder)
        }
    }
}
