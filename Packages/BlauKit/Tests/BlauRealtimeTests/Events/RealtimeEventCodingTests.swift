import Foundation
import Testing

@testable import BlauRealtime

/// Parses JSON into `JSONValue` so tests compare structure, not key order
/// or number formatting.
func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

func json(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

@Suite("Client events: wire format")
struct RealtimeClientEventTests {
    func encoded(_ event: RealtimeClientEvent) throws -> JSONValue {
        try json(RealtimeEventCoding.encode(event))
    }

    @Test func userTextTurn() throws {
        #expect(
            try encoded(.conversationItemCreate(.userText("What's next?")))
                == json(
                    #"{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"What's next?"}]}}"#
                ))
    }

    @Test func itemCreateWithPreviousItem() throws {
        #expect(
            try encoded(.conversationItemCreate(.assistantText("Hi", id: "a1"), previousItemID: "u1"))
                == json(
                    #"{"type":"conversation.item.create","previous_item_id":"u1","item":{"id":"a1","type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}]}}"#
                ))
    }

    /// Manual turns are `"turn_detection": {"type": null}`, as xAI documents
    /// (`turn_detection.type`: `null` for manual text turns).
    @Test func sessionUpdateWithManualTurns() throws {
        let session = RealtimeSession(
            instructions: "Be brief.", voice: "eve", turnDetection: .manual,
            audio: .init(output: .init(format: .pcm24kHz)))
        #expect(
            try encoded(.sessionUpdate(session))
                == json(
                    #"{"type":"session.update","session":{"instructions":"Be brief.","voice":"eve","turn_detection":{"type":null},"audio":{"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#
                ))
    }

    @Test func sessionUpdateOmitsUnsetFields() throws {
        #expect(
            try encoded(.sessionUpdate(RealtimeSession(resumption: .init(enabled: true))))
                == json(#"{"type":"session.update","session":{"resumption":{"enabled":true}}}"#))
    }

    @Test func sessionUpdateWithEveryField() throws {
        let session = RealtimeSession(
            model: "grok-voice-think-fast-2.0",
            instructions: "x",
            reasoning: .init(effort: .disabled),
            voice: "ara",
            turnDetection: .init(type: .serverVAD, idleTimeoutMilliseconds: 10_000),
            resumption: .init(enabled: true),
            audio: .init(
                input: .init(
                    format: .init(type: .pcm, rate: 16_000), transport: .binary,
                    transcription: .init(languageHint: "en", keyterms: ["Blau"])),
                output: .init(format: .pcm24kHz, transport: .binary, speed: 1.2)),
            tools: [
                .function(
                    name: "search_memory", description: "Search",
                    parameters: ["type": "object", "properties": ["query": ["type": "string"]]]),
                .other(["type": "web_search"]),
            ],
            replace: ["Blau": "Blow"])
        #expect(
            try encoded(.sessionUpdate(session))
                == json(
                    """
                    {"type":"session.update","session":{
                      "model":"grok-voice-think-fast-2.0","instructions":"x","reasoning":{"effort":"none"},"voice":"ara",
                      "turn_detection":{"type":"server_vad","idle_timeout_ms":10000},
                      "resumption":{"enabled":true},
                      "audio":{
                        "input":{"format":{"type":"audio/pcm","rate":16000},"transport":"binary",
                                 "transcription":{"language_hint":"en","keyterms":["Blau"]}},
                        "output":{"format":{"type":"audio/pcm","rate":24000},"transport":"binary","speed":1.2}},
                      "tools":[
                        {"type":"function","name":"search_memory","description":"Search",
                         "parameters":{"type":"object","properties":{"query":{"type":"string"}}}},
                        {"type":"web_search"}],
                      "replace":{"Blau":"Blow"}}}
                    """))
    }

    @Test func audioAppendIsBase64() throws {
        #expect(
            try encoded(.inputAudioBufferAppend(Data([0x00, 0x01, 0xFF, 0x7F])))
                == json(#"{"type":"input_audio_buffer.append","audio":"AAH/fw=="}"#))
    }

    @Test func bufferControlEvents() throws {
        #expect(try encoded(.inputAudioBufferCommit) == json(#"{"type":"input_audio_buffer.commit"}"#))
        #expect(try encoded(.inputAudioBufferClear) == json(#"{"type":"input_audio_buffer.clear"}"#))
    }

    @Test func truncateAndDelete() throws {
        #expect(
            try encoded(.conversationItemTruncate(itemID: "msg_4", contentIndex: 0, audioEndMilliseconds: 1_500))
                == json(
                    #"{"type":"conversation.item.truncate","item_id":"msg_4","content_index":0,"audio_end_ms":1500}"#))
        #expect(
            try encoded(.conversationItemDelete(itemID: "msg_3"))
                == json(#"{"type":"conversation.item.delete","item_id":"msg_3"}"#))
    }

    @Test func responseCreateAndCancel() throws {
        #expect(try encoded(.responseCreate()) == json(#"{"type":"response.create"}"#))
        #expect(
            try encoded(
                .responseCreate(.init(modalities: [.text], instructions: "One line.", metadata: ["turn": "7"])))
                == json(
                    #"{"type":"response.create","response":{"modalities":["text"],"instructions":"One line.","metadata":{"turn":"7"}}}"#
                ))
        #expect(
            try encoded(.responseCreate(.init(metadata: ["blau_turn": "2"]), eventID: "blau_rc_2_1"))
                == json(
                    #"{"type":"response.create","event_id":"blau_rc_2_1","response":{"metadata":{"blau_turn":"2"}}}"#
                ))
        #expect(try encoded(.responseCancel()) == json(#"{"type":"response.cancel"}"#))
        #expect(
            try encoded(.responseCancel(responseID: "resp_1"))
                == json(#"{"type":"response.cancel","response_id":"resp_1"}"#))
    }

    @Test func functionOutputAndForceMessage() throws {
        #expect(
            try encoded(.conversationItemCreate(.functionOutput(callID: "call_1", output: #"{"ok":true}"#)))
                == json(
                    #"{"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"call_1","output":"{\"ok\":true}"}}"#
                ))
        #expect(
            try encoded(.conversationItemCreate(.forceMessage(.init(text: "One moment.", interruptible: false))))
                == json(
                    #"{"type":"conversation.item.create","item":{"type":"force_message","role":"assistant","content":[{"type":"output_text","text":"One moment."}],"interruptible":false}}"#
                ))
    }

    static let allCases: [RealtimeClientEvent] = [
        .sessionUpdate(
            RealtimeSession(
                voice: "eve", turnDetection: .manual, tools: [.function(name: "f", description: nil, parameters: nil)])),
        .inputAudioBufferAppend(Data(repeating: 7, count: 33)),
        .inputAudioBufferCommit,
        .inputAudioBufferClear,
        .conversationItemCreate(.userText("hi"), previousItemID: "p"),
        .conversationItemCreate(.systemText("context")),
        .conversationItemCreate(.functionOutput(callID: "c", output: "{}")),
        .conversationItemCreate(.functionCall(.init(callID: "c", name: "f", arguments: "{}"))),
        .conversationItemCreate(.forceMessage(.init(text: "Hello"))),
        .conversationItemDelete(itemID: "i"),
        .conversationItemTruncate(itemID: "i", contentIndex: 1, audioEndMilliseconds: 250),
        .responseCreate(),
        .responseCreate(.init(metadata: ["n": 1, "flag": true, "nested": ["a": [1, 2]]])),
        .responseCreate(eventID: "e"),
        .responseCancel(),
        .responseCancel(responseID: "r"),
    ]

    @Test(arguments: allCases)
    func roundTrips(event: RealtimeClientEvent) throws {
        let decoded = try RealtimeEventCoding.decodeClientEvent(RealtimeEventCoding.encode(event))
        #expect(decoded == event)
        #expect(try json(RealtimeEventCoding.encode(event))["type"] == .string(event.type))
    }
}

@Suite("Server events: decoding")
struct RealtimeServerEventTests {
    /// Every server event in xAI's realtime reference
    /// (docs.x.ai/voice-realtime.ws.json, fetched 2026-10-07).
    static let referenceTypes = [
        "session.created", "conversation.created", "session.updated", "input_audio_buffer.speech_started",
        "input_audio_buffer.speech_stopped", "input_audio_buffer.committed", "input_audio_buffer.timeout_triggered",
        "input_audio_buffer.cleared", "conversation.item.deleted", "conversation.item.added",
        "conversation.item.truncated", "conversation.item.input_audio_transcription.completed",
        "conversation.item.input_audio_transcription.updated", "input_audio_buffer.dtmf_event_received",
        "response.created", "response.output_item.added", "response.output_item.done",
        "response.content_part.added", "response.content_part.done", "response.output_audio_transcript.delta",
        "response.output_audio_transcript.done", "response.output_audio.delta", "response.output_audio.done",
        "response.text.delta", "response.output_text.delta", "response.function_call_arguments.delta",
        "response.function_call_arguments.done", "mcp_list_tools.in_progress", "mcp_list_tools.completed",
        "mcp_list_tools.failed", "response.mcp_call_arguments.delta", "response.mcp_call_arguments.done",
        "response.mcp_call.in_progress", "response.mcp_call.completed", "response.mcp_call.failed", "response.done",
        "error",
    ]

    @Test func everyReferenceTypeHasATypedCase() {
        #expect(Set(Self.referenceTypes).subtracting(RealtimeServerEvent.knownTypes).isEmpty)
        // Resumption replays history with this one (speech-to-speech guide).
        #expect(RealtimeServerEvent.knownTypes.contains("conversation.item.created"))
    }

    @Test func audioDeltaDecodesBase64() {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"event_id":"event_4950","type":"response.output_audio.delta","response_id":"resp_001","item_id":"msg_008","output_index":0,"content_index":0,"delta":"AAH/fw=="}"#
        )
        #expect(
            event
                == .responseOutputAudioDelta(
                    .init(
                        eventID: "event_4950", responseID: "resp_001", itemID: "msg_008", outputIndex: 0,
                        contentIndex: 0, audio: Data([0x00, 0x01, 0xFF, 0x7F]))))
    }

    @Test func responseDoneCarriesUsageAndMetadata() throws {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"event_id":"e","type":"response.done","response":{"id":"resp_001","object":"realtime.response","status":"cancelled","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"metadata":{"turn":"3"}}}"#
        )
        guard case .responseDone(let done) = event else {
            Issue.record("Expected response.done, got \(event)")
            return
        }
        #expect(done.response.status == .cancelled)
        #expect(done.response.usage == .init(inputTokens: 10, outputTokens: 5, totalTokens: 15))
        #expect(done.response.metadata == ["turn": "3"])
    }

    @Test func errorEvent() {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"event_id":"event_err01","type":"error","error":{"type":"invalid_request_error","code":"invalid_audio_format","message":"Audio format not supported."}}"#
        )
        #expect(
            event
                == .error(
                    .init(
                        eventID: "event_err01",
                        error: .init(
                            type: .invalidRequest, code: "invalid_audio_format",
                            message: "Audio format not supported."))))
    }

    @Test func unknownTypeKeepsTheRawFrame() {
        let raw = #"{"type":"response.hologram.delta","event_id":"e5","delta":"x"}"#
        let event = RealtimeEventCoding.decodeServerEvent(raw)
        #expect(event == .unknown(.init(type: "response.hologram.delta", raw: Data(raw.utf8))))
        #expect(event.type == "response.hologram.delta")
        #expect(event.isUnknown)
    }

    @Test func malformedKnownTypeBecomesUnknownWithTheReason() {
        let raw = #"{"type":"response.output_audio.delta","response_id":"r"}"#
        guard case .unknown(let unknown) = RealtimeEventCoding.decodeServerEvent(raw) else {
            Issue.record("Expected unknown")
            return
        }
        #expect(unknown.type == "response.output_audio.delta")
        #expect(unknown.raw == Data(raw.utf8))
        #expect(unknown.decodingFailure == "missing key delta at <root>")
    }

    @Test func nonJSONBecomesUnknownWithoutAType() {
        guard case .unknown(let unknown) = RealtimeEventCoding.decodeServerEvent("not json") else {
            Issue.record("Expected unknown")
            return
        }
        #expect(unknown.type == "")
        #expect(unknown.decodingFailure != nil)
    }

    @Test(arguments: [
        ("response.text.delta", "response.output_text.delta"),
        ("response.audio_transcript.delta", "response.output_audio_transcript.delta"),
    ])
    func olderNamesDecodeAsTheCanonicalType(alias: String, canonical: String) {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"type":"\#(alias)","response_id":"r","item_id":"i","delta":"Hi"}"#)
        #expect(event.type == canonical)
        #expect(!event.isUnknown)
    }

    @Test func olderAudioDeltaName() {
        let event = RealtimeEventCoding.decodeServerEvent(#"{"type":"response.audio.delta","delta":"AAE="}"#)
        #expect(event == .responseOutputAudioDelta(.init(audio: Data([0, 1]))))
    }

    @Test func unknownEnumValuesAndItemTypesStillDecode() throws {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"type":"response.output_item.added","response_id":"r","output_index":0,"item":{"id":"i","type":"message","status":"paused","role":"narrator","content":[{"type":"hologram"}]}}"#
        )
        guard case .responseOutputItemAdded(let added) = event, case .message(let message) = added.item else {
            Issue.record("Expected a message item, got \(event)")
            return
        }
        #expect(message.status == RealtimeItemStatus(rawValue: "paused"))
        #expect(message.role == "narrator")
        #expect(message.content == [ContentPart(type: "hologram")])

        let mcp = RealtimeEventCoding.decodeServerEvent(
            #"{"type":"response.output_item.added","item":{"id":"m1","type":"mcp_call","name":"search"}}"#)
        guard case .responseOutputItemAdded(let mcpAdded) = mcp else {
            Issue.record("Expected an output item, got \(mcp)")
            return
        }
        #expect(mcpAdded.item.type == "mcp_call")
        #expect(mcpAdded.item.id == "m1")
    }

    @Test func functionToolsDecodeInBothShapes() throws {
        let flat = try JSONDecoder().decode(
            RealtimeTool.self, from: Data(#"{"type":"function","name":"f","parameters":{"type":"object"}}"#.utf8))
        let nested = try JSONDecoder().decode(
            RealtimeTool.self,
            from: Data(#"{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}"#.utf8))
        #expect(flat == .function(name: "f", description: nil, parameters: ["type": "object"]))
        #expect(nested == flat)
        let search = try JSONDecoder().decode(RealtimeTool.self, from: Data(#"{"type":"x_search"}"#.utf8))
        #expect(search == .other(["type": "x_search"]))
    }

    @Test func sessionEchoWithManualTurns() {
        let event = RealtimeEventCoding.decodeServerEvent(
            #"{"type":"session.updated","session":{"model":"grok-voice-latest","voice":"Eve","turn_detection":{"type":null},"replace":{"Acme":"Akmee"}}}"#
        )
        guard case .sessionUpdated(let updated) = event else {
            Issue.record("Expected session.updated, got \(event)")
            return
        }
        #expect(updated.session.turnDetection == .manual)
        #expect(updated.session.replace == ["Acme": "Akmee"])
    }

    @Test func unknownEventsReEncodeTheirOriginalJSON() throws {
        let raw = #"{"type":"future.event","n":1,"nested":{"a":[true,null]}}"#
        let event = RealtimeEventCoding.decodeServerEvent(raw)
        #expect(try json(RealtimeEventCoding.encode(event)) == json(raw))
    }
}
