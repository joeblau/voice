import BlauCore
import Foundation

// Maps the realtime and xAI errors to the error catalog (#80,
// docs/errors.md). Details shown to the user are the sanitized server
// messages `XAIError` already keeps, or HTTP statuses: never a key, a token
// or anything the user said.

/// `URLError` codes that mean the device has no usable internet connection,
/// as opposed to xAI being unreachable.
enum OfflineURLErrors {
    static let codes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,
        URLError.dataNotAllowed.rawValue,
        URLError.internationalRoamingOff.rawValue,
        URLError.callIsActive.rawValue,
    ]

    /// TLS problems: a captive portal, a VPN, or the device's clock.
    static let insecure: Set<Int> = [
        URLError.serverCertificateUntrusted.rawValue,
        URLError.serverCertificateHasBadDate.rawValue,
        URLError.serverCertificateHasUnknownRoot.rawValue,
        URLError.serverCertificateNotYetValid.rawValue,
        URLError.secureConnectionFailed.rawValue,
        URLError.clientCertificateRejected.rawValue,
        URLError.appTransportSecurityRequiresSecureConnection.rawValue,
    ]

    static func issue(code: Int) -> UserFacingIssue {
        if codes.contains(code) { return UserFacingIssue(.offline) }
        if insecure.contains(code) { return UserFacingIssue(.secureConnectionFailed) }
        return UserFacingIssue(.grokUnreachable)
    }
}

extension XAIError {
    /// The catalog entry for this error.
    public var issue: UserFacingIssue {
        switch self {
        case .missingAPIKey:
            UserFacingIssue(.missingAPIKey)
        case .keyStore(.locked):
            UserFacingIssue(.keychainLocked)
        case .keyStore:
            UserFacingIssue(.keychainFailure)
        case .invalidAPIKey(let message):
            UserFacingIssue(.invalidAPIKey, detail: message)
        case .keyDisabled(.keyBlocked):
            UserFacingIssue(.apiKeyDisabled, detail: "The key is blocked.")
        case .keyDisabled(.keyDisabled):
            UserFacingIssue(.apiKeyDisabled, detail: "The key is disabled.")
        case .keyDisabled(.teamBlocked):
            UserFacingIssue(.apiKeyDisabled, detail: "The team that owns the key is blocked.")
        case .insufficientCredits(let message):
            UserFacingIssue(.insufficientCredits, detail: message)
        case .permissionDenied(let message):
            UserFacingIssue(.voiceNotPermitted, detail: message)
        case .rateLimited(let retryAfter):
            UserFacingIssue(
                .rateLimited,
                detail: retryAfter.map { "xAI asked to wait \(Self.seconds($0)) before trying again." })
        case .badRequest(let status, let message):
            UserFacingIssue(.unexpectedResponse, detail: Self.detail(status: status, message: message))
        case .server(let status, let message):
            UserFacingIssue(.xaiServerError, detail: Self.detail(status: status, message: message))
        case .network(let code):
            OfflineURLErrors.issue(code: code)
        case .invalidResponse:
            UserFacingIssue(.unexpectedResponse)
        case .cancelled:
            UserFacingIssue(.grokUnreachable)
        }
    }

    static func detail(status: Int, message: String?) -> String {
        if let message, !message.isEmpty { return "HTTP \(status): \(message)" }
        return "HTTP \(status)"
    }

    static func seconds(_ duration: Duration) -> String {
        let seconds = max(1, Int(duration.timeInterval.rounded(.up)))
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

extension RealtimeClientError {
    /// The catalog entry for this error.
    public var issue: UserFacingIssue {
        switch self {
        case .token(let error):
            error.issue
        case .unauthorized(let status):
            UserFacingIssue(.invalidAPIKey, detail: "HTTP \(status)")
        case .handshakeFailed(let status?) where status == 429:
            UserFacingIssue(.rateLimited)
        case .handshakeFailed(let status?) where status == 408 || status >= 500:
            UserFacingIssue(.xaiServerError, detail: "HTTP \(status)")
        case .handshakeFailed(let status?):
            UserFacingIssue(.unexpectedResponse, detail: "HTTP \(status)")
        case .handshakeFailed(nil):
            UserFacingIssue(.grokUnreachable)
        case .network(let code):
            OfflineURLErrors.issue(code: code)
        case .connectTimedOut, .pingTimedOut, .closed, .notConnected, .cancelled:
            UserFacingIssue(.grokUnreachable)
        case .encodingFailed:
            UserFacingIssue(.unexpectedResponse)
        }
    }
}

extension RealtimeErrorDetail {
    /// The catalog entry for an `error` event (or a failed response's
    /// `status_details.error`) that ended a turn.
    public var issue: UserFacingIssue {
        let code = (self.code ?? "").lowercased()
        let type = (self.type?.rawValue ?? "").lowercased()
        let detail = message.map(XAIError.sanitize)
        if code.contains("rate_limit") || type.contains("rate_limit") {
            return UserFacingIssue(.rateLimited, detail: detail)
        }
        if ["insufficient_quota", "credit", "billing", "spending"].contains(where: { code.contains($0) }) {
            return UserFacingIssue(.insufficientCredits, detail: detail)
        }
        if type == RealtimeErrorType.internalError.rawValue || code.contains("server_error") {
            return UserFacingIssue(.xaiServerError, detail: detail)
        }
        return UserFacingIssue(.replyFailed, detail: detail)
    }

    /// The error a failed response reports in `status_details`, e.g.
    /// `{"type": "failed", "error": {"type": "...", "code": "..."}}`.
    init?(statusDetails: JSONValue?) {
        guard let error = statusDetails?["error"], case .object = error else { return nil }
        self.init(
            type: error["type"]?.stringValue.map(RealtimeErrorType.init(rawValue:)),
            code: error["code"]?.stringValue,
            message: error["message"]?.stringValue)
    }
}

extension UserFacingIssue {
    /// This issue as the reason one reply failed (`TurnFailure.Kind.response`)
    /// while the connection stays open.
    ///
    /// Try Again reconnects, and the connection is already there, so it is
    /// dropped: the user says it again instead (the next utterance starts a
    /// new turn). The severity is capped at warning so the banner can be
    /// dismissed, even for `account.noCredits`, which blocks only when it
    /// stops the connection itself. Connection-level wording ("Blau tries
    /// again shortly") is replaced, since nothing is retried by itself.
    public var asReplyFailure: UserFacingIssue {
        var issue = self
        issue.actions.removeAll { $0 == .retry }
        issue.severity = min(issue.severity, .warning)
        switch code {
        case .rateLimited:
            issue.message = "xAI is limiting requests from your key right now. Wait a moment, then say it again."
        case .xaiServerError:
            issue.message = "xAI's servers returned an error for that reply. Say it again to retry."
        case .insufficientCredits:
            issue.message =
                "Your xAI team has no credits left or hit its spending limit. Add credits at console.x.ai, then "
                + "say it again."
        case .unexpectedResponse:
            issue.message = "xAI sent something Blau didn't expect. Say it again; if it keeps happening, update Blau."
        default:
            break
        }
        return issue
    }
}

extension TurnFailure.Kind {
    /// The catalog entry for a failure of this kind with no more specific
    /// cause.
    var defaultIssue: UserFacingIssue {
        switch self {
        case .connection: UserFacingIssue(.grokUnreachable)
        case .response: UserFacingIssue(.replyFailed)
        case .persistence: UserFacingIssue(.transcriptNotSaved)
        }
    }
}
