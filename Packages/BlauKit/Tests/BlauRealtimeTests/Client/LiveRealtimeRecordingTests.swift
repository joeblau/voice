import Foundation
import Testing

@testable import BlauRealtime

/// Runs one manual text turn against the real xAI realtime API and records
/// it as a fixture. Needs the network and a real key, so it only runs when
/// asked:
///
/// ```sh
/// BLAU_XAI_LIVE=1 XAI_API_KEY=<key> \
/// BLAU_XAI_RECORD_PATH="$PWD/Tests/BlauRealtimeTests/Fixtures/live-manual-text-turn.jsonl" \
/// swift test --filter LiveRealtimeRecordingTests
/// ```
///
/// The key mints a short-lived client secret (as the app does) and is never
/// written anywhere. Optional: `BLAU_XAI_MODEL` (default
/// `grok-voice-think-fast-2.0`), `BLAU_XAI_HOST` (default `api.x.ai`).
@Suite(
    "Live xAI realtime recording",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_XAI_LIVE"] == "1"),
    .timeLimit(.minutes(2))
)
struct LiveRealtimeRecordingTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test func recordAManualTextTurn() async throws {
        let rawKey = try #require(Self.environment["XAI_API_KEY"], "Set XAI_API_KEY")
        let key = try XAIAPIKey(validating: rawKey)
        let host = Self.environment["BLAU_XAI_HOST"] ?? "api.x.ai"
        let model = Self.environment["BLAU_XAI_MODEL"] ?? "grok-voice-think-fast-2.0"
        let endpoint = try #require(URL(string: "wss://\(host)/v1/realtime?model=\(model)"))

        let http = XAIHTTPClient(
            baseURL: try #require(URL(string: "https://\(host)")), keyStore: InMemoryAPIKeyStore(key: key))
        let tokens = TokenProvider(minter: XAIClientSecretMinter(client: http))
        let recorder = RealtimeTranscriptRecorder(metadata: [
            "note": "Manual turns: one user text turn and an audio reply.",
            "source": .string(
                "Recorded live from \(host) with LiveRealtimeRecordingTests on \(Date.now.formatted(.iso8601))"),
            "model": .string(model),
        ])
        let client = RealtimeClient(endpoint: endpoint, tokenProvider: tokens, recorder: recorder)
        let events = StreamCollector(client.events)

        try await client.connect()
        try await client.send(
            .sessionUpdate(
                RealtimeSession(
                    instructions: "You are a concise assistant. Answer in one short sentence.",
                    voice: "eve",
                    turnDetection: .manual,
                    audio: .init(output: .init(format: .pcm24kHz)))))
        try await waitUntil("session.updated", timeout: .seconds(20)) {
            events.values.contains { $0.type == "session.updated" }
        }
        try await client.send(.conversationItemCreate(.userText("Say hello in five words or fewer.")))
        try await client.send(.responseCreate())
        try await waitUntil("response.done", timeout: .seconds(60)) {
            events.values.contains { $0.type == "response.done" || $0.type == "error" }
        }
        await client.shutdown()

        let transcript = recorder.transcript
        let path =
            Self.environment["BLAU_XAI_RECORD_PATH"]
            ?? FileManager.default.temporaryDirectory.appending(path: "blau-live-realtime.jsonl").path()
        try transcript.write(to: URL(filePath: path))
        print("Recorded \(transcript.entries.count) frames to \(path)")

        let unknown = transcript.serverEvents.filter(\.isUnknown).map(\.type)
        #expect(unknown.isEmpty, "Undecoded event types: \(unknown)")
        #expect(!events.values.contains { $0.type == "error" }, "The server reported an error")
        #expect(events.values.contains { $0.type == "response.output_audio.delta" })
    }
}
