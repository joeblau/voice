import Foundation
import Testing

@testable import BlauRealtime

/// Snapshot tests of the exact `session.update` Blau sends.
///
/// Each snapshot in `Fixtures/Snapshots/` is the wire JSON (what
/// `RealtimeEventCoding.encode` produces, the bytes `RealtimeClient` sends)
/// re-printed with sorted keys and indentation so a diff is reviewable, plus
/// the instructions as plain text. A change to the session or the prompt
/// fails here until the snapshot is updated on purpose:
///
/// ```sh
/// cd Packages/BlauKit
/// BLAU_RECORD_SNAPSHOTS=1 swift test --filter SessionUpdateSnapshotTests
/// git diff Tests/BlauRealtimeTests/Fixtures/Snapshots
/// ```
@Suite("session.update snapshots")
struct SessionUpdateSnapshotTests {
    private func update(
        _ settings: RealtimeVoiceSettings,
        memory: RealtimeMemoryContext = .empty,
        tools: [RealtimeTool] = []
    ) -> RealtimeClientEvent {
        .sessionUpdate(
            RealtimeSessionConfiguration.blau.session(
                settings: settings, memory: memory, tools: tools, now: SessionFixtures.now,
                timeZone: SessionFixtures.timeZone))
    }

    @Test func defaultSessionUpdate() throws {
        let event = update(.default)
        try assertSnapshot(of: event, named: "session-update-default")
        try assertTextSnapshot(instructions(of: event), named: "instructions-default")
    }

    @Test func sessionUpdateWithSettingsMemoryAndTools() throws {
        let event = update(
            RealtimeVoiceSettings(voice: .rex, speed: 1.25, reasoningEffort: .disabled),
            memory: SessionFixtures.memory,
            tools: SessionFixtures.tools)
        try assertSnapshot(of: event, named: "session-update-rex-memory-tools")
        try assertTextSnapshot(instructions(of: event), named: "instructions-memory-tools")
    }

    /// The parts of the wire format the issue pins down, checked field by
    /// field so a failure says which one broke.
    @Test func wireFormatEssentials() throws {
        let json = try wireObject(update(RealtimeVoiceSettings(voice: .ara, speed: 0.8)))
        #expect(json["type"] as? String == "session.update")
        let session = try #require(json["session"] as? [String: Any])

        // Manual turns: `turn_detection.type` is present and null.
        let turnDetection = try #require(session["turn_detection"] as? [String: Any])
        #expect(turnDetection.keys.contains("type"))
        #expect(turnDetection["type"] is NSNull)

        #expect(session["voice"] as? String == "ara")
        #expect((session["reasoning"] as? [String: Any])?["effort"] as? String == "high")

        let output = try #require((session["audio"] as? [String: Any])?["output"] as? [String: Any])
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(output["speed"] as? Double == 0.8)
        #expect(output["transport"] as? String == "json")

        // Text turns only: no input audio config, no model (it's on the URL),
        // no tools until there are some.
        #expect((session["audio"] as? [String: Any])?["input"] == nil)
        #expect(session["model"] == nil)
        #expect(session["tools"] == nil)
        #expect((session["instructions"] as? String)?.hasPrefix("You are Blau,") == true)
    }

    @Test func wireBytesRoundTrip() throws {
        let event = update(
            RealtimeVoiceSettings(voice: .sal, speed: 1.1), memory: SessionFixtures.memory,
            tools: SessionFixtures.tools)
        let data = try RealtimeEventCoding.encode(event)
        #expect(try RealtimeEventCoding.decodeClientEvent(data) == event)
        // Encoding is deterministic: the same event gives the same bytes.
        #expect(try RealtimeEventCoding.encode(event) == data)
    }

    // MARK: Helpers

    private func instructions(of event: RealtimeClientEvent) throws -> String {
        guard case .sessionUpdate(let session) = event else { throw SnapshotError.notASessionUpdate }
        return try #require(session.instructions)
    }

    private func wireObject(_ event: RealtimeClientEvent) throws -> [String: Any] {
        let data = try RealtimeEventCoding.encode(event)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Snapshot support

enum SnapshotError: Error {
    case notASessionUpdate
}

/// `Tests/BlauRealtimeTests/Fixtures/Snapshots` in the source tree (not the
/// bundled copy), so recording updates the files under version control.
/// Inside `Fixtures` because that directory is already a test resource, so
/// SwiftPM doesn't warn about unhandled files.
private let snapshotDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/Snapshots", directoryHint: .isDirectory)

private var isRecording: Bool {
    ProcessInfo.processInfo.environment["BLAU_RECORD_SNAPSHOTS"] == "1"
}

/// Compares the event's wire JSON, pretty-printed with sorted keys, with
/// `Fixtures/Snapshots/<name>.json`.
func assertSnapshot(
    of event: RealtimeClientEvent, named name: String, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let wire = try RealtimeEventCoding.encode(event)
    let object = try JSONSerialization.jsonObject(with: wire)
    let pretty = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try assertTextSnapshot(
        String(decoding: pretty, as: UTF8.self) + "\n", named: name, extension: "json", sourceLocation: sourceLocation)
}

/// Compares `text` with `Fixtures/Snapshots/<name>.<extension>`. Records it
/// (and fails, so a new snapshot is always reviewed) when the file is
/// missing or `BLAU_RECORD_SNAPSHOTS=1`.
func assertTextSnapshot(
    _ text: String, named name: String, extension pathExtension: String = "txt",
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    // Files end with a newline, so editors that add one don't break them.
    let text = text.hasSuffix("\n") ? text : text + "\n"
    let url = snapshotDirectory.appending(path: "\(name).\(pathExtension)")
    let existing = try? String(contentsOf: url, encoding: .utf8)
    if isRecording || existing == nil {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if existing != text {
            Issue.record(
                "Recorded snapshot \(url.lastPathComponent); review it and run again without BLAU_RECORD_SNAPSHOTS",
                sourceLocation: sourceLocation)
        }
        return
    }
    guard let existing, existing != text else { return }
    let firstDifference = zip(
        existing.split(separator: "\n", omittingEmptySubsequences: false),
        text.split(separator: "\n", omittingEmptySubsequences: false)
    )
    .enumerated()
    .first { $0.element.0 != $0.element.1 }
    let detail =
        firstDifference.map {
            "line \($0.offset + 1):\n  snapshot: \($0.element.0)\n  actual:   \($0.element.1)"
        } ?? "length differs (\(existing.count) vs \(text.count) characters)"
    Issue.record(
        "Snapshot \(url.lastPathComponent) doesn't match; first difference at \(detail). Re-record with BLAU_RECORD_SNAPSHOTS=1 if the change is intended.",
        sourceLocation: sourceLocation)
}
