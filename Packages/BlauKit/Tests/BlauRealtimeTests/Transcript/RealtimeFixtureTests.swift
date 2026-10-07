import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

enum Fixtures {
    /// Every `.jsonl` transcript in `Tests/BlauRealtimeTests/Fixtures`.
    static var urls: [URL] {
        guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var names: [String] { urls.map { $0.deletingPathExtension().lastPathComponent } }

    static func transcript(_ name: String) throws -> RealtimeTranscript {
        let url = try #require(urls.first { $0.deletingPathExtension().lastPathComponent == name })
        return try RealtimeTranscript(contentsOf: url)
    }
}

@Suite("Fixture sessions")
struct RealtimeFixtureTests {
    @Test func fixturesArePresent() {
        #expect(Fixtures.names.count >= 7, "\(Fixtures.names)")
    }

    /// The acceptance criterion: every event in every fixture session
    /// decodes to a typed event.
    @Test(arguments: Fixtures.names)
    func everyServerEventDecodes(fixture: String) throws {
        let transcript = try Fixtures.transcript(fixture)
        let events = transcript.serverEvents
        #expect(!events.isEmpty)
        for event in events {
            if case .unknown(let unknown) = event {
                Issue.record(
                    "\(fixture): \(unknown.type) did not decode (\(unknown.decodingFailure ?? "unknown type"))")
            }
        }
    }

    @Test(arguments: Fixtures.names)
    func everyClientEventDecodes(fixture: String) throws {
        let transcript = try Fixtures.transcript(fixture)
        let messages = transcript.entries.filter {
            if $0.direction == .client, case .message = $0.payload { true } else { false }
        }
        let events = try transcript.clientEvents
        #expect(events.count == messages.count)
        #expect(!events.isEmpty)
    }

    /// Typed events survive encode → decode unchanged, so fakes and fixture
    /// writers can produce frames from the types.
    @Test(arguments: Fixtures.names)
    func serverEventsRoundTrip(fixture: String) throws {
        for event in try Fixtures.transcript(fixture).serverEvents {
            // A delta made from a binary frame has no JSON form of its own.
            if case .responseOutputAudioDelta(let delta) = event, delta.isBinaryFrame { continue }
            let decoded = RealtimeEventCoding.decodeServerEvent(try RealtimeEventCoding.encode(event))
            #expect(decoded == event, "\(event.type)")
        }
    }

    @Test(arguments: Fixtures.names)
    func jsonLinesRoundTrip(fixture: String) throws {
        let transcript = try Fixtures.transcript(fixture)
        let reread = try RealtimeTranscript(jsonLines: transcript.jsonLines())
        #expect(reread == transcript)
    }

    @Test func fixturesCoverEveryReferenceServerEvent() throws {
        var seen: Set<String> = []
        for name in Fixtures.names {
            for entry in try Fixtures.transcript(name).entries where entry.direction == .server {
                if case .message(.text(let text)) = entry.payload,
                    let type = RealtimeEventCoding.type(of: Data(text.utf8))
                {
                    seen.insert(type)
                }
            }
        }
        let missing = Set(RealtimeServerEventTests.referenceTypes).subtracting(seen)
        #expect(missing.isEmpty, "Fixtures never exercise \(missing.sorted())")
    }

    @Test func fixturesCoverEveryClientEvent() throws {
        var seen: Set<String> = []
        for name in Fixtures.names {
            for event in try Fixtures.transcript(name).clientEvents {
                seen.insert(event.type)
            }
        }
        #expect(seen == Set(RealtimeClientEventTests.allCases.map(\.type)))
    }

    @Test func manualTurnDecodesToTheExpectedSequence() throws {
        let events = try Fixtures.transcript("manual-text-turn").serverEvents
        #expect(
            events.map(\.type) == [
                "conversation.created", "session.created", "session.updated", "conversation.item.added",
                "response.created", "response.output_item.added", "response.content_part.added",
                "response.output_audio.delta", "response.output_audio_transcript.delta",
                "response.output_audio.delta", "response.output_audio_transcript.delta",
                "response.output_audio.delta", "response.output_audio_transcript.delta",
                "response.output_audio.done", "response.output_audio_transcript.done", "response.content_part.done",
                "response.output_item.done", "response.done",
            ])
        let audio = events.compactMap { event -> Data? in
            if case .responseOutputAudioDelta(let delta) = event { delta.audio } else { nil }
        }
        // Three 20 ms chunks of 24 kHz PCM16.
        #expect(audio.map(\.count) == [960, 960, 960])
        guard case .sessionUpdated(let updated) = events[2] else {
            Issue.record("Expected session.updated")
            return
        }
        #expect(updated.session.turnDetection == .manual)
    }

    @Test func binaryFramesAreAttributedToTheAudioPartInProgress() throws {
        let deltas = try Fixtures.transcript("binary-audio").serverEvents.compactMap {
            event -> RealtimeServerEvent.AudioDelta? in
            if case .responseOutputAudioDelta(let delta) = event { delta } else { nil }
        }
        #expect(deltas.count == 3)
        for delta in deltas {
            #expect(delta.isBinaryFrame)
            #expect(delta.responseID == "resp_001")
            #expect(delta.itemID == "item_002")
            #expect(delta.contentIndex == 0)
            #expect(delta.audio.count == 960)
        }
        let appends = try Fixtures.transcript("binary-audio").clientEvents.filter {
            if case .inputAudioBufferAppend = $0 { true } else { false }
        }
        #expect(appends.count == 2)
    }

    @Test func dropAndResumeSplitsIntoTwoConnections() throws {
        let transcript = try Fixtures.transcript("drop-and-resume")
        let connections = transcript.connections
        #expect(connections.count == 2)
        guard case .connect(let url) = connections[1].entries.first?.payload else {
            Issue.record("Second connection should start with connect")
            return
        }
        #expect(url?.hasSuffix("&conversation_id=conv_77") == true)
        guard case .close(let code, _) = connections[0].entries.last?.payload else {
            Issue.record("First connection should end with close")
            return
        }
        #expect(code == 1006)
    }

    @Test func fixturesSayTheyAreHandWritten() throws {
        for name in Fixtures.names {
            let source = try Fixtures.transcript(name).metadata["source"]?.stringValue ?? ""
            #expect(source.contains("Hand-written") || source.contains("Recorded"), "\(name)")
        }
    }
}

@Suite("Transcript format")
struct RealtimeTranscriptFormatTests {
    @Test func readsEveryLineKind() throws {
        let text = """
            {"meta":{"note":"x"}}
            {"at":0,"from":"client","connect":"wss://h/v1/realtime"}

            {"at":0.25,"from":"server","event":{"type":"input_audio_buffer.cleared"}}
            {"at":0.5,"from":"server","text":"not json"}
            {"at":0.75,"from":"client","binary":"AAE="}
            {"at":1,"from":"server","close":{"code":1006}}
            """
        let transcript = try RealtimeTranscript(jsonLines: Data(text.utf8))
        #expect(transcript.metadata == ["note": "x"])
        #expect(
            transcript.entries == [
                .init(offset: .zero, direction: .client, payload: .connect(url: "wss://h/v1/realtime")),
                .init(
                    offset: .milliseconds(250), direction: .server,
                    payload: .message(.text(#"{"type":"input_audio_buffer.cleared"}"#))),
                .init(offset: .milliseconds(500), direction: .server, payload: .message(.text("not json"))),
                .init(offset: .milliseconds(750), direction: .client, payload: .message(.binary(Data([0, 1])))),
                .init(offset: .seconds(1), direction: .server, payload: .close(code: 1006, reason: nil)),
            ])
    }

    @Test func reportsTheBadLine() {
        let text = "{\"at\":0,\"from\":\"server\",\"event\":{\"type\":\"x\"}}\n{\"at\":1}\n"
        #expect(throws: RealtimeTranscript.FormatError(line: 2, reason: "missing \"from\"")) {
            try RealtimeTranscript(jsonLines: Data(text.utf8))
        }
    }

    @Test func recorderTimesEntriesFromTheFirstOne() {
        let clock = ManualClock()
        let recorder = RealtimeTranscriptRecorder(clock: clock, metadata: ["note": "t"])
        clock.advance(by: .seconds(5))
        recorder.record(.client, .connect(url: "wss://h"))
        clock.advance(by: .milliseconds(120))
        recorder.record(.server, .message(.text(#"{"type":"session.created","session":{}}"#)))
        let transcript = recorder.transcript
        #expect(transcript.entries.map(\.offset) == [.zero, .milliseconds(120)])
        #expect(transcript.metadata == ["note": "t"])
        recorder.reset()
        #expect(recorder.transcript.entries.isEmpty)
    }
}
