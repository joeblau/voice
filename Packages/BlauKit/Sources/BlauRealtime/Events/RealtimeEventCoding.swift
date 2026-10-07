import Foundation

/// JSON coding for realtime events.
///
/// Keys are spelled out in each type's `CodingKeys`, so no key strategy is
/// used: free-form JSON (tool schemas, metadata, `replace` maps) passes
/// through untouched. `Data` fields are base64, as the protocol requires.
public enum RealtimeEventCoding {
    /// Encodes an event as compact JSON. Keys are sorted, so the same event
    /// always produces the same bytes (stable fixtures and tests).
    public static func encode(_ event: RealtimeClientEvent) throws -> Data {
        try makeEncoder().encode(event)
    }

    /// Encodes a server event (for tests and fake servers).
    public static func encode(_ event: RealtimeServerEvent) throws -> Data {
        try makeEncoder().encode(event)
    }

    /// Decodes a client event (for transcripts and tests).
    public static func decodeClientEvent(_ data: Data) throws -> RealtimeClientEvent {
        try JSONDecoder().decode(RealtimeClientEvent.self, from: data)
    }

    /// Decodes one server frame. Never throws: a frame with an unknown
    /// `type`, a payload that doesn't match its type, or bytes that aren't a
    /// JSON object become ``RealtimeServerEvent/unknown(_:)`` with the raw
    /// bytes kept.
    public static func decodeServerEvent(_ data: Data) -> RealtimeServerEvent {
        do {
            return try JSONDecoder().decode(RealtimeServerEvent.self, from: data)
        } catch let error as RealtimeServerEvent.UnknownTypeError {
            return .unknown(.init(type: error.type, raw: data))
        } catch {
            return .unknown(.init(type: Self.type(of: data) ?? "", raw: data, decodingFailure: describe(error)))
        }
    }

    /// Decodes one server text frame.
    public static func decodeServerEvent(_ text: String) -> RealtimeServerEvent {
        decodeServerEvent(Data(text.utf8))
    }

    /// The `type` of a JSON event, without decoding the rest.
    public static func type(of data: Data) -> String? {
        struct Probe: Decodable { var type: String }
        return try? JSONDecoder().decode(Probe.self, from: data).type
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// A one-line description of a decoding error that names the failing
    /// key path. Never includes values, which may be user content.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else {
            return String(describing: Swift.type(of: error))
        }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted data at \(path(context))"
        @unknown default:
            return "decoding failed"
        }
    }
}
