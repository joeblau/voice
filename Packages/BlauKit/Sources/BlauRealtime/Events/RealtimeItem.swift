import Foundation

/// One item of conversation history: what the client creates with
/// `conversation.item.create` and what the server reports in
/// `conversation.item.added` and `response.output_item.*`.
///
/// Fields the server fills in (`id`, `object`, `status`) are optional, so the
/// same types work in both directions. Item types Blau doesn't model yet
/// (MCP calls, for example) decode to ``other(type:_:)`` with their JSON kept.
public enum RealtimeItem: Sendable, Hashable, Codable {
    /// A text or audio message from the user, the assistant or the system.
    case message(Message)
    /// A function call the assistant made (or one seeded into history).
    case functionCall(FunctionCall)
    /// The client's result for a function call.
    case functionCallOutput(FunctionCallOutput)
    /// A scripted line the server speaks verbatim with TTS (xAI extension).
    /// Don't send `response.create` after it: it is a complete turn.
    case forceMessage(ForceMessage)
    /// An item type Blau doesn't model, kept as JSON.
    case other(type: String, JSONValue)

    /// The item's `type` on the wire.
    public var type: String {
        switch self {
        case .message: "message"
        case .functionCall: "function_call"
        case .functionCallOutput: "function_call_output"
        case .forceMessage: "force_message"
        case .other(let type, _): type
        }
    }

    /// The item's id, when it has one.
    public var id: String? {
        switch self {
        case .message(let item): item.id
        case .functionCall(let item): item.id
        case .functionCallOutput(let item): item.id
        case .forceMessage: nil
        case .other(_, let json): json["id"]?.stringValue
        }
    }

    // MARK: Convenience

    /// A user message with one `input_text` part: how Blau sends a verified
    /// utterance (issue #1, "Turn control").
    public static func userText(_ text: String, id: String? = nil) -> RealtimeItem {
        .message(Message(id: id, role: .user, content: [.inputText(text)]))
    }

    /// An assistant text message, for seeding history after a reconnect.
    public static func assistantText(_ text: String, id: String? = nil) -> RealtimeItem {
        .message(Message(id: id, role: .assistant, content: [.text(text)]))
    }

    /// A system message carrying context for the model.
    public static func systemText(_ text: String, id: String? = nil) -> RealtimeItem {
        .message(Message(id: id, role: .system, content: [.inputText(text)]))
    }

    /// The result of the function call `callID`, as a JSON string.
    public static func functionOutput(callID: String, output: String) -> RealtimeItem {
        .functionCallOutput(FunctionCallOutput(callID: callID, output: output))
    }

    // MARK: Codable

    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "message": self = .message(try Message(from: decoder))
        case "function_call": self = .functionCall(try FunctionCall(from: decoder))
        case "function_call_output": self = .functionCallOutput(try FunctionCallOutput(from: decoder))
        case "force_message": self = .forceMessage(try ForceMessage(from: decoder))
        default: self = .other(type: type, try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .message(let item): try item.encode(to: encoder)
        case .functionCall(let item): try item.encode(to: encoder)
        case .functionCallOutput(let item): try item.encode(to: encoder)
        case .forceMessage(let item): try item.encode(to: encoder)
        case .other(_, let json):
            try json.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
    }
}

// MARK: - Item types

extension RealtimeItem {
    /// A text or audio message.
    public struct Message: Sendable, Hashable, Codable {
        public var id: String?
        /// `realtime.item` on server items.
        public var object: String?
        public var status: RealtimeItemStatus?
        public var role: RealtimeRole
        public var content: [ContentPart]

        public init(
            id: String? = nil, object: String? = nil, status: RealtimeItemStatus? = nil, role: RealtimeRole,
            content: [ContentPart]
        ) {
            self.id = id
            self.object = object
            self.status = status
            self.role = role
            self.content = content
        }

        /// The message's text: its text parts, or the transcripts of its
        /// audio parts, joined.
        public var text: String {
            content.compactMap { $0.text ?? $0.transcript }.joined()
        }

        private enum CodingKeys: String, CodingKey {
            case id, object, status, role, content
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            object = try container.decodeIfPresent(String.self, forKey: .object)
            status = try container.decodeIfPresent(RealtimeItemStatus.self, forKey: .status)
            role = try container.decode(RealtimeRole.self, forKey: .role)
            content = try container.decodeIfPresent([ContentPart].self, forKey: .content) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(object, forKey: .object)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        }
    }

    /// A function call the assistant made. `arguments` is a JSON string and
    /// is only complete on `response.output_item.done` and
    /// `response.function_call_arguments.done`.
    public struct FunctionCall: Sendable, Hashable, Codable {
        public var id: String?
        public var object: String?
        public var status: RealtimeItemStatus?
        public var callID: String?
        public var name: String?
        public var arguments: String?

        public init(
            id: String? = nil, object: String? = nil, status: RealtimeItemStatus? = nil, callID: String?,
            name: String?, arguments: String?
        ) {
            self.id = id
            self.object = object
            self.status = status
            self.callID = callID
            self.name = name
            self.arguments = arguments
        }

        private enum CodingKeys: String, CodingKey {
            case id, object, status, name, arguments
            case callID = "call_id"
        }
    }

    /// The client's result for function call `callID`. `output` is a JSON
    /// string.
    public struct FunctionCallOutput: Sendable, Hashable, Codable {
        public var id: String?
        public var object: String?
        public var status: RealtimeItemStatus?
        public var callID: String
        public var output: String

        public init(
            id: String? = nil, object: String? = nil, status: RealtimeItemStatus? = nil, callID: String,
            output: String
        ) {
            self.id = id
            self.object = object
            self.status = status
            self.callID = callID
            self.output = output
        }

        private enum CodingKeys: String, CodingKey {
            case id, object, status, output
            case callID = "call_id"
        }
    }

    /// A line the server speaks verbatim (xAI `force_message`).
    public struct ForceMessage: Sendable, Hashable, Codable {
        public var text: String
        /// When `false`, caller audio is dropped until playback completes.
        /// `nil` uses the server default (`true`).
        public var interruptible: Bool?

        public init(text: String, interruptible: Bool? = nil) {
            self.text = text
            self.interruptible = interruptible
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, interruptible
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let parts = try container.decodeIfPresent([ContentPart].self, forKey: .content) ?? []
            text = parts.compactMap(\.text).joined()
            interruptible = try container.decodeIfPresent(Bool.self, forKey: .interruptible)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(RealtimeRole.assistant, forKey: .role)
            try container.encode([ContentPart(type: .outputText, text: text)], forKey: .content)
            try container.encodeIfPresent(interruptible, forKey: .interruptible)
        }
    }
}

// MARK: - Content parts

/// One part of a message: text, or audio with its transcript.
public struct ContentPart: Sendable, Hashable, Codable {
    public var type: RealtimeContentType
    public var text: String?
    /// Audio bytes (base64 on the wire).
    public var audio: Data?
    public var transcript: String?

    public init(type: RealtimeContentType, text: String? = nil, audio: Data? = nil, transcript: String? = nil) {
        self.type = type
        self.text = text
        self.audio = audio
        self.transcript = transcript
    }

    /// User text.
    public static func inputText(_ text: String) -> ContentPart {
        ContentPart(type: .inputText, text: text)
    }

    /// Plain text.
    public static func text(_ text: String) -> ContentPart {
        ContentPart(type: .text, text: text)
    }
}
