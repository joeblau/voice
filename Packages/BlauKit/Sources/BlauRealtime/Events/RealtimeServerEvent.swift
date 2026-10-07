import Foundation

/// An event the xAI realtime API sends to Blau.
///
/// Covers every server event in xAI's realtime reference
/// (https://docs.x.ai/voice-realtime.ws.json), plus the OpenAI-beta names
/// xAI still emits for some of them (`response.text.delta`,
/// `response.audio.delta`, …) and `conversation.item.created`, which
/// resumption uses to replay history. A type Blau doesn't know, or a known
/// type whose payload doesn't parse, becomes ``unknown(_:)`` with the raw
/// JSON kept, so a protocol change never ends the session.
///
/// Decode frames with ``RealtimeEventCoding/decodeServerEvent(_:)``, which
/// never throws.
///
/// Payload fields are optional unless the event is useless without them
/// (the `delta` of a delta event, the `session` of `session.created`): the
/// reference marks almost nothing as required, and dropping an audio delta
/// because an index is missing would be worse than a `nil`.
public enum RealtimeServerEvent: Sendable, Hashable, Codable {
    // Session
    /// `session.created`: sent on connect with the session's defaults.
    case sessionCreated(SessionEvent)
    /// `session.updated`: acknowledges `session.update`.
    case sessionUpdated(SessionEvent)
    /// `conversation.created`: carries the conversation id resumption needs.
    case conversationCreated(ConversationCreated)

    // Input audio buffer
    case inputAudioBufferSpeechStarted(SpeechBoundary)
    case inputAudioBufferSpeechStopped(SpeechBoundary)
    case inputAudioBufferCommitted(InputAudioBufferCommitted)
    case inputAudioBufferCleared(Acknowledgement)
    /// The `idle_timeout_ms` timer fired and the server committed a silent
    /// turn.
    case inputAudioBufferTimeoutTriggered(InputAudioBufferTimeout)
    /// A DTMF keypress (SIP sessions only).
    case inputAudioBufferDTMFEventReceived(DTMFEvent)

    // Conversation
    /// `conversation.item.added`: an item joined the history.
    case conversationItemAdded(ConversationItemEvent)
    /// `conversation.item.created`: resumption replays prior turns with it.
    case conversationItemCreated(ConversationItemEvent)
    case conversationItemDeleted(ConversationItemDeleted)
    /// Confirms `conversation.item.truncate`, with the transcript that was
    /// kept (xAI extension).
    case conversationItemTruncated(ConversationItemTruncated)
    case conversationItemInputAudioTranscriptionCompleted(InputAudioTranscription)
    /// The cumulative transcript of the user's audio so far.
    case conversationItemInputAudioTranscriptionUpdated(InputAudioTranscription)

    // Responses
    case responseCreated(ResponseEvent)
    case responseOutputItemAdded(OutputItemEvent)
    case responseOutputItemDone(OutputItemEvent)
    case responseContentPartAdded(ContentPartEvent)
    case responseContentPartDone(ContentPartEvent)
    /// Assistant audio. Also produced from binary frames when the session's
    /// output transport is `binary` (see ``AudioDelta``).
    case responseOutputAudioDelta(AudioDelta)
    case responseOutputAudioDone(ContentDone)
    case responseOutputAudioTranscriptDelta(TextDelta)
    case responseOutputAudioTranscriptDone(ContentDone)
    /// Text-mode output: `response.output_text.delta`, or its older name
    /// `response.text.delta`.
    case responseOutputTextDelta(TextDelta)
    /// `response.output_text.done` (or `response.text.done`).
    case responseOutputTextDone(ContentDone)
    case responseFunctionCallArgumentsDelta(ArgumentsDelta)
    /// A function call is ready to run with complete arguments (#38).
    case responseFunctionCallArgumentsDone(ArgumentsDone)
    /// The response finished: completed, cancelled or incomplete, with usage.
    case responseDone(ResponseEvent)

    // Remote MCP tools
    case mcpListToolsInProgress(MCPEvent)
    case mcpListToolsCompleted(MCPEvent)
    case mcpListToolsFailed(MCPEvent)
    case responseMCPCallArgumentsDelta(ArgumentsDelta)
    case responseMCPCallArgumentsDone(ArgumentsDone)
    case responseMCPCallInProgress(MCPEvent)
    case responseMCPCallCompleted(MCPEvent)
    case responseMCPCallFailed(MCPEvent)

    /// `error`. Most errors leave the session open.
    case error(ErrorEvent)

    /// A type Blau doesn't model, or a payload that didn't parse.
    case unknown(UnknownEvent)

    // MARK: Types

    /// The canonical wire type of each case, as written by `encode(to:)`.
    public var type: String {
        switch self {
        case .sessionCreated: "session.created"
        case .sessionUpdated: "session.updated"
        case .conversationCreated: "conversation.created"
        case .inputAudioBufferSpeechStarted: "input_audio_buffer.speech_started"
        case .inputAudioBufferSpeechStopped: "input_audio_buffer.speech_stopped"
        case .inputAudioBufferCommitted: "input_audio_buffer.committed"
        case .inputAudioBufferCleared: "input_audio_buffer.cleared"
        case .inputAudioBufferTimeoutTriggered: "input_audio_buffer.timeout_triggered"
        case .inputAudioBufferDTMFEventReceived: "input_audio_buffer.dtmf_event_received"
        case .conversationItemAdded: "conversation.item.added"
        case .conversationItemCreated: "conversation.item.created"
        case .conversationItemDeleted: "conversation.item.deleted"
        case .conversationItemTruncated: "conversation.item.truncated"
        case .conversationItemInputAudioTranscriptionCompleted:
            "conversation.item.input_audio_transcription.completed"
        case .conversationItemInputAudioTranscriptionUpdated: "conversation.item.input_audio_transcription.updated"
        case .responseCreated: "response.created"
        case .responseOutputItemAdded: "response.output_item.added"
        case .responseOutputItemDone: "response.output_item.done"
        case .responseContentPartAdded: "response.content_part.added"
        case .responseContentPartDone: "response.content_part.done"
        case .responseOutputAudioDelta: "response.output_audio.delta"
        case .responseOutputAudioDone: "response.output_audio.done"
        case .responseOutputAudioTranscriptDelta: "response.output_audio_transcript.delta"
        case .responseOutputAudioTranscriptDone: "response.output_audio_transcript.done"
        case .responseOutputTextDelta: "response.output_text.delta"
        case .responseOutputTextDone: "response.output_text.done"
        case .responseFunctionCallArgumentsDelta: "response.function_call_arguments.delta"
        case .responseFunctionCallArgumentsDone: "response.function_call_arguments.done"
        case .responseDone: "response.done"
        case .mcpListToolsInProgress: "mcp_list_tools.in_progress"
        case .mcpListToolsCompleted: "mcp_list_tools.completed"
        case .mcpListToolsFailed: "mcp_list_tools.failed"
        case .responseMCPCallArgumentsDelta: "response.mcp_call_arguments.delta"
        case .responseMCPCallArgumentsDone: "response.mcp_call_arguments.done"
        case .responseMCPCallInProgress: "response.mcp_call.in_progress"
        case .responseMCPCallCompleted: "response.mcp_call.completed"
        case .responseMCPCallFailed: "response.mcp_call.failed"
        case .error: "error"
        case .unknown(let event): event.type
        }
    }

    /// Older (OpenAI beta) names xAI documents as equivalent, mapped to the
    /// canonical name they decode as.
    public static let typeAliases: [String: String] = [
        "response.text.delta": "response.output_text.delta",
        "response.text.done": "response.output_text.done",
        "response.audio.delta": "response.output_audio.delta",
        "response.audio.done": "response.output_audio.done",
        "response.audio_transcript.delta": "response.output_audio_transcript.delta",
        "response.audio_transcript.done": "response.output_audio_transcript.done",
    ]

    /// Every type that decodes to a typed case, aliases included.
    public static let knownTypes: Set<String> = Set(decoders.keys)

    /// Whether this is ``unknown(_:)``.
    public var isUnknown: Bool {
        if case .unknown = self { true } else { false }
    }

    // MARK: Codable

    private enum TypeKey: String, CodingKey {
        case type
    }

    /// Thrown by `init(from:)` for a type with no typed case;
    /// ``RealtimeEventCoding/decodeServerEvent(_:)`` turns it into
    /// ``unknown(_:)``.
    struct UnknownTypeError: Error {
        var type: String
    }

    private typealias Decode = @Sendable (any Decoder) throws -> RealtimeServerEvent

    private static let decoders: [String: Decode] = {
        var table: [String: Decode] = [
            "session.created": { .sessionCreated(try SessionEvent(from: $0)) },
            "session.updated": { .sessionUpdated(try SessionEvent(from: $0)) },
            "conversation.created": { .conversationCreated(try ConversationCreated(from: $0)) },
            "input_audio_buffer.speech_started": { .inputAudioBufferSpeechStarted(try SpeechBoundary(from: $0)) },
            "input_audio_buffer.speech_stopped": { .inputAudioBufferSpeechStopped(try SpeechBoundary(from: $0)) },
            "input_audio_buffer.committed": { .inputAudioBufferCommitted(try InputAudioBufferCommitted(from: $0)) },
            "input_audio_buffer.cleared": { .inputAudioBufferCleared(try Acknowledgement(from: $0)) },
            "input_audio_buffer.timeout_triggered": {
                .inputAudioBufferTimeoutTriggered(try InputAudioBufferTimeout(from: $0))
            },
            "input_audio_buffer.dtmf_event_received": { .inputAudioBufferDTMFEventReceived(try DTMFEvent(from: $0)) },
            "conversation.item.added": { .conversationItemAdded(try ConversationItemEvent(from: $0)) },
            "conversation.item.created": { .conversationItemCreated(try ConversationItemEvent(from: $0)) },
            "conversation.item.deleted": { .conversationItemDeleted(try ConversationItemDeleted(from: $0)) },
            "conversation.item.truncated": { .conversationItemTruncated(try ConversationItemTruncated(from: $0)) },
            "conversation.item.input_audio_transcription.completed": {
                .conversationItemInputAudioTranscriptionCompleted(try InputAudioTranscription(from: $0))
            },
            "conversation.item.input_audio_transcription.updated": {
                .conversationItemInputAudioTranscriptionUpdated(try InputAudioTranscription(from: $0))
            },
            "response.created": { .responseCreated(try ResponseEvent(from: $0)) },
            "response.output_item.added": { .responseOutputItemAdded(try OutputItemEvent(from: $0)) },
            "response.output_item.done": { .responseOutputItemDone(try OutputItemEvent(from: $0)) },
            "response.content_part.added": { .responseContentPartAdded(try ContentPartEvent(from: $0)) },
            "response.content_part.done": { .responseContentPartDone(try ContentPartEvent(from: $0)) },
            "response.output_audio.delta": { .responseOutputAudioDelta(try AudioDelta(from: $0)) },
            "response.output_audio.done": { .responseOutputAudioDone(try ContentDone(from: $0)) },
            "response.output_audio_transcript.delta": { .responseOutputAudioTranscriptDelta(try TextDelta(from: $0)) },
            "response.output_audio_transcript.done": { .responseOutputAudioTranscriptDone(try ContentDone(from: $0)) },
            "response.output_text.delta": { .responseOutputTextDelta(try TextDelta(from: $0)) },
            "response.output_text.done": { .responseOutputTextDone(try ContentDone(from: $0)) },
            "response.function_call_arguments.delta": {
                .responseFunctionCallArgumentsDelta(try ArgumentsDelta(from: $0))
            },
            "response.function_call_arguments.done": {
                .responseFunctionCallArgumentsDone(try ArgumentsDone(from: $0))
            },
            "response.done": { .responseDone(try ResponseEvent(from: $0)) },
            "mcp_list_tools.in_progress": { .mcpListToolsInProgress(try MCPEvent(from: $0)) },
            "mcp_list_tools.completed": { .mcpListToolsCompleted(try MCPEvent(from: $0)) },
            "mcp_list_tools.failed": { .mcpListToolsFailed(try MCPEvent(from: $0)) },
            "response.mcp_call_arguments.delta": { .responseMCPCallArgumentsDelta(try ArgumentsDelta(from: $0)) },
            "response.mcp_call_arguments.done": { .responseMCPCallArgumentsDone(try ArgumentsDone(from: $0)) },
            "response.mcp_call.in_progress": { .responseMCPCallInProgress(try MCPEvent(from: $0)) },
            "response.mcp_call.completed": { .responseMCPCallCompleted(try MCPEvent(from: $0)) },
            "response.mcp_call.failed": { .responseMCPCallFailed(try MCPEvent(from: $0)) },
            "error": { .error(try ErrorEvent(from: $0)) },
        ]
        for (alias, canonical) in typeAliases {
            table[alias] = table[canonical]
        }
        return table
    }()

    /// Decodes a typed event. Throws `UnknownTypeError` for a type with no
    /// typed case, and `DecodingError` for a malformed payload. Prefer
    /// ``RealtimeEventCoding/decodeServerEvent(_:)``, which handles both.
    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        guard let decode = Self.decoders[type] else {
            throw UnknownTypeError(type: type)
        }
        self = try decode(decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .unknown(let event):
            // Write the original JSON back unchanged.
            try event.json.encode(to: encoder)
            return
        case .sessionCreated(let payload), .sessionUpdated(let payload): try payload.encode(to: encoder)
        case .conversationCreated(let payload): try payload.encode(to: encoder)
        case .inputAudioBufferSpeechStarted(let payload), .inputAudioBufferSpeechStopped(let payload):
            try payload.encode(to: encoder)
        case .inputAudioBufferCommitted(let payload): try payload.encode(to: encoder)
        case .inputAudioBufferCleared(let payload): try payload.encode(to: encoder)
        case .inputAudioBufferTimeoutTriggered(let payload): try payload.encode(to: encoder)
        case .inputAudioBufferDTMFEventReceived(let payload): try payload.encode(to: encoder)
        case .conversationItemAdded(let payload), .conversationItemCreated(let payload):
            try payload.encode(to: encoder)
        case .conversationItemDeleted(let payload): try payload.encode(to: encoder)
        case .conversationItemTruncated(let payload): try payload.encode(to: encoder)
        case .conversationItemInputAudioTranscriptionCompleted(let payload),
            .conversationItemInputAudioTranscriptionUpdated(let payload):
            try payload.encode(to: encoder)
        case .responseCreated(let payload), .responseDone(let payload): try payload.encode(to: encoder)
        case .responseOutputItemAdded(let payload), .responseOutputItemDone(let payload):
            try payload.encode(to: encoder)
        case .responseContentPartAdded(let payload), .responseContentPartDone(let payload):
            try payload.encode(to: encoder)
        case .responseOutputAudioDelta(let payload): try payload.encode(to: encoder)
        case .responseOutputAudioDone(let payload), .responseOutputAudioTranscriptDone(let payload),
            .responseOutputTextDone(let payload):
            try payload.encode(to: encoder)
        case .responseOutputAudioTranscriptDelta(let payload), .responseOutputTextDelta(let payload):
            try payload.encode(to: encoder)
        case .responseFunctionCallArgumentsDelta(let payload), .responseMCPCallArgumentsDelta(let payload):
            try payload.encode(to: encoder)
        case .responseFunctionCallArgumentsDone(let payload), .responseMCPCallArgumentsDone(let payload):
            try payload.encode(to: encoder)
        case .mcpListToolsInProgress(let payload), .mcpListToolsCompleted(let payload),
            .mcpListToolsFailed(let payload), .responseMCPCallInProgress(let payload),
            .responseMCPCallCompleted(let payload), .responseMCPCallFailed(let payload):
            try payload.encode(to: encoder)
        case .error(let payload): try payload.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
    }
}

// MARK: - Payloads

extension RealtimeServerEvent {
    /// An event that carries only its id (`input_audio_buffer.cleared`).
    public struct Acknowledgement: Sendable, Hashable, Codable {
        public var eventID: String?

        public init(eventID: String? = nil) {
            self.eventID = eventID
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
        }
    }

    /// `session.created` and `session.updated`.
    public struct SessionEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var session: RealtimeSession

        public init(eventID: String? = nil, session: RealtimeSession) {
            self.eventID = eventID
            self.session = session
        }

        private enum CodingKeys: String, CodingKey {
            case session
            case eventID = "event_id"
        }
    }

    /// `conversation.created`.
    public struct ConversationCreated: Sendable, Hashable, Codable {
        public var eventID: String?
        public var conversation: Conversation

        public init(eventID: String? = nil, conversation: Conversation) {
            self.eventID = eventID
            self.conversation = conversation
        }

        public struct Conversation: Sendable, Hashable, Codable {
            /// Pass it back as `?conversation_id=` to resume (#39).
            public var id: String
            public var object: String?

            public init(id: String, object: String? = nil) {
                self.id = id
                self.object = object
            }
        }

        private enum CodingKeys: String, CodingKey {
            case conversation
            case eventID = "event_id"
        }
    }

    /// `input_audio_buffer.speech_started` (with `audioStartMilliseconds`)
    /// and `.speech_stopped` (with `audioEndMilliseconds`). Server VAD only.
    public struct SpeechBoundary: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String?
        public var audioStartMilliseconds: Int?
        public var audioEndMilliseconds: Int?

        public init(
            eventID: String? = nil, itemID: String? = nil, audioStartMilliseconds: Int? = nil,
            audioEndMilliseconds: Int? = nil
        ) {
            self.eventID = eventID
            self.itemID = itemID
            self.audioStartMilliseconds = audioStartMilliseconds
            self.audioEndMilliseconds = audioEndMilliseconds
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case itemID = "item_id"
            case audioStartMilliseconds = "audio_start_ms"
            case audioEndMilliseconds = "audio_end_ms"
        }
    }

    /// `input_audio_buffer.committed`.
    public struct InputAudioBufferCommitted: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String?
        public var previousItemID: String?

        public init(eventID: String? = nil, itemID: String? = nil, previousItemID: String? = nil) {
            self.eventID = eventID
            self.itemID = itemID
            self.previousItemID = previousItemID
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case itemID = "item_id"
            case previousItemID = "previous_item_id"
        }
    }

    /// `input_audio_buffer.timeout_triggered`.
    public struct InputAudioBufferTimeout: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String?
        public var previousItemID: String?
        public var audioStartMilliseconds: Int?
        public var audioEndMilliseconds: Int?

        public init(
            eventID: String? = nil, itemID: String? = nil, previousItemID: String? = nil,
            audioStartMilliseconds: Int? = nil, audioEndMilliseconds: Int? = nil
        ) {
            self.eventID = eventID
            self.itemID = itemID
            self.previousItemID = previousItemID
            self.audioStartMilliseconds = audioStartMilliseconds
            self.audioEndMilliseconds = audioEndMilliseconds
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case itemID = "item_id"
            case previousItemID = "previous_item_id"
            case audioStartMilliseconds = "audio_start_ms"
            case audioEndMilliseconds = "audio_end_ms"
        }
    }

    /// `input_audio_buffer.dtmf_event_received`.
    public struct DTMFEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        /// `0`–`9`, `*` or `#` (the wire field is `event`).
        public var digit: String
        /// Unix seconds.
        public var receivedAt: Int?

        public init(eventID: String? = nil, digit: String, receivedAt: Int? = nil) {
            self.eventID = eventID
            self.digit = digit
            self.receivedAt = receivedAt
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case digit = "event"
            case receivedAt = "received_at"
        }
    }

    /// `conversation.item.added` and `conversation.item.created`.
    public struct ConversationItemEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var previousItemID: String?
        public var item: RealtimeItem

        public init(eventID: String? = nil, previousItemID: String? = nil, item: RealtimeItem) {
            self.eventID = eventID
            self.previousItemID = previousItemID
            self.item = item
        }

        private enum CodingKeys: String, CodingKey {
            case item
            case eventID = "event_id"
            case previousItemID = "previous_item_id"
        }
    }

    /// `conversation.item.deleted`.
    public struct ConversationItemDeleted: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String

        public init(eventID: String? = nil, itemID: String) {
            self.eventID = eventID
            self.itemID = itemID
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case itemID = "item_id"
        }
    }

    /// `conversation.item.truncated`.
    public struct ConversationItemTruncated: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String
        public var contentIndex: Int?
        /// How much audio remains, in milliseconds.
        public var audioEndMilliseconds: Int?
        /// The transcript up to the cut (xAI extension), for updating what
        /// the chat shows after a barge-in.
        public var transcript: String?

        public init(
            eventID: String? = nil, itemID: String, contentIndex: Int? = nil, audioEndMilliseconds: Int? = nil,
            transcript: String? = nil
        ) {
            self.eventID = eventID
            self.itemID = itemID
            self.contentIndex = contentIndex
            self.audioEndMilliseconds = audioEndMilliseconds
            self.transcript = transcript
        }

        private enum CodingKeys: String, CodingKey {
            case transcript
            case eventID = "event_id"
            case itemID = "item_id"
            case contentIndex = "content_index"
            case audioEndMilliseconds = "audio_end_ms"
        }
    }

    /// `conversation.item.input_audio_transcription.completed` and
    /// `.updated` (cumulative, may revise earlier text).
    public struct InputAudioTranscription: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String?
        public var transcript: String

        public init(eventID: String? = nil, itemID: String? = nil, transcript: String) {
            self.eventID = eventID
            self.itemID = itemID
            self.transcript = transcript
        }

        private enum CodingKeys: String, CodingKey {
            case transcript
            case eventID = "event_id"
            case itemID = "item_id"
        }
    }

    /// `response.created` and `response.done`.
    public struct ResponseEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var response: RealtimeResponse

        public init(eventID: String? = nil, response: RealtimeResponse) {
            self.eventID = eventID
            self.response = response
        }

        private enum CodingKeys: String, CodingKey {
            case response
            case eventID = "event_id"
        }
    }

    /// `response.output_item.added` and `.done`.
    public struct OutputItemEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var outputIndex: Int?
        public var item: RealtimeItem

        public init(eventID: String? = nil, responseID: String? = nil, outputIndex: Int? = nil, item: RealtimeItem) {
            self.eventID = eventID
            self.responseID = responseID
            self.outputIndex = outputIndex
            self.item = item
        }

        private enum CodingKeys: String, CodingKey {
            case item
            case eventID = "event_id"
            case responseID = "response_id"
            case outputIndex = "output_index"
        }
    }

    /// `response.content_part.added` and `.done`.
    public struct ContentPartEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var contentIndex: Int?
        public var part: ContentPart

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            contentIndex: Int? = nil, part: ContentPart
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.contentIndex = contentIndex
            self.part = part
        }

        private enum CodingKeys: String, CodingKey {
            case part
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case contentIndex = "content_index"
        }
    }

    /// `response.output_audio.delta`: a chunk of assistant audio in the
    /// session's output format (24 kHz PCM16 for Blau).
    ///
    /// With binary output transport the server sends the bytes as WebSocket
    /// binary frames with no header. ``RealtimeClient`` turns each frame into
    /// one of these, filling `responseID`, `itemID` and `contentIndex` from
    /// the response, item and part in progress, with `eventID` `nil` and
    /// ``isBinaryFrame`` set.
    public struct AudioDelta: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var contentIndex: Int?
        /// The audio bytes (base64 `delta` on the wire).
        public var audio: Data
        /// Whether this came from a binary frame rather than a JSON event.
        public var isBinaryFrame: Bool

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            contentIndex: Int? = nil, audio: Data, isBinaryFrame: Bool = false
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.contentIndex = contentIndex
            self.audio = audio
            self.isBinaryFrame = isBinaryFrame
        }

        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case contentIndex = "content_index"
            case audio = "delta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
            responseID = try container.decodeIfPresent(String.self, forKey: .responseID)
            itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
            outputIndex = try container.decodeIfPresent(Int.self, forKey: .outputIndex)
            contentIndex = try container.decodeIfPresent(Int.self, forKey: .contentIndex)
            audio = try container.decode(Data.self, forKey: .audio)
            isBinaryFrame = false
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(eventID, forKey: .eventID)
            try container.encodeIfPresent(responseID, forKey: .responseID)
            try container.encodeIfPresent(itemID, forKey: .itemID)
            try container.encodeIfPresent(outputIndex, forKey: .outputIndex)
            try container.encodeIfPresent(contentIndex, forKey: .contentIndex)
            try container.encode(audio, forKey: .audio)
        }
    }

    /// A streamed text fragment: the assistant's audio transcript or text
    /// output.
    public struct TextDelta: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var contentIndex: Int?
        public var delta: String

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            contentIndex: Int? = nil, delta: String
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.contentIndex = contentIndex
            self.delta = delta
        }

        private enum CodingKeys: String, CodingKey {
            case delta
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case contentIndex = "content_index"
        }
    }

    /// The end of a content stream: `response.output_audio.done`,
    /// `response.output_audio_transcript.done` (with the full `transcript`)
    /// and `response.output_text.done` (with the full `text`).
    public struct ContentDone: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var contentIndex: Int?
        public var transcript: String?
        public var text: String?

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            contentIndex: Int? = nil, transcript: String? = nil, text: String? = nil
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.contentIndex = contentIndex
            self.transcript = transcript
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case transcript, text
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case contentIndex = "content_index"
        }
    }

    /// Streamed function or MCP call arguments (a fragment of a JSON
    /// string).
    public struct ArgumentsDelta: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var callID: String?
        public var delta: String

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            callID: String? = nil, delta: String
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.callID = callID
            self.delta = delta
        }

        private enum CodingKeys: String, CodingKey {
            case delta
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case callID = "call_id"
        }
    }

    /// A function or MCP call with its complete arguments. Answer a function
    /// call with ``RealtimeItem/functionOutput(callID:output:)`` and then
    /// `response.create` once every call of the response has an output.
    public struct ArgumentsDone: Sendable, Hashable, Codable {
        public var eventID: String?
        public var responseID: String?
        public var itemID: String?
        public var outputIndex: Int?
        public var callID: String
        public var name: String?
        /// A JSON string.
        public var arguments: String

        public init(
            eventID: String? = nil, responseID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil,
            callID: String, name: String? = nil, arguments: String
        ) {
            self.eventID = eventID
            self.responseID = responseID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.callID = callID
            self.name = name
            self.arguments = arguments
        }

        private enum CodingKeys: String, CodingKey {
            case name, arguments
            case eventID = "event_id"
            case responseID = "response_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
            case callID = "call_id"
        }
    }

    /// A remote MCP lifecycle event (`mcp_list_tools.*`,
    /// `response.mcp_call.*`).
    public struct MCPEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var itemID: String?
        public var outputIndex: Int?
        /// Set on the `failed` events.
        public var error: RealtimeErrorDetail?

        public init(
            eventID: String? = nil, itemID: String? = nil, outputIndex: Int? = nil, error: RealtimeErrorDetail? = nil
        ) {
            self.eventID = eventID
            self.itemID = itemID
            self.outputIndex = outputIndex
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case error
            case eventID = "event_id"
            case itemID = "item_id"
            case outputIndex = "output_index"
        }
    }

    /// `error`.
    public struct ErrorEvent: Sendable, Hashable, Codable {
        public var eventID: String?
        public var error: RealtimeErrorDetail

        public init(eventID: String? = nil, error: RealtimeErrorDetail) {
            self.eventID = eventID
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case error
            case eventID = "event_id"
        }
    }

    /// An event Blau couldn't type.
    public struct UnknownEvent: Sendable, Hashable {
        /// The event's `type`, or `""` when the frame had none.
        public var type: String
        /// The frame as received.
        public var raw: Data
        /// Why a known type failed to decode; `nil` when the type is simply
        /// unknown.
        public var decodingFailure: String?

        public init(type: String, raw: Data, decodingFailure: String? = nil) {
            self.type = type
            self.raw = raw
            self.decodingFailure = decodingFailure
        }

        /// The frame parsed as JSON (`.null` if it isn't JSON).
        public var json: JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: raw)) ?? .null
        }
    }
}

// MARK: - Shared types

/// A response, as reported by `response.created` and `response.done`.
public struct RealtimeResponse: Sendable, Hashable, Codable {
    public var id: String?
    public var object: String?
    public var status: RealtimeResponseStatus?
    /// Why the response ended the way it did, when the server says.
    public var statusDetails: JSONValue?
    public var output: [RealtimeItem]?
    public var usage: Usage?
    /// What the client passed in `response.create`, echoed back.
    public var metadata: [String: JSONValue]?

    public init(
        id: String? = nil, object: String? = nil, status: RealtimeResponseStatus? = nil,
        statusDetails: JSONValue? = nil, output: [RealtimeItem]? = nil, usage: Usage? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.object = object
        self.status = status
        self.statusDetails = statusDetails
        self.output = output
        self.usage = usage
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, status, output, usage, metadata
        case statusDetails = "status_details"
    }

    /// Token usage for one response.
    public struct Usage: Sendable, Hashable, Codable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var totalTokens: Int?
        /// Per-modality breakdowns, when reported.
        public var inputTokenDetails: JSONValue?
        public var outputTokenDetails: JSONValue?

        public init(
            inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil,
            inputTokenDetails: JSONValue? = nil, outputTokenDetails: JSONValue? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.inputTokenDetails = inputTokenDetails
            self.outputTokenDetails = outputTokenDetails
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
            case inputTokenDetails = "input_token_details"
            case outputTokenDetails = "output_token_details"
        }
    }
}

/// The details of an `error` event or a failed MCP call.
public struct RealtimeErrorDetail: Sendable, Hashable, Codable {
    public var type: RealtimeErrorType?
    /// A finer-grained code, e.g. `invalid_audio_format`.
    public var code: String?
    public var message: String?
    /// The parameter at fault, if any.
    public var param: String?
    /// The client event that caused the error, if any.
    public var eventID: String?

    public init(
        type: RealtimeErrorType? = nil, code: String? = nil, message: String? = nil, param: String? = nil,
        eventID: String? = nil
    ) {
        self.type = type
        self.code = code
        self.message = message
        self.param = param
        self.eventID = eventID
    }

    private enum CodingKeys: String, CodingKey {
        case type, code, message, param
        case eventID = "event_id"
    }
}
