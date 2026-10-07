import Foundation

/// Fetches a short spoken sample of a Grok voice for Settings → Voice's
/// preview button, from xAI's text-to-speech endpoint (`POST /v1/tts`) with
/// the user's key.
///
/// The realtime voices and the TTS voices share their ids (`eve`, `ara`...),
/// so the sample sounds like the conversation will. It is spoken at the
/// chosen speed. Samples are MP3 and cached in memory per voice and speed,
/// so replaying one doesn't call xAI again. Each new sample is a short TTS
/// request billed to the user's xAI account.
///
/// ```swift
/// let previewer = RealtimeVoicePreviewer(client: xai.client)
/// let mp3 = try await previewer.sample(voice: .ara, speed: 1.1)
/// ```
public actor RealtimeVoicePreviewer {
    /// xAI's text-to-speech endpoint.
    static let path = "/v1/tts"

    /// The body of `POST /v1/tts` (snake-cased by `XAIHTTPClient.encoder`).
    struct SpeechRequest: Encodable, Equatable {
        struct OutputFormat: Encodable, Equatable {
            var codec: String
            var sampleRate: Int
            var bitRate: Int
        }

        var text: String
        var voiceId: String
        var language: String
        var speed: Double
        var outputFormat: OutputFormat
    }

    private struct CacheKey: Hashable {
        var voice: RealtimeVoice
        var speed: Double
    }

    private let client: XAIHTTPClient
    private let language: String
    private var cache: [CacheKey: Data] = [:]

    /// - Parameters:
    ///   - client: The REST client, authenticated with the stored key.
    ///   - language: The sample's BCP-47 language; Blau's instructions to
    ///     Grok are in English.
    public init(client: XAIHTTPClient, language: String = "en") {
        self.client = client
        self.language = language
    }

    /// What the sample says.
    public static func sampleText(for voice: RealtimeVoice) -> String {
        "Hi, I'm \(voice.displayName). This is how I'll sound when we talk."
    }

    /// The `/v1/tts` request for `voice` at `speed` (clamped like the
    /// session's `audio.output.speed`).
    static func request(voice: RealtimeVoice, speed: Double, language: String) throws(XAIError)
        -> XAIHTTPClient.Request
    {
        let body = SpeechRequest(
            text: sampleText(for: voice),
            voiceId: (voice.normalized ?? .eve).rawValue,
            language: language,
            speed: RealtimeVoiceSettings.clampedSpeed(speed),
            outputFormat: .init(codec: "mp3", sampleRate: 24_000, bitRate: 64_000))
        var request = try XAIHTTPClient.Request.post(path, json: body)
        request.accept = "audio/mpeg"
        return request
    }

    /// An MP3 of `voice` saying ``sampleText(for:)`` at `speed`.
    ///
    /// - Throws: ``XAIError/missingAPIKey`` without a stored key, the
    ///   classified xAI failure, or ``XAIError/invalidResponse(_:)`` when
    ///   the reply has no audio.
    public func sample(voice: RealtimeVoice, speed: Double) async throws(XAIError) -> Data {
        let key = CacheKey(voice: voice.normalized ?? .eve, speed: RealtimeVoiceSettings.clampedSpeed(speed))
        if let cached = cache[key] { return cached }
        let request = try Self.request(voice: key.voice, speed: key.speed, language: language)
        let audio = try await client.send(request)
        guard !audio.isEmpty else { throw .invalidResponse("The voice preview had no audio") }
        cache[key] = audio
        return audio
    }

    /// Forgets every cached sample, e.g. after the key changes.
    public func clearCache() {
        cache.removeAll()
    }
}
