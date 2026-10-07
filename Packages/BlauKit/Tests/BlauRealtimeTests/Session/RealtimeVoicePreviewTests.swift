import Foundation
import Testing

@testable import BlauRealtime

/// Settings → Voice → Preview: a short TTS sample per voice and speed.
@Suite("Voice preview")
struct RealtimeVoicePreviewTests {
    /// The request body as sent, with xAI's snake-case keys.
    private func body(of request: URLRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        return try #require(object as? [String: Any])
    }

    @Test func requestsTheVoiceFromTextToSpeech() async throws {
        let transport = ScriptedTransport(routes: ["/v1/tts": .http(status: 200, body: "ID3-mp3-bytes")])
        let previewer = RealtimeVoicePreviewer(client: .test(transport: transport))

        let audio = try await previewer.sample(voice: .ara, speed: 1.13)

        #expect(audio == Data("ID3-mp3-bytes".utf8))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/tts")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.primaryRaw)")
        let sent = try body(of: request)
        #expect(sent["voice_id"] as? String == "ara")
        #expect(sent["language"] as? String == "en")
        // Rounded to the session speed's step, like `audio.output.speed`.
        #expect(sent["speed"] as? Double == 1.15)
        #expect(sent["text"] as? String == "Hi, I'm Ara. This is how I'll sound when we talk.")
        let format = try #require(sent["output_format"] as? [String: Any])
        #expect(format["codec"] as? String == "mp3")
        #expect(format["sample_rate"] as? Int == 24_000)
        #expect(format["bit_rate"] as? Int == 64_000)
        #expect(Set(sent.keys) == ["text", "voice_id", "language", "speed", "output_format"])
    }

    @Test func otherRequestsStillAskForJSON() throws {
        let request = XAIHTTPClient.test(transport: ScriptedTransport(routes: [:]))
            .makeURLRequest(.get("/v1/models"), apiKey: TestKeys.primary)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func samplesAreCachedPerVoiceAndSpeed() async throws {
        let transport = ScriptedTransport(routes: ["/v1/tts": .http(status: 200, body: "audio")])
        let previewer = RealtimeVoicePreviewer(client: .test(transport: transport))

        _ = try await previewer.sample(voice: .eve, speed: 1.0)
        _ = try await previewer.sample(voice: "EVE", speed: 1.0)
        #expect(transport.requests.count == 1)

        _ = try await previewer.sample(voice: .eve, speed: 1.2)
        _ = try await previewer.sample(voice: .rex, speed: 1.0)
        #expect(transport.requests.count == 3)

        await previewer.clearCache()
        _ = try await previewer.sample(voice: .eve, speed: 1.0)
        #expect(transport.requests.count == 4)
    }

    @Test func failuresAreClassifiedAndNotCached() async throws {
        let transport = ScriptedTransport(routes: [
            "/v1/tts": .json(403, #"{"error":"Your newly created team doesn't have any credits yet."}"#)
        ])
        let previewer = RealtimeVoicePreviewer(client: .test(transport: transport))
        for _ in 0..<2 {
            do {
                _ = try await previewer.sample(voice: .eve, speed: 1.0)
                Issue.record("Expected the preview to fail")
            } catch {
                #expect(XAIAccountProblem(error).kind == .noCredits, "\(error)")
            }
        }
        #expect(transport.requests.count == 2)
    }

    @Test func anEmptyReplyIsAnError() async {
        let transport = ScriptedTransport(routes: ["/v1/tts": .http(status: 200, body: "")])
        let previewer = RealtimeVoicePreviewer(client: .test(transport: transport))
        await #expect(throws: XAIError.self) {
            try await previewer.sample(voice: .eve, speed: 1.0)
        }
    }

    @Test func withoutAKeyNothingIsSent() async {
        let transport = ScriptedTransport(routes: [:])
        let previewer = RealtimeVoicePreviewer(
            client: .test(store: InMemoryAPIKeyStore(), transport: transport))
        await #expect(throws: XAIError.missingAPIKey) {
            try await previewer.sample(voice: .eve, speed: 1.0)
        }
        #expect(transport.requests.isEmpty)
    }
}
