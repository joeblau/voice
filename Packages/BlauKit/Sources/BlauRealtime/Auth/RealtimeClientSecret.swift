import Foundation

/// A short-lived realtime credential ("ephemeral token") minted from the
/// user's API key with `POST /v1/realtime/client_secrets`.
///
/// It authenticates exactly one thing: the realtime WebSocket upgrade, via
/// the ``webSocketSubprotocol``. `URLSessionWebSocketTask` strips the
/// `Authorization` header from the upgrade request, so the secret travels in
/// `Sec-WebSocket-Protocol` instead (issue #1, "Key decisions").
///
/// Like ``XAIAPIKey`` it never appears in descriptions or logs.
public struct RealtimeClientSecret: Sendable, Hashable {
    /// Prefix xAI expects in `Sec-WebSocket-Protocol`.
    public static let subprotocolPrefix = "xai-client-secret."

    /// The secret. Pass it only to the WebSocket.
    public let value: String

    /// When xAI says the secret expires (`expires_at`), on the server's
    /// clock. `nil` if the response didn't say.
    public let expiresAt: Date?

    public init(value: String, expiresAt: Date?) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// `xai-client-secret.<secret>`, for
    /// `URLSession.webSocketTask(with:protocols:)`.
    public var webSocketSubprotocol: String {
        Self.subprotocolPrefix + value
    }
}

extension RealtimeClientSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "RealtimeClientSecret(<redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["value": "<redacted>", "expiresAt": expiresAt as Any], displayStyle: .struct)
    }
}

/// Mints realtime client secrets. ``TokenProvider`` caches and refreshes
/// what this returns. Should Blau ever ship on a shared xAI account, a
/// minting proxy can implement this protocol without changing any caller.
public protocol RealtimeClientSecretMinting: Sendable {
    /// Mints a secret valid for `lifetime`.
    func mintClientSecret(lifetime: Duration) async throws(XAIError) -> RealtimeClientSecret
}

/// Mints client secrets on device with the user's key. No backend.
///
/// Request, per https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens:
///
///     POST /v1/realtime/client_secrets
///     Authorization: Bearer <key>
///     {"expires_after":{"seconds":600}}
///
/// The endpoint rejects a `session` object (and `expires_after.anchor`), so
/// the model is chosen on the WebSocket URL (`?model=…`) and with
/// `session.update` instead. The response carries `value` and `expires_at`
/// (Unix seconds) at the top level; the OpenAI-style nested
/// `client_secret: {value, expires_at}` is accepted as well.
public struct XAIClientSecretMinter: RealtimeClientSecretMinting {
    static let path = "/v1/realtime/client_secrets"

    /// xAI accepts lifetimes up to an hour.
    public static let maximumLifetime: Duration = .seconds(3_600)

    private let client: XAIHTTPClient

    public init(client: XAIHTTPClient) {
        self.client = client
    }

    public func mintClientSecret(lifetime: Duration) async throws(XAIError) -> RealtimeClientSecret {
        try await mint(lifetime: lifetime, apiKey: nil)
    }

    /// Mints with an explicit key (used by ``XAIKeyValidator`` before the key
    /// is stored), or with the stored key when `apiKey` is `nil`.
    func mint(lifetime: Duration, apiKey: XAIAPIKey?) async throws(XAIError) -> RealtimeClientSecret {
        let request = try XAIHTTPClient.Request.post(
            Self.path, json: Body(expiresAfter: .init(seconds: Self.wholeSeconds(lifetime))))
        let response = try await client.send(request, apiKey: apiKey, decoding: Response.self)
        guard let value = response.value, !value.isEmpty else {
            throw .invalidResponse("client_secrets response has no value")
        }
        return RealtimeClientSecret(value: value, expiresAt: response.expiresAt)
    }

    /// Clamped to 1…3600 s, as the endpoint takes whole seconds.
    static func wholeSeconds(_ lifetime: Duration) -> Int {
        let seconds = Int(lifetime.components.seconds)
        return min(max(seconds, 1), Int(maximumLifetime.components.seconds))
    }

    struct Body: Encodable {
        struct ExpiresAfter: Encodable {
            var seconds: Int
        }
        var expiresAfter: ExpiresAfter
    }

    struct Response: Decodable {
        let value: String?
        let expiresAt: Date?

        private struct Nested: Decodable {
            let value: String?
            let expiresAt: Double?
        }

        private enum CodingKeys: String, CodingKey {
            case value, expiresAt, clientSecret
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerate a shape we don't know (e.g. a bare string) as long as `value` is present.
            let nested = (try? container.decodeIfPresent(Nested.self, forKey: .clientSecret)) ?? nil
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? nested?.value
            let seconds = try container.decodeIfPresent(Double.self, forKey: .expiresAt) ?? nested?.expiresAt
            expiresAt = seconds.map { Date(timeIntervalSince1970: $0) }
        }
    }
}
