import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

/// Loads a real capture of Grok's audio deltas into a `DeltaStreamFixture`.
///
/// The file is JSON Lines: one realtime server event per line, as received,
/// with the receive time added as `t_ms` (milliseconds since the first
/// line). Only `response.output_audio.delta` events of the first audio
/// item are used; other events are skipped.
///
/// ```json
/// {"t_ms": 0, "type": "response.output_audio.delta", "item_id": "item_1", "content_index": 0, "delta": "AAEC..."}
/// ```
enum RecordedDeltaStream {
    struct Line: Decodable {
        var milliseconds: Double
        var type: String
        var itemID: String?
        var delta: String?

        enum CodingKeys: String, CodingKey {
            case milliseconds = "t_ms"
            case type
            case itemID = "item_id"
            case delta
        }
    }

    enum LoadError: Error {
        case noAudio
        case invalidBase64(line: Int)
    }

    static func fixture(jsonLines: String) throws -> DeltaStreamFixture {
        let decoder = JSONDecoder()
        var item: String?
        var samples: [Int16] = []
        var deltas: [DeltaStreamFixture.Delta] = []
        for (number, text) in jsonLines.split(whereSeparator: \.isNewline).enumerated() {
            let line = try decoder.decode(Line.self, from: Data(text.utf8))
            guard line.type == "response.output_audio.delta", let id = line.itemID, let delta = line.delta else {
                continue
            }
            if item == nil { item = id }
            guard id == item else { continue }
            guard let bytes = Data(base64Encoded: delta) else { throw LoadError.invalidBase64(line: number + 1) }
            let pcm = bytes.withUnsafeBytes { raw in
                (0..<(bytes.count / 2)).map {
                    Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
                }
            }
            deltas.append(
                DeltaStreamFixture.Delta(
                    arrivalFrame: Int(line.milliseconds * Double(DeltaStreamFixture.sampleRate) / 1000),
                    start: samples.count,
                    count: pcm.count,
                    base64: delta
                )
            )
            samples += pcm
        }
        guard !samples.isEmpty else { throw LoadError.noAudio }
        return DeltaStreamFixture(samples: samples, deltas: deltas, floats: PCM16Decoder.floats(from: samples))
    }

    /// The capture named by `BLAU_PLAYBACK_RECORDING`, if any.
    static func fromEnvironment() throws -> DeltaStreamFixture? {
        guard let path = ProcessInfo.processInfo.environment["BLAU_PLAYBACK_RECORDING"], !path.isEmpty else {
            return nil
        }
        return try fixture(jsonLines: String(contentsOf: URL(filePath: path), encoding: .utf8))
    }
}

@Suite("Recorded delta streams")
struct RecordedDeltaStreamTests {
    /// Writes `fixture` in the capture format, as a client logging its
    /// socket would.
    static func jsonLines(_ fixture: DeltaStreamFixture, item: String = "item_rec") -> String {
        var lines = [#"{"t_ms": 0, "type": "response.created"}"#]
        for delta in fixture.deltas {
            let t = Double(delta.arrivalFrame) * 1000 / Double(DeltaStreamFixture.sampleRate)
            lines.append(
                #"{"t_ms": \#(t), "type": "response.output_audio.delta", "item_id": "\#(item)", "content_index": 0, "delta": "\#(delta.base64)"}"#
            )
        }
        lines.append(#"{"t_ms": 99999, "type": "response.output_audio.done", "item_id": "\#(item)"}"#)
        return lines.joined(separator: "\n")
    }

    @Test func loadsACaptureIntoAFixture() throws {
        let original = DeltaStreamFixture.synthetic(seconds: 5, seed: 11)
        let loaded = try RecordedDeltaStream.fixture(jsonLines: Self.jsonLines(original))
        #expect(loaded.samples == original.samples)
        #expect(loaded.deltas.map(\.count) == original.deltas.map(\.count))
        // Arrival times survive the round trip through milliseconds.
        for (a, b) in zip(loaded.deltas, original.deltas) {
            #expect(abs(a.arrivalFrame - b.arrivalFrame) <= 1)
        }
    }

    @Test func rejectsACaptureWithoutAudio() {
        #expect(throws: RecordedDeltaStream.LoadError.self) {
            try RecordedDeltaStream.fixture(jsonLines: #"{"t_ms": 0, "type": "response.done"}"#)
        }
    }

    /// Replays a real capture when `BLAU_PLAYBACK_RECORDING=/path/to/capture.jsonl`
    /// is set: every sample plays, in order, and played-ms matches.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_PLAYBACK_RECORDING"] != nil))
    func replaysTheRecordingInTheEnvironment() throws {
        let fixture = try #require(try RecordedDeltaStream.fromEnvironment())
        let player = StreamingAudioPlayer(clock: ManualClock(), signposter: .disabled(.audio))
        var simulation = PlaybackSimulation(player: player, fixture: fixture)
        try simulation.runToEnd()

        let expected = fixture.floats
        let start = try #require(simulation.alignedStart)
        #expect(Array(simulation.output[start..<(start + expected.count)]) == expected)
        #expect(player.snapshot.underrunCount == 0, "a real network can underrun; inspect the capture's timing")
        #expect(player.playedItem(for: simulation.item)?.playedFrames == Int64(expected.count))
    }
}
