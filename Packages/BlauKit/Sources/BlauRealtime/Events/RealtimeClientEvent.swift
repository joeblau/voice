import Foundation

/// An event Blau sends to the xAI realtime API.
///
/// Covers every client event in xAI's realtime reference
/// (https://docs.x.ai/voice-realtime.ws.json). `Codable` both ways so
/// transcripts of what the client sent can be decoded in tests.
///
/// ```swift
/// try await client.send(.conversationItemCreate(.userText("What's next on my list?")))
/// try await client.send(.responseCreate())
/// ```
public enum RealtimeClientEvent: Sendable, Hashable, Codable {
    /// `session.update`: changes the fields of `session` that are set.
    case sessionUpdate(RealtimeSession)
    /// `input_audio_buffer.append`: audio in the session's input format.
    /// With ``RealtimeClient/Configuration/inputAudioTransport`` set to
    /// `.binary`, ``RealtimeClient`` sends the bytes as a binary frame
    /// instead of base64 JSON.
    case inputAudioBufferAppend(Data)
    /// `input_audio_buffer.commit`: commits the buffer as a user message
    /// (manual turns only).
    case inputAudioBufferCommit
    /// `input_audio_buffer.clear`: discards uncommitted audio.
    case inputAudioBufferClear
    /// `conversation.item.create`, optionally inserted after
    /// `previousItemID`.
    case conversationItemCreate(RealtimeItem, previousItemID: String? = nil)
    /// `conversation.item.delete`.
    case conversationItemDelete(itemID: String)
    /// `conversation.item.truncate`: cuts an assistant audio item at what the
    /// user actually heard, on barge-in (#37).
    case conversationItemTruncate(itemID: String, contentIndex: Int, audioEndMilliseconds: Int)
    /// `response.create`: asks for a response, optionally with per-response
    /// options. `eventID` is the client `event_id`: an `error` caused by this
    /// event names it in `error.event_id`, so a rejected request can be told
    /// apart from others.
    case responseCreate(RealtimeResponseOptions? = nil, eventID: String? = nil)
    /// `response.cancel`: cancels `responseID`, or the response in progress
    /// when `nil`.
    case responseCancel(responseID: String? = nil)

    /// The event's `type` on the wire.
    public var type: String {
        switch self {
        case .sessionUpdate: "session.update"
        case .inputAudioBufferAppend: "input_audio_buffer.append"
        case .inputAudioBufferCommit: "input_audio_buffer.commit"
        case .inputAudioBufferClear: "input_audio_buffer.clear"
        case .conversationItemCreate: "conversation.item.create"
        case .conversationItemDelete: "conversation.item.delete"
        case .conversationItemTruncate: "conversation.item.truncate"
        case .responseCreate: "response.create"
        case .responseCancel: "response.cancel"
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, session, audio, item, response
        case previousItemID = "previous_item_id"
        case itemID = "item_id"
        case contentIndex = "content_index"
        case audioEndMilliseconds = "audio_end_ms"
        case responseID = "response_id"
        case eventID = "event_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session.update":
            self = .sessionUpdate(try container.decode(RealtimeSession.self, forKey: .session))
        case "input_audio_buffer.append":
            self = .inputAudioBufferAppend(try container.decode(Data.self, forKey: .audio))
        case "input_audio_buffer.commit":
            self = .inputAudioBufferCommit
        case "input_audio_buffer.clear":
            self = .inputAudioBufferClear
        case "conversation.item.create":
            self = .conversationItemCreate(
                try container.decode(RealtimeItem.self, forKey: .item),
                previousItemID: try container.decodeIfPresent(String.self, forKey: .previousItemID))
        case "conversation.item.delete":
            self = .conversationItemDelete(itemID: try container.decode(String.self, forKey: .itemID))
        case "conversation.item.truncate":
            self = .conversationItemTruncate(
                itemID: try container.decode(String.self, forKey: .itemID),
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                audioEndMilliseconds: try container.decode(Int.self, forKey: .audioEndMilliseconds))
        case "response.create":
            self = .responseCreate(
                try container.decodeIfPresent(RealtimeResponseOptions.self, forKey: .response),
                eventID: try container.decodeIfPresent(String.self, forKey: .eventID))
        case "response.cancel":
            self = .responseCancel(responseID: try container.decodeIfPresent(String.self, forKey: .responseID))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown client event type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .sessionUpdate(let session):
            try container.encode(session, forKey: .session)
        case .inputAudioBufferAppend(let audio):
            try container.encode(audio, forKey: .audio)
        case .inputAudioBufferCommit, .inputAudioBufferClear:
            break
        case .conversationItemCreate(let item, let previousItemID):
            try container.encodeIfPresent(previousItemID, forKey: .previousItemID)
            try container.encode(item, forKey: .item)
        case .conversationItemDelete(let itemID):
            try container.encode(itemID, forKey: .itemID)
        case .conversationItemTruncate(let itemID, let contentIndex, let audioEndMilliseconds):
            try container.encode(itemID, forKey: .itemID)
            try container.encode(contentIndex, forKey: .contentIndex)
            try container.encode(audioEndMilliseconds, forKey: .audioEndMilliseconds)
        case .responseCreate(let options, let eventID):
            try container.encodeIfPresent(eventID, forKey: .eventID)
            try container.encodeIfPresent(options, forKey: .response)
        case .responseCancel(let responseID):
            try container.encodeIfPresent(responseID, forKey: .responseID)
        }
    }
}

/// Options for one `response.create`.
public struct RealtimeResponseOptions: Sendable, Hashable, Codable {
    public var modalities: [RealtimeModality]?
    /// Replaces the session instructions for this response only.
    public var instructions: String?
    /// Echoed back on `response.created` and `response.done`, including when
    /// the response is cancelled. Useful for matching a response to the turn
    /// that asked for it.
    public var metadata: [String: JSONValue]?

    public init(
        modalities: [RealtimeModality]? = nil, instructions: String? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.modalities = modalities
        self.instructions = instructions
        self.metadata = metadata
    }
}
