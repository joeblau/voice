import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

/// Fuzzes the realtime event decoder with malformed messages (#80).
///
/// The corpus is every server frame in the fixture sessions. Each round
/// mutates frames with a seeded generator (so a failure reproduces from its
/// seed): byte flips, insertions, deletions and truncations; JSON-aware
/// mutations that swap a value for one of another type, drop keys, change
/// `type` to another event's, or nest the payload; and hand-picked hostile
/// inputs (deep nesting, huge numbers and strings, invalid UTF-8, bad
/// base64). Properties:
///
/// - `RealtimeEventCoding.decodeServerEvent` never traps or hangs, whatever
///   it is given;
/// - a frame it can't type comes back as `.unknown` with the bytes exactly
///   as received;
/// - a frame it does type is stable: encoding the event and decoding it
///   again gives the same event;
/// - through a live `RealtimeClient` and `TurnOrchestrator`, a burst of
///   malformed frames neither drops the connection nor disturbs the next
///   turn.
///
/// Set `BLAU_FUZZ_ITERATIONS` for a longer run (the default keeps
/// `swift test` fast).
@Suite("Realtime event decoder: fuzzing")
struct RealtimeEventFuzzTests {
    /// Mutations per corpus frame and seed.
    static let iterations: Int = {
        ProcessInfo.processInfo.environment["BLAU_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 40
    }()

    /// The server's text frames from every fixture session.
    static func corpus() throws -> [Data] {
        var frames: [Data] = []
        for name in Fixtures.names {
            for entry in try Fixtures.transcript(name).entries where entry.direction == .server {
                if case .message(.text(let text)) = entry.payload {
                    frames.append(Data(text.utf8))
                }
            }
        }
        return frames
    }

    /// Every known event type in the corpus, for type confusion.
    static func knownTypes(in corpus: [Data]) -> [String] {
        Array(Set(corpus.compactMap(RealtimeEventCoding.type(of:)))).sorted()
    }

    // MARK: Properties

    /// Decodes `data` and checks the decoder's contract.
    static func check(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        let event = RealtimeEventCoding.decodeServerEvent(data)
        _ = event.type
        switch event {
        case .unknown(let unknown):
            #expect(unknown.raw == data, "an unknown event keeps its bytes", sourceLocation: sourceLocation)
        default:
            // Typed: the encoding is stable. (A value the encoder refuses,
            // such as a number JSON can't hold, is not a decoding problem.)
            guard let encoded = try? RealtimeEventCoding.encode(event) else { return }
            let again = RealtimeEventCoding.decodeServerEvent(encoded)
            #expect(
                again == event, "\(event.type) changed after a round trip: \(String(decoding: data, as: UTF8.self))",
                sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [UInt64(1), 2, 3, 0xB1A0, 0x5EED])
    func mutatedFixtureFramesNeverBreakTheDecoder(seed: UInt64) throws {
        let corpus = try Self.corpus()
        #expect(corpus.count > 50)
        let types = Self.knownTypes(in: corpus)
        var random = FuzzRandom(seed: seed)
        var unknown = 0
        var total = 0
        for frame in corpus {
            for _ in 0..<Self.iterations {
                let mutated = FrameMutator.mutate(frame, types: types, using: &random)
                Self.check(mutated)
                total += 1
                if RealtimeEventCoding.decodeServerEvent(mutated).isUnknown { unknown += 1 }
            }
        }
        // The mutations really do produce malformed frames, and not only.
        #expect(unknown > total / 10, "\(unknown) of \(total) mutated frames were malformed")
        #expect(unknown < total, "every mutated frame was malformed")
    }

    @Test func randomBytesNeverBreakTheDecoder() {
        var random = FuzzRandom(seed: 42)
        for _ in 0..<(Self.iterations * 50) {
            let count = Int.random(in: 0...256, using: &random)
            let bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
            Self.check(bytes)
        }
    }

    @Test(arguments: HostileFrame.all)
    func hostileFramesBecomeUnknownOrDecodeStably(frame: HostileFrame) {
        Self.check(frame.data)
    }

    @Test func malformedVersionsOfEveryEventKeepTheirType() throws {
        // A known type with a broken payload is reported as that type, with
        // the reason, so the log says what changed.
        let corpus = try Self.corpus()
        for frame in corpus {
            guard let type = RealtimeEventCoding.type(of: frame), case .object(var object) = try json(frame)
            else { continue }
            for key in object.keys where key != "type" && key != "event_id" {
                object[key] = .array([.number(1), .object(["x": .null])])
            }
            let broken = try JSONEncoder().encode(JSONValue.object(object))
            let event = RealtimeEventCoding.decodeServerEvent(broken)
            if case .unknown(let unknown) = event {
                #expect(unknown.type == type)
                #expect(unknown.raw == broken)
            }
        }
    }

    // MARK: Through the client and the orchestrator

    /// A burst of malformed frames mid-session: none is fatal, the socket
    /// stays open, and the next turn goes through as if nothing happened.
    @Test func malformedFramesDontDisturbALiveSession() async throws {
        let corpus = try Self.corpus()
        let types = Self.knownTypes(in: corpus)
        var random = FuzzRandom(seed: 0xF022)
        var malformed: [String] = []
        while malformed.count < 500 {
            let frame = corpus[Int.random(in: 0..<corpus.count, using: &random)]
            let mutated = FrameMutator.mutate(frame, types: types, using: &random)
            // Only frames that can't be typed: a well-formed but different
            // event (a `max_duration` error, a new conversation) would
            // legitimately change the session.
            guard RealtimeEventCoding.decodeServerEvent(mutated).isUnknown,
                let text = String(data: mutated, encoding: .utf8)
            else { continue }
            malformed.append(text)
        }

        let harness = TurnHarness()
        let socket = try await harness.start()
        let events = StreamCollector(harness.orchestrator.updates(bufferingPolicy: .unbounded))
        defer { events.cancel() }
        for text in malformed {
            socket.push(text)
        }
        // Binary garbage with no response in progress: audio for nothing.
        for size in [0, 1, 3, 4_801] {
            socket.push(binary: Data(repeating: 0xA5, count: size))
        }
        await harness.orchestrator.handle(.final(harness.utterance("Are you still there?", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in ServerEvents.reply("Still here.", response: "resp_1", item: "item_1", turn: socket.turnTag()) {
            socket.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 1 }
        #expect(harness.connector.sockets.count == 1)
        #expect(socket.closeCode == nil)
        #expect(await harness.snapshot().connection == .connected)
        #expect(!events.values.contains { if case .error = $0.state { true } else { false } })
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Are you still there?", "Still here."])
    }
}

// MARK: - Mutations

/// A small, fast, seedable generator (SplitMix64), so every fuzz failure
/// reproduces from its seed.
struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum FrameMutator {
    /// One to three random mutations of `frame`.
    static func mutate(_ frame: Data, types: [String], using random: inout FuzzRandom) -> Data {
        var data = frame
        for _ in 0..<Int.random(in: 1...3, using: &random) {
            data = mutateOnce(data, types: types, using: &random)
        }
        return data
    }

    private static func mutateOnce(_ frame: Data, types: [String], using random: inout FuzzRandom) -> Data {
        switch Int.random(in: 0..<10, using: &random) {
        case 0: return flipBytes(frame, using: &random)
        case 1: return truncate(frame, using: &random)
        case 2: return insertBytes(frame, using: &random)
        case 3: return deleteRange(frame, using: &random)
        default: return mutateJSON(frame, types: types, using: &random) ?? flipBytes(frame, using: &random)
        }
    }

    // MARK: Bytes

    private static func flipBytes(_ frame: Data, using random: inout FuzzRandom) -> Data {
        guard !frame.isEmpty else { return Data([UInt8.random(in: 0...255, using: &random)]) }
        var bytes = [UInt8](frame)
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
        }
        return Data(bytes)
    }

    private static func truncate(_ frame: Data, using random: inout FuzzRandom) -> Data {
        frame.prefix(Int.random(in: 0...frame.count, using: &random))
    }

    private static let interesting: [[UInt8]] = [
        Array("\"".utf8), Array("{".utf8), Array("}".utf8), Array("[".utf8), Array("]".utf8), Array(",".utf8),
        Array(":".utf8), Array("null".utf8), Array("\\u0000".utf8), Array("\\ud800".utf8), [0xFF], [0xC3],
        [0xF0, 0x9F], [0x00], Array("1e999".utf8), Array("-0".utf8),
    ]

    private static func insertBytes(_ frame: Data, using random: inout FuzzRandom) -> Data {
        var bytes = [UInt8](frame)
        let insert = interesting[Int.random(in: 0..<interesting.count, using: &random)]
        bytes.insert(contentsOf: insert, at: Int.random(in: 0...bytes.count, using: &random))
        return Data(bytes)
    }

    private static func deleteRange(_ frame: Data, using random: inout FuzzRandom) -> Data {
        guard frame.count > 1 else { return Data() }
        var bytes = [UInt8](frame)
        let start = Int.random(in: 0..<bytes.count, using: &random)
        let end = min(bytes.count, start + Int.random(in: 1...16, using: &random))
        bytes.removeSubrange(start..<end)
        return Data(bytes)
    }

    // MARK: JSON

    private static func mutateJSON(_ frame: Data, types: [String], using random: inout FuzzRandom) -> Data? {
        guard var value = try? JSONDecoder().decode(JSONValue.self, from: frame) else { return nil }
        switch Int.random(in: 0..<6, using: &random) {
        case 0:
            // Another event's type over this payload.
            guard case .object(var object) = value, !types.isEmpty else { return nil }
            object["type"] = .string(types[Int.random(in: 0..<types.count, using: &random)])
            value = .object(object)
        case 1:
            value = dropRandomKey(value, using: &random)
        case 2, 3:
            value = replaceRandomValue(value, depth: 0, using: &random)
        case 4:
            // The payload wrapped where an object is expected.
            value = Bool.random(using: &random) ? .array([value]) : .object(["event": value])
        default:
            guard case .object(var object) = value else { return nil }
            object["type"] = randomValue(using: &random)
            value = .object(object)
        }
        return try? JSONEncoder().encode(value)
    }

    private static func dropRandomKey(_ value: JSONValue, using random: inout FuzzRandom) -> JSONValue {
        switch value {
        case .object(var object) where !object.isEmpty:
            let keys = object.keys.sorted()
            let key = keys[Int.random(in: 0..<keys.count, using: &random)]
            if Bool.random(using: &random), let nested = object[key] {
                object[key] = dropRandomKey(nested, using: &random)
            } else {
                object[key] = nil
            }
            return .object(object)
        case .array(var array) where !array.isEmpty:
            let index = Int.random(in: 0..<array.count, using: &random)
            array[index] = dropRandomKey(array[index], using: &random)
            return .array(array)
        default:
            return value
        }
    }

    private static func replaceRandomValue(
        _ value: JSONValue, depth: Int, using random: inout FuzzRandom
    ) -> JSONValue {
        // Replace here, or descend into a container.
        let descend = depth < 6 && Int.random(in: 0..<3, using: &random) > 0
        switch value {
        case .object(var object) where descend && !object.isEmpty:
            let keys = object.keys.sorted()
            let key = keys[Int.random(in: 0..<keys.count, using: &random)]
            object[key] = replaceRandomValue(object[key] ?? .null, depth: depth + 1, using: &random)
            return .object(object)
        case .array(var array) where descend && !array.isEmpty:
            let index = Int.random(in: 0..<array.count, using: &random)
            array[index] = replaceRandomValue(array[index], depth: depth + 1, using: &random)
            return .array(array)
        default:
            return depth == 0 ? value : randomValue(using: &random)
        }
    }

    private static func randomValue(using random: inout FuzzRandom) -> JSONValue {
        switch Int.random(in: 0..<12, using: &random) {
        case 0: .null
        case 1: .bool(Bool.random(using: &random))
        case 2: .number(Double(Int.random(in: -3...3, using: &random)))
        case 3: .number(1.7976931348623157e308)
        case 4: .number(-0.5)
        case 5: .string("")
        case 6: .string(String(repeating: "é", count: Int.random(in: 1...2_000, using: &random)))
        case 7: .string("!!not base64!!")
        case 8: .array([])
        case 9: .object([:])
        case 10: .array([.null, .object(["type": "message"]), .number(1e9)])
        default: .object(["type": .number(7), "id": .array([])])
        }
    }
}

/// Hand-picked frames no mutation is likely to reach.
struct HostileFrame: Sendable, CustomTestStringConvertible {
    let name: String
    let data: Data

    var testDescription: String { name }

    init(_ name: String, _ data: Data) {
        self.name = name
        self.data = data
    }

    init(_ name: String, _ text: String) {
        self.init(name, Data(text.utf8))
    }

    static let all: [HostileFrame] = [
        HostileFrame("empty", Data()),
        HostileFrame("whitespace", "  \n\t "),
        HostileFrame("null", "null"),
        HostileFrame("a number", "42"),
        HostileFrame("an array of events", #"[{"type":"response.done"}]"#),
        HostileFrame("type is a number", #"{"type":7}"#),
        HostileFrame("type is null", #"{"type":null}"#),
        HostileFrame("type is empty", #"{"type":""}"#),
        HostileFrame("only a type", #"{"type":"response.output_audio.delta"}"#),
        HostileFrame("duplicate keys", #"{"type":"response.done","type":"error","error":{}}"#),
        HostileFrame("BOM prefix", Data([0xEF, 0xBB, 0xBF]) + Data(#"{"type":"session.created","session":{}}"#.utf8)),
        HostileFrame(
            "invalid UTF-8", Data([0x7B, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x7D])),
        HostileFrame("lone surrogate", #"{"type":"response.output_text.delta","delta":"\ud800"}"#),
        HostileFrame("NUL in a string", #"{"type":"response.output_text.delta","delta":"a\u0000b"}"#),
        HostileFrame("huge exponent", #"{"type":"response.done","response":{"usage":{"input_tokens":1e999}}}"#),
        HostileFrame("fractional index", #"{"type":"response.output_text.delta","output_index":1.5,"delta":"x"}"#),
        HostileFrame("negative index", #"{"type":"response.output_text.delta","content_index":-1,"delta":"x"}"#),
        HostileFrame("bad base64 audio", #"{"type":"response.output_audio.delta","delta":"!!not base64!!"}"#),
        HostileFrame("odd-length audio", #"{"type":"response.output_audio.delta","delta":"AAEC"}"#),
        HostileFrame(
            "large audio delta",
            #"{"type":"response.output_audio.delta","delta":""# + String(repeating: "AAAA", count: 500_000) + #""}"#),
        HostileFrame(
            "a long string",
            #"{"type":"response.output_text.delta","delta":""# + String(repeating: "word ", count: 200_000) + #""}"#),
        HostileFrame(
            "nested 64 deep", Data((String(repeating: "[", count: 64) + String(repeating: "]", count: 64)).utf8)),
        HostileFrame(
            "nested 100,000 deep",
            Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8)),
        HostileFrame(
            "a deep payload under a known type",
            #"{"type":"response.function_call_arguments.done","call_id":"c","name":"n","arguments":"x","x":"#
                + String(repeating: #"{"a":"#, count: 50_000) + "1" + String(repeating: "}", count: 50_000) + "}"),
        HostileFrame("unclosed object", #"{"type":"response.done","response":{"id":"r""#),
        HostileFrame("trailing garbage", #"{"type":"session.created","session":{}} trailing"#),
        HostileFrame("error without a body", #"{"type":"error"}"#),
        HostileFrame("error with a string", #"{"type":"error","error":"boom"}"#),
        HostileFrame("item of an unknown type", #"{"type":"conversation.item.created","item":{"type":42}}"#),
    ]
}
