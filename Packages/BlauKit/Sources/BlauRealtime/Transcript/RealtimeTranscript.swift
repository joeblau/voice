import BlauCore
import Foundation

/// A recorded realtime session: every frame that crossed the WebSocket, in
/// order, with connects and closes. Recorded by
/// ``RealtimeTranscriptRecorder`` and replayed by
/// ``RealtimeReplayConnector``, so a real (or hand-written) session can
/// drive tests without a network.
///
/// ## File format
///
/// JSON Lines, one object per line, in this order:
///
/// ```text
/// {"meta":{"note":"…","model":"grok-voice-think-fast-2.0"}}            optional, first line
/// {"at":0,"connect":"wss://api.x.ai/v1/realtime?model=…","from":"client"}
/// {"at":0.081,"event":{"type":"session.created",…},"from":"server"}     a JSON text frame
/// {"at":0.6,"binary":"AAEC…","from":"server"}                            a binary frame (base64)
/// {"at":0.7,"from":"server","text":"not json"}                           a text frame that isn't a JSON object
/// {"at":9.5,"close":{"code":1006},"from":"server"}                       the connection ended
/// ```
///
/// `at` is seconds since the recording started. Client secrets never appear:
/// they travel in the upgrade's `Sec-WebSocket-Protocol` header, which isn't
/// recorded. Conversation text and audio do, so treat transcripts of real
/// sessions as private data.
public struct RealtimeTranscript: Sendable, Hashable {
    /// Who sent a frame.
    public enum Direction: String, Sendable, Hashable, Codable {
        case client
        case server
    }

    /// What happened.
    public enum Payload: Sendable, Hashable {
        /// The client opened a connection to `url` (without any secret).
        case connect(url: String?)
        /// A frame.
        case message(RealtimeSocketMessage)
        /// The connection ended. From the server (or the network), or a
        /// client-initiated close. `code` 1006 means it just died.
        case close(code: Int?, reason: String?)
    }

    public struct Entry: Sendable, Hashable {
        /// Time since the recording started.
        public var offset: Duration
        public var direction: Direction
        public var payload: Payload

        public init(offset: Duration = .zero, direction: Direction, payload: Payload) {
            self.offset = offset
            self.direction = direction
            self.payload = payload
        }

        /// A server JSON event.
        public static func server(_ json: String, at offset: Duration = .zero) -> Entry {
            Entry(offset: offset, direction: .server, payload: .message(.text(json)))
        }

        /// A client JSON event.
        public static func client(_ json: String, at offset: Duration = .zero) -> Entry {
            Entry(offset: offset, direction: .client, payload: .message(.text(json)))
        }
    }

    /// Free-form notes from the `meta` line: where it came from, the model,
    /// whether it was recorded or written by hand.
    public var metadata: [String: JSONValue]
    public var entries: [Entry]

    public init(metadata: [String: JSONValue] = [:], entries: [Entry] = []) {
        self.metadata = metadata
        self.entries = entries
    }

    // MARK: Views

    /// The transcript split into one transcript per connection, at each
    /// `connect` entry. Entries before the first `connect` (hand-written
    /// fixtures often have none) form a connection of their own.
    public var connections: [RealtimeTranscript] {
        var result: [[Entry]] = []
        for entry in entries {
            if case .connect = entry.payload {
                result.append([entry])
            } else if result.isEmpty {
                result.append([entry])
            } else {
                result[result.count - 1].append(entry)
            }
        }
        return result.map { RealtimeTranscript(metadata: metadata, entries: $0) }
    }

    /// The server's frames as typed events, in order. Binary frames become
    /// audio deltas attributed to the response in progress, exactly as
    /// ``RealtimeClient`` delivers them.
    public var serverEvents: [RealtimeServerEvent] {
        var attribution = BinaryAudioAttribution()
        var events: [RealtimeServerEvent] = []
        for entry in entries where entry.direction == .server {
            switch entry.payload {
            case .message(let message):
                let event = attribution.decode(message)
                events.append(event)
            case .connect, .close:
                attribution = BinaryAudioAttribution()
            }
        }
        return events
    }

    /// The client's frames as typed events, in order. Binary frames become
    /// `input_audio_buffer.append`.
    public var clientEvents: [RealtimeClientEvent] {
        get throws {
            try entries.compactMap { entry -> RealtimeClientEvent? in
                guard entry.direction == .client, case .message(let message) = entry.payload else { return nil }
                switch message {
                case .text(let text): return try RealtimeEventCoding.decodeClientEvent(Data(text.utf8))
                case .binary(let data): return .inputAudioBufferAppend(data)
                }
            }
        }
    }

    // MARK: JSON Lines

    /// Why a transcript file couldn't be read.
    public struct FormatError: Error, Sendable, Equatable, CustomStringConvertible {
        /// 1-based line number.
        public var line: Int
        public var reason: String

        public var description: String { "line \(line): \(reason)" }
    }

    private struct Line: Codable {
        struct Close: Codable {
            var code: Int?
            var reason: String?
        }

        var meta: [String: JSONValue]?
        var at: Double?
        var from: Direction?
        var connect: String?
        var event: JSONValue?
        var text: String?
        var binary: Data?
        var close: Close?
    }

    /// Reads a transcript from JSON Lines. Blank lines are skipped.
    public init(jsonLines data: Data) throws(FormatError) {
        self.init()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for (index, rawLine) in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .enumerated()
        {
            let lineNumber = index + 1
            guard rawLine.contains(where: { !$0.isASCIIWhitespace }) else { continue }
            let line: Line
            do {
                line = try decoder.decode(Line.self, from: Data(rawLine))
            } catch {
                throw FormatError(line: lineNumber, reason: RealtimeEventCoding.describe(error))
            }
            if let meta = line.meta {
                metadata.merge(meta) { _, new in new }
                continue
            }
            guard let from = line.from else {
                throw FormatError(line: lineNumber, reason: "missing \"from\"")
            }
            let payload: Payload
            if let connect = line.connect {
                payload = .connect(url: connect)
            } else if let event = line.event {
                guard let json = try? encoder.encode(event) else {
                    throw FormatError(line: lineNumber, reason: "unencodable event")
                }
                payload = .message(.text(String(decoding: json, as: UTF8.self)))
            } else if let text = line.text {
                payload = .message(.text(text))
            } else if let binary = line.binary {
                payload = .message(.binary(binary))
            } else if let close = line.close {
                payload = .close(code: close.code, reason: close.reason)
            } else {
                throw FormatError(line: lineNumber, reason: "no connect, event, text, binary or close")
            }
            let seconds = max(line.at ?? 0, 0)
            entries.append(
                Entry(offset: .milliseconds(Int64((seconds * 1_000).rounded())), direction: from, payload: payload))
        }
    }

    /// Reads a transcript file.
    public init(contentsOf url: URL) throws {
        try self.init(jsonLines: Data(contentsOf: url))
    }

    /// The transcript as JSON Lines. JSON text frames are written inline as
    /// `event` objects so the file stays readable and diffable.
    public func jsonLines() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines: [Data] = []
        if !metadata.isEmpty, let meta = try? encoder.encode(Line(meta: metadata)) {
            lines.append(meta)
        }
        for entry in entries {
            var line = Line(at: (entry.offset.timeInterval * 1_000).rounded() / 1_000, from: entry.direction)
            switch entry.payload {
            case .connect(let url):
                line.connect = url ?? ""
            case .message(.text(let text)):
                if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                    case .object = json
                {
                    line.event = json
                } else {
                    line.text = text
                }
            case .message(.binary(let data)):
                line.binary = data
            case .close(let code, let reason):
                line.close = Line.Close(code: code, reason: reason)
            }
            if let encoded = try? encoder.encode(line) {
                lines.append(encoded)
            }
        }
        return Data(lines.joined(separator: Data([UInt8(ascii: "\n")]))) + Data([UInt8(ascii: "\n")])
    }

    /// Writes the transcript as JSON Lines.
    public func write(to url: URL) throws {
        try jsonLines().write(to: url, options: .atomic)
    }
}

extension UInt8 {
    fileprivate var isASCIIWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\t") || self == UInt8(ascii: "\r")
            || self == UInt8(ascii: "\n")
    }
}

// MARK: - Binary audio attribution

/// Gives binary audio frames (output transport `binary`) the response, item
/// and content indices of the audio part in progress, which the server only
/// announces in the surrounding JSON events.
struct BinaryAudioAttribution: Sendable {
    private var responseID: String?
    private var itemID: String?
    private var outputIndex: Int?
    private var contentIndex: Int?

    /// Decodes a frame, then updates the attribution from it.
    mutating func decode(_ message: RealtimeSocketMessage) -> RealtimeServerEvent {
        let event: RealtimeServerEvent
        switch message {
        case .text(let text):
            event = RealtimeEventCoding.decodeServerEvent(text)
        case .binary(let data):
            event = .responseOutputAudioDelta(
                .init(
                    responseID: responseID, itemID: itemID, outputIndex: outputIndex, contentIndex: contentIndex,
                    audio: data, isBinaryFrame: true))
        }
        observe(event)
        return event
    }

    private mutating func observe(_ event: RealtimeServerEvent) {
        switch event {
        case .responseCreated(let created):
            self = BinaryAudioAttribution()
            responseID = created.response.id
        case .responseOutputItemAdded(let added):
            guard case .message = added.item else { return }
            responseID = added.responseID ?? responseID
            itemID = added.item.id
            outputIndex = added.outputIndex
            contentIndex = nil
        case .responseContentPartAdded(let added) where added.part.type == .audio:
            itemID = added.itemID ?? itemID
            outputIndex = added.outputIndex ?? outputIndex
            contentIndex = added.contentIndex
        case .responseDone:
            self = BinaryAudioAttribution()
        default:
            break
        }
    }
}
