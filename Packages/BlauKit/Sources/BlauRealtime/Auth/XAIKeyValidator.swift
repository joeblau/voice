import Foundation
import os

/// What xAI says about a key that passed validation.
public struct XAIKeyStatus: Sendable, Equatable {
    /// The key's name in the xAI console, if xAI reported it.
    public var name: String?
    /// Whether minting a realtime client secret with the key worked.
    /// `false` only when the mint step was inconclusive (an unexpected
    /// response unrelated to the key); key and account problems throw.
    public var realtimeVerified: Bool

    public init(name: String? = nil, realtimeVerified: Bool = true) {
        self.name = name
        self.realtimeVerified = realtimeVerified
    }
}

/// Checks a key before it is stored.
public protocol XAIKeyValidating: Sendable {
    /// Returns what xAI reports about `key`, or throws why it can't be used.
    func validate(_ key: XAIAPIKey) async throws(XAIError) -> XAIKeyStatus
}

/// Validates a key with two cheap, unbilled calls:
///
/// 1. `GET /v1/api-key` returns the key's metadata, including
///    `api_key_blocked`, `api_key_disabled` and `team_blocked`. A wrong key
///    fails here with 400/401. If the endpoint is ever unavailable (404),
///    `GET /v1/models` is used instead, as the issue suggests.
/// 2. `POST /v1/realtime/client_secrets` mints a throwaway secret, which
///    proves the key may use the realtime voice API (an ACL-restricted key
///    gets 403) and surfaces "no credits" errors where xAI reports them at
///    mint time.
public struct XAIKeyValidator: XAIKeyValidating {
    static let apiKeyInfoPath = "/v1/api-key"
    static let modelsPath = "/v1/models"
    /// Lifetime of the throwaway secret (the value xAI's docs use).
    static let probeLifetime: Duration = .seconds(300)

    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "xai")

    private let client: XAIHTTPClient

    public init(client: XAIHTTPClient) {
        self.client = client
    }

    public func validate(_ key: XAIAPIKey) async throws(XAIError) -> XAIKeyStatus {
        var status = XAIKeyStatus()
        do throws(XAIError) {
            let info = try await client.send(.get(Self.apiKeyInfoPath), apiKey: key, decoding: APIKeyInfo.self)
            if info.apiKeyBlocked == true { throw XAIError.keyDisabled(.keyBlocked) }
            if info.apiKeyDisabled == true { throw XAIError.keyDisabled(.keyDisabled) }
            if info.teamBlocked == true { throw XAIError.keyDisabled(.teamBlocked) }
            status.name = info.name.flatMap { $0.isEmpty ? nil : $0 }
        } catch .badRequest(status: 404, _) {
            _ = try await client.send(.get(Self.modelsPath), apiKey: key)
        }

        do throws(XAIError) {
            _ = try await XAIClientSecretMinter(client: client).mint(lifetime: Self.probeLifetime, apiKey: key)
        } catch let error where error.requiresUserAction || error.isRetryable || error == .cancelled {
            throw error
        } catch {
            // The key itself was accepted above; an unexpected mint response
            // shouldn't block saving it. The token provider reports it again
            // when a session starts.
            Self.logger.error(
                "Realtime mint check was inconclusive: \(String(describing: error), privacy: .public)")
            status.realtimeVerified = false
        }
        return status
    }

    /// The fields Blau reads from `GET /v1/api-key`. Everything is optional
    /// so additions or removals on xAI's side don't break validation.
    struct APIKeyInfo: Decodable {
        let name: String?
        let apiKeyBlocked: Bool?
        let apiKeyDisabled: Bool?
        let teamBlocked: Bool?
    }
}
