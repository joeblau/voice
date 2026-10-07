import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

@Suite("Realtime errors → error catalog")
struct RealtimeIssueMappingTests {
    @Test(arguments: [
        (XAIError.missingAPIKey, IssueCode.missingAPIKey),
        (.keyStore(.locked), .keychainLocked),
        (.keyStore(.corruptItem), .keychainFailure),
        (.keyStore(.keychain(status: -25300)), .keychainFailure),
        (.invalidAPIKey(message: "Incorrect API key"), .invalidAPIKey),
        (.keyDisabled(.keyBlocked), .apiKeyDisabled),
        (.keyDisabled(.teamBlocked), .apiKeyDisabled),
        (.insufficientCredits(message: nil), .insufficientCredits),
        (.permissionDenied(message: nil), .voiceNotPermitted),
        (.rateLimited(retryAfter: .seconds(3)), .rateLimited),
        (.badRequest(status: 422, message: "bad"), .unexpectedResponse),
        (.server(status: 503, message: nil), .xaiServerError),
        (.network(code: URLError.notConnectedToInternet.rawValue), .offline),
        (.network(code: URLError.dataNotAllowed.rawValue), .offline),
        (.network(code: URLError.timedOut.rawValue), .grokUnreachable),
        (.network(code: URLError.serverCertificateUntrusted.rawValue), .secureConnectionFailed),
        (.invalidResponse("no secret"), .unexpectedResponse),
    ])
    func xaiErrors(error: XAIError, code: IssueCode) {
        #expect(error.issue.code == code)
        #expect(RealtimeClientError.token(error).issue.code == code)
    }

    @Test func detailsCarrySanitizedServerMessages() {
        #expect(XAIError.invalidAPIKey(message: "Incorrect API key").issue.detail == "Incorrect API key")
        #expect(
            XAIError.rateLimited(retryAfter: .seconds(3)).issue.detail
                == "xAI asked to wait 3 seconds before trying again.")
        #expect(XAIError.rateLimited(retryAfter: .milliseconds(200)).issue.detail?.contains("1 second") == true)
        #expect(XAIError.rateLimited(retryAfter: nil).issue.detail == nil)
        #expect(XAIError.server(status: 502, message: "Bad gateway").issue.detail == "HTTP 502: Bad gateway")
        #expect(XAIError.badRequest(status: 404, message: nil).issue.detail == "HTTP 404")
    }

    @Test(arguments: [
        (RealtimeClientError.unauthorized(status: 401), IssueCode.invalidAPIKey),
        (.handshakeFailed(status: 429), .rateLimited),
        (.handshakeFailed(status: 500), .xaiServerError),
        (.handshakeFailed(status: 408), .xaiServerError),
        (.handshakeFailed(status: 404), .unexpectedResponse),
        (.handshakeFailed(status: nil), .grokUnreachable),
        (.network(code: URLError.notConnectedToInternet.rawValue), .offline),
        (.network(code: URLError.networkConnectionLost.rawValue), .grokUnreachable),
        (.network(code: URLError.secureConnectionFailed.rawValue), .secureConnectionFailed),
        (.connectTimedOut, .grokUnreachable),
        (.pingTimedOut, .grokUnreachable),
        (.closed(code: RealtimeCloseCode(rawValue: 1011), reason: nil), .grokUnreachable),
        (.encodingFailed("x"), .unexpectedResponse),
    ])
    func clientErrors(error: RealtimeClientError, code: IssueCode) {
        #expect(error.issue.code == code)
    }

    @Test(arguments: [
        (RealtimeErrorDetail(type: "rate_limit_error", code: "rate_limit_exceeded"), IssueCode.rateLimited),
        (RealtimeErrorDetail(type: .invalidRequest, code: "insufficient_quota"), .insufficientCredits),
        (RealtimeErrorDetail(type: .internalError, code: nil), .xaiServerError),
        (RealtimeErrorDetail(type: .invalidRequest, code: "invalid_value", message: "Bad"), .replyFailed),
        (RealtimeErrorDetail(), .replyFailed),
    ])
    func serverErrors(detail: RealtimeErrorDetail, code: IssueCode) {
        #expect(detail.issue.code == code)
    }

    @Test func serverMessagesAreSanitized() {
        let detail = RealtimeErrorDetail(code: "invalid_api_key", message: "Key xai-abcdefghijklmnop is wrong")
        #expect(detail.issue.detail == "Key xai-… is wrong")
    }

    @Test func aFailedResponsesStatusDetailsAreRead() {
        let details: JSONValue = [
            "type": "failed", "error": ["type": "rate_limit_error", "code": "rate_limit_exceeded", "message": "Slow"],
        ]
        let error = RealtimeErrorDetail(statusDetails: details)
        #expect(error?.code == "rate_limit_exceeded")
        #expect(error?.message == "Slow")
        #expect(RealtimeErrorDetail(statusDetails: nil) == nil)
        #expect(RealtimeErrorDetail(statusDetails: ["type": "cancelled", "reason": "client_cancelled"]) == nil)
        #expect(RealtimeErrorDetail(statusDetails: ["error": "boom"]) == nil)
    }

    @Test func turnFailuresDefaultToTheirKindsEntry() {
        #expect(TurnFailure(kind: .connection, message: "x").issue.code == .grokUnreachable)
        #expect(TurnFailure(kind: .response, message: "x").issue.code == .replyFailed)
        #expect(TurnFailure(kind: .persistence, message: "x").issue.code == .transcriptNotSaved)
        let failure = TurnFailure(connectionError: .token(.missingAPIKey))
        #expect(failure.issue.code == .missingAPIKey)
        #expect(failure.requiresUserAction)
    }

    /// Try Again only reconnects, and a failed reply leaves the connection
    /// open, so a reply-level failure never offers it, and its banner can
    /// always be dismissed (review of #139).
    @Test(arguments: [
        RealtimeErrorDetail(type: "rate_limit_error", code: "rate_limit_exceeded"),
        RealtimeErrorDetail(type: .invalidRequest, code: "insufficient_quota"),
        RealtimeErrorDetail(type: .internalError, code: nil),
        RealtimeErrorDetail(type: .invalidRequest, code: "invalid_value", message: "Bad"),
    ])
    func replyFailuresOfferNoTryAgainAndCanBeDismissed(detail: RealtimeErrorDetail) {
        let failure = TurnFailure(kind: .response, message: "x", issue: detail.issue)
        #expect(failure.issue.code == detail.issue.code)
        #expect(!failure.issue.actions.contains(.retry))
        #expect(failure.issue.severity <= .warning)
        #expect(IssueBoard.canDismiss(failure.issue))
        #expect(!failure.issue.message.contains("tries again"))
        #expect(!failure.issue.message.contains("keeps trying"))
    }

    @Test func noCreditsBlocksOnlyWhenItStopsTheConnection() {
        let connection = TurnFailure(connectionError: .token(.insufficientCredits(message: nil)))
        #expect(connection.issue.code == .insufficientCredits)
        #expect(connection.issue.severity == .blocking)
        #expect(connection.issue.actions == [.openXAIConsole, .retry])

        let reply = TurnFailure(kind: .response, message: "x", issue: UserFacingIssue(.insufficientCredits))
        #expect(reply.issue.severity == .warning)
        #expect(reply.issue.actions == [.openXAIConsole])
        #expect(reply.issue.message.hasSuffix("then say it again."))

        var board = IssueBoard()
        board.update(.conversation, reply.issue)
        board.dismiss(.insufficientCredits)
        #expect(board.visible.isEmpty)
    }
}

@Suite("Conversation connectivity")
struct ConversationConnectivityTests {
    func snapshot(
        connection: RealtimeClient.ConnectionState, phase: RealtimeSessionContinuity.Phase,
        network: NetworkReachability = .reachable, queued: Int = 0, state: TurnState = .listening
    ) -> TurnSnapshot {
        TurnSnapshot(
            state: state, connection: connection, conversationID: ConversationID(), queuedUtterances: queued,
            network: network, session: RealtimeSessionContinuity(phase: phase))
    }

    @Test func noConversationIsInactive() {
        #expect(TurnSnapshot().connectivity == .inactive)
        #expect(TurnSnapshot().issue == nil)
    }

    @Test func theSessionPhaseDecidesWhileConnected() {
        #expect(snapshot(connection: .connected, phase: .live).connectivity == .online)
        #expect(snapshot(connection: .connecting(attempt: 1), phase: .connecting).connectivity == .connecting)
        #expect(snapshot(connection: .connected, phase: .rollingOver).connectivity == .renewing)
        #expect(snapshot(connection: .connected, phase: .resuming).connectivity == .reconnecting)
        #expect(snapshot(connection: .reconnecting(attempt: 2), phase: .reconnecting).connectivity == .reconnecting)
    }

    @Test func noNetworkIsOfflineWhateverTheConnectionSays() {
        #expect(
            snapshot(connection: .reconnecting(attempt: 3), phase: .reconnecting, network: .unreachable).connectivity
                == .offline)
        #expect(snapshot(connection: .connected, phase: .live, network: .unreachable).connectivity == .offline)
        // An unknown network doesn't count as offline.
        #expect(snapshot(connection: .connected, phase: .live, network: .unknown).connectivity == .online)
    }

    @Test func aConnectionThatGaveUpSaysWhy() {
        let offline = snapshot(
            connection: .disconnected(.network(code: URLError.notConnectedToInternet.rawValue)), phase: .reconnecting)
        #expect(offline.connectivity == .offline)
        let outage = snapshot(connection: .disconnected(.handshakeFailed(status: 503)), phase: .reconnecting)
        #expect(outage.connectivity == .unavailable(UserFacingIssue(.xaiServerError, detail: "HTTP 503")))
        // A deliberate disconnect isn't a problem.
        #expect(snapshot(connection: .disconnected(.cancelled), phase: .connecting).connectivity == .connecting)
        #expect(snapshot(connection: .disconnected(nil), phase: .connecting).connectivity == .connecting)
    }

    @Test func repliesWaitOnlyForRealOutages() {
        #expect(!ConversationConnectivity.online.defersReplies)
        #expect(!ConversationConnectivity.connecting.defersReplies)
        #expect(!ConversationConnectivity.renewing.defersReplies)
        #expect(ConversationConnectivity.reconnecting.defersReplies)
        #expect(ConversationConnectivity.offline.defersReplies)
        #expect(ConversationConnectivity.unavailable(UserFacingIssue(.rateLimited)).defersReplies)
    }

    @Test func theIssueCountsWhatIsWaitingAndOffersToDiscardIt() {
        let one = snapshot(
            connection: .reconnecting(attempt: 1), phase: .reconnecting, network: .unreachable, queued: 1)
        #expect(one.issue?.code == .offline)
        #expect(one.issue?.message == UserFacingIssue(.offline).message + " 1 message is waiting to send.")
        #expect(one.issue?.actions == [.discardQueued])

        let outage = snapshot(connection: .disconnected(.handshakeFailed(status: 503)), phase: .reconnecting, queued: 4)
        #expect(outage.issue?.code == .xaiServerError)
        #expect(outage.issue?.message.hasSuffix("4 messages are waiting to send.") == true)
        #expect(outage.issue?.actions == [.retry, .discardQueued])

        let nothingWaiting = snapshot(connection: .reconnecting(attempt: 1), phase: .reconnecting)
        #expect(nothingWaiting.issue == UserFacingIssue(.reconnecting))
    }

    @Test func aFailedTurnShowsWhenTheConnectionIsFine() {
        let failure = TurnFailure(kind: .response, message: "x", issue: UserFacingIssue(.rateLimited))
        let shown = snapshot(connection: .connected, phase: .live, state: .error(failure)).issue
        #expect(shown?.code == .rateLimited)
        #expect(shown?.actions == [])
        #expect(shown?.severity == .warning)
        // A connection failure is reported through the connection.
        let connection = TurnFailure(connectionError: .handshakeFailed(status: 503))
        #expect(snapshot(connection: .connected, phase: .live, state: .error(connection)).issue == nil)
        #expect(snapshot(connection: .connected, phase: .live).issue == nil)
    }
}
