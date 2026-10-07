import Foundation

/// Everything that can go wrong talking to the xAI REST API with the user's
/// key. Messages from xAI are kept (sanitized and truncated, see
/// ``XAIError/sanitize(_:)``) so the UI can show specifics.
public enum XAIError: Error, Sendable, Equatable {
    /// No key is stored. The user has to enter one in onboarding or Settings.
    case missingAPIKey
    /// The key store failed.
    case keyStore(APIKeyStoreError)
    /// xAI rejected the key: wrong, revoked or mistyped (HTTP 400/401).
    case invalidAPIKey(message: String?)
    /// The key exists but is switched off.
    case keyDisabled(KeyDisabledReason)
    /// The key's team has no credits left or hit its spending limit.
    case insufficientCredits(message: String?)
    /// The key is valid but not allowed to call this endpoint or model
    /// (HTTP 403 for an ACL-restricted key).
    case permissionDenied(message: String?)
    /// Too many requests (HTTP 429). `retryAfter` is the server's hint.
    case rateLimited(retryAfter: Duration?)
    /// The request was malformed (HTTP 400/404/422 for reasons other than
    /// the key). A bug in Blau, not something the user can fix.
    case badRequest(status: Int, message: String?)
    /// xAI had a problem (HTTP 408 or 5xx).
    case server(status: Int, message: String?)
    /// The request never got a response: offline, DNS, TLS, timeout.
    /// `code` is the `URLError.Code` raw value.
    case network(code: Int)
    /// The response wasn't what the API documents.
    case invalidResponse(String)
    /// The calling task was cancelled.
    case cancelled

    /// Why xAI reports a key as switched off (`GET /v1/api-key`).
    public enum KeyDisabledReason: String, Sendable, Equatable {
        /// `api_key_blocked`
        case keyBlocked
        /// `api_key_disabled`
        case keyDisabled
        /// `team_blocked`
        case teamBlocked
    }

    /// Whether the same request may succeed if tried again later without the
    /// user changing anything.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server:
            true
        case .network(let code):
            !Self.permanentNetworkFailures.contains(code)
        case .keyStore(.locked):
            true
        case .missingAPIKey, .keyStore, .invalidAPIKey, .keyDisabled, .insufficientCredits, .permissionDenied,
            .badRequest, .invalidResponse, .cancelled:
            false
        }
    }

    /// `URLError` codes that retrying won't fix: a cancelled request or a
    /// server certificate problem.
    static let permanentNetworkFailures: Set<Int> = [
        URLError.cancelled.rawValue,
        URLError.serverCertificateUntrusted.rawValue,
        URLError.serverCertificateHasBadDate.rawValue,
        URLError.serverCertificateHasUnknownRoot.rawValue,
        URLError.serverCertificateNotYetValid.rawValue,
        URLError.appTransportSecurityRequiresSecureConnection.rawValue,
    ]

    /// Whether the user has to change something about their key or account
    /// (enter a new key, add credits, unblock it) before calls can succeed.
    public var requiresUserAction: Bool {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .keyDisabled, .insufficientCredits, .permissionDenied:
            true
        default:
            false
        }
    }
}

// MARK: - Classifying HTTP responses

extension XAIError {
    /// Maps a non-2xx response to an error.
    ///
    /// xAI documents 400 for an invalid key on some endpoints, 401 for a
    /// missing or invalid `Authorization` header, 403 for permission problems
    /// (including teams without credits) and 429 for rate limits. Credit
    /// problems are recognised from the message, since xAI reports them with
    /// different status codes on different endpoints.
    static func classify(status: Int, body: Data, headers: [AnyHashable: Any] = [:]) -> XAIError {
        let message = errorMessage(in: body)
        let lowered = message?.lowercased() ?? ""

        if mentionsCredits(lowered) && [400, 402, 403, 429].contains(status) {
            return .insufficientCredits(message: message)
        }
        switch status {
        case 400 where mentionsAPIKey(lowered), 401:
            return .invalidAPIKey(message: message)
        case 402:
            return .insufficientCredits(message: message)
        case 403:
            if lowered.contains("blocked") { return .keyDisabled(.keyBlocked) }
            if lowered.contains("disabled") { return .keyDisabled(.keyDisabled) }
            return .permissionDenied(message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: headers))
        case 408, 500...599:
            return .server(status: status, message: message)
        default:
            return .badRequest(status: status, message: message)
        }
    }

    private static func mentionsAPIKey(_ lowered: String) -> Bool {
        ["api key", "api-key", "apikey", "api_key", "authorization", "unauthorized", "authentication"]
            .contains(where: lowered.contains)
    }

    private static func mentionsCredits(_ lowered: String) -> Bool {
        ["credit", "spending limit", "billing", "payment", "insufficient funds", "license"]
            .contains(where: lowered.contains)
    }

    /// The human-readable message in an error body. Understands xAI's
    /// `{"code": …, "error": "…"}` and the OpenAI-style
    /// `{"error": {"message": "…"}}`, and falls back to plain text.
    static func errorMessage(in body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let nested = object["error"] as? [String: Any]
            let candidates: [Any?] = [object["error"], nested?["message"], object["message"], object["detail"]]
            if let text = candidates.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                return sanitize(text)
            }
            return nil
        }
        return String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : sanitize($0) }
    }

    /// The longest message kept from a response body.
    static let maximumMessageLength = 300

    /// Trims, truncates and masks anything key-shaped (`xai-` followed by
    /// eight or more key characters) so an echoed key never reaches the UI
    /// or logs.
    static func sanitize(_ text: String) -> String {
        let masked = text.replacing(/xai-[A-Za-z0-9_\-*•.]{8,}/) { _ in "xai-…" }
        let trimmed = masked.trimmingWhitespace()
        guard trimmed.count > maximumMessageLength else { return trimmed }
        return String(trimmed.prefix(maximumMessageLength)) + "…"
    }

    /// `Retry-After` in seconds (the HTTP-date form is ignored).
    static func retryAfter(in headers: [AnyHashable: Any]) -> Duration? {
        let value = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value
        guard let text = value as? String, let seconds = Double(text.trimmingWhitespace()), seconds >= 0 else {
            return nil
        }
        return .milliseconds(Int64((seconds * 1_000).rounded()))
    }
}
