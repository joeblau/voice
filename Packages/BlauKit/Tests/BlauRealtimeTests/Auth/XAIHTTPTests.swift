import Foundation
import Testing

@testable import BlauRealtime

@Suite("XAIError classification")
struct XAIErrorTests {
    private func classify(_ status: Int, _ body: String, headers: [String: String] = [:]) -> XAIError {
        XAIError.classify(status: status, body: Data(body.utf8), headers: headers)
    }

    @Test func invalidKeyOn400And401() {
        let message = "Incorrect API key provided: xa***b2. You can obtain an API key from https://console.x.ai."
        #expect(
            classify(400, #"{"code":"Client specified an invalid argument","error":"\#(message)"}"#)
                == .invalidAPIKey(message: message))
        #expect(classify(401, "") == .invalidAPIKey(message: nil))
    }

    @Test func otherBadRequestsAreNotBlamedOnTheKey() {
        #expect(
            classify(400, #"{"error":"expires_after.seconds must be positive"}"#)
                == .badRequest(status: 400, message: "expires_after.seconds must be positive"))
        #expect(classify(422, "nope") == .badRequest(status: 422, message: "nope"))
    }

    @Test func creditProblemsAreRecognisedWhateverTheStatus() {
        let body = #"{"error":"Your team doesn't have any credits yet. Purchase credits at console.x.ai."}"#
        for status in [400, 402, 403, 429] {
            #expect(classify(status, body) == .insufficientCredits(message: XAIError.errorMessage(in: Data(body.utf8))))
        }
        #expect(classify(402, "") == .insufficientCredits(message: nil))
        #expect(
            classify(429, #"{"error":"You have reached your monthly spending limit"}"#)
                == .insufficientCredits(message: "You have reached your monthly spending limit"))
    }

    @Test func forbiddenMapsToPermissionOrDisabledKey() {
        #expect(
            classify(403, #"{"error":"The API key does not have permission to access model grok-voice"}"#)
                == .permissionDenied(message: "The API key does not have permission to access model grok-voice"))
        #expect(classify(403, #"{"error":"API key is blocked"}"#) == .keyDisabled(.keyBlocked))
        #expect(classify(403, #"{"error":"API key is disabled"}"#) == .keyDisabled(.keyDisabled))
    }

    @Test func rateLimitsCarryRetryAfter() {
        #expect(classify(429, "slow down", headers: ["Retry-After": "3"]) == .rateLimited(retryAfter: .seconds(3)))
        #expect(
            classify(429, "slow down", headers: ["retry-after": "0.5"]) == .rateLimited(retryAfter: .milliseconds(500)))
        #expect(
            classify(429, "slow down", headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])
                == .rateLimited(retryAfter: nil))
    }

    @Test func serverErrors() {
        #expect(classify(503, "<html>down</html>") == .server(status: 503, message: "<html>down</html>"))
        #expect(classify(408, "") == .server(status: 408, message: nil))
    }

    @Test func understandsOpenAIStyleErrorBodies() {
        #expect(XAIError.errorMessage(in: Data(#"{"error":{"message":"bad","type":"x"}}"#.utf8)) == "bad")
        #expect(XAIError.errorMessage(in: Data(#"{"message":"also bad"}"#.utf8)) == "also bad")
    }

    @Test func messagesNeverCarryAKey() {
        let body = #"{"error":"Incorrect API key provided: \#(TestKeys.primaryRaw)"}"#
        let message = XAIError.errorMessage(in: Data(body.utf8))
        #expect(message == "Incorrect API key provided: xai-…")
    }

    @Test func longMessagesAreTruncated() {
        let message = XAIError.sanitize(String(repeating: "x", count: 1_000))
        #expect(message.count == XAIError.maximumMessageLength + 1)
    }

    @Test func retryability() {
        #expect(XAIError.network(code: URLError.notConnectedToInternet.rawValue).isRetryable)
        #expect(XAIError.network(code: URLError.timedOut.rawValue).isRetryable)
        #expect(!XAIError.network(code: URLError.serverCertificateUntrusted.rawValue).isRetryable)
        #expect(XAIError.server(status: 502, message: nil).isRetryable)
        #expect(XAIError.rateLimited(retryAfter: nil).isRetryable)
        #expect(XAIError.keyStore(.locked).isRetryable)
        for error: XAIError in [
            .missingAPIKey, .invalidAPIKey(message: nil), .keyDisabled(.teamBlocked),
            .insufficientCredits(message: nil),
            .permissionDenied(message: nil), .badRequest(status: 400, message: nil), .cancelled,
        ] {
            #expect(!error.isRetryable, "\(error)")
        }
    }

    @Test func userActionIsNeededOnlyForKeyAndAccountProblems() {
        #expect(XAIError.invalidAPIKey(message: nil).requiresUserAction)
        #expect(XAIError.insufficientCredits(message: nil).requiresUserAction)
        #expect(XAIError.missingAPIKey.requiresUserAction)
        #expect(!XAIError.network(code: URLError.notConnectedToInternet.rawValue).requiresUserAction)
        #expect(!XAIError.server(status: 500, message: nil).requiresUserAction)
    }
}

@Suite("XAIHTTPClient")
struct XAIHTTPClientTests {
    @Test func authenticatesWithTheStoredKey() async throws {
        let transport = ScriptedTransport { _ in .json(200, "{}") }
        _ = try await XAIHTTPClient.test(transport: transport).send(.get("/v1/models"))

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.primaryRaw)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func postsJSON() async throws {
        let transport = ScriptedTransport { _ in .json(200, "{}") }
        struct Body: Encodable { var someField = 1 }
        _ = try await XAIHTTPClient.test(transport: transport).send(try .post("/v1/x", json: Body()))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"some_field":1}"#)
    }

    @Test func anExplicitKeyOverridesTheStore() async throws {
        let transport = ScriptedTransport { _ in .json(200, "{}") }
        _ = try await XAIHTTPClient.test(store: InMemoryAPIKeyStore(), transport: transport)
            .send(.get("/v1/models"), apiKey: TestKeys.secondary)
        #expect(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.secondaryRaw)")
    }

    @Test func failsWithoutAStoredKeyAndSendsNothing() async {
        let transport = ScriptedTransport { _ in .json(200, "{}") }
        await #expect(throws: XAIError.missingAPIKey) {
            try await XAIHTTPClient.test(store: InMemoryAPIKeyStore(), transport: transport).send(.get("/v1/models"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func reportsKeyStoreFailures() async {
        let transport = ScriptedTransport { _ in .json(200, "{}") }
        await #expect(throws: XAIError.keyStore(.locked)) {
            try await XAIHTTPClient.test(store: FailingAPIKeyStore(error: .locked), transport: transport)
                .send(.get("/v1/models"))
        }
    }

    @Test func mapsTransportFailures() async {
        let offline = ScriptedTransport { _ in .failure(.notConnectedToInternet) }
        await #expect(throws: XAIError.network(code: URLError.notConnectedToInternet.rawValue)) {
            try await XAIHTTPClient.test(transport: offline).send(.get("/v1/models"))
        }
        let cancelled = ScriptedTransport { _ in .failure(.cancelled) }
        await #expect(throws: XAIError.cancelled) {
            try await XAIHTTPClient.test(transport: cancelled).send(.get("/v1/models"))
        }
    }

    @Test func classifiesErrorStatuses() async {
        let transport = ScriptedTransport { _ in .json(401, #"{"error":"Unauthorized"}"#) }
        await #expect(throws: XAIError.invalidAPIKey(message: "Unauthorized")) {
            try await XAIHTTPClient.test(transport: transport).send(.get("/v1/models"))
        }
    }

    @Test func reportsUndecodableResponses() async {
        struct Expected: Decodable { var value: String }
        let transport = ScriptedTransport { _ in .json(200, "[]") }
        await #expect {
            try await XAIHTTPClient.test(transport: transport).send(.get("/v1/x"), decoding: Expected.self)
        } throws: { error in
            if case .invalidResponse = error as? XAIError { true } else { false }
        }
    }
}

@Suite("XAIClientSecretMinter")
struct XAIClientSecretMinterTests {
    @Test func requestsAClientSecretWithTheDocumentedBody() async throws {
        let transport = ScriptedTransport { _ in .json(200, #"{"value":"secret-abc","expires_at":1900000000}"#) }
        let minter = XAIClientSecretMinter(client: .test(transport: transport))

        let secret = try await minter.mintClientSecret(lifetime: .seconds(600))

        #expect(secret.value == "secret-abc")
        #expect(secret.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/realtime/client_secrets")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.primaryRaw)")
        // xAI rejects a `session` object here; the model goes on the WebSocket URL.
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"expires_after":{"seconds":600}}"#)
    }

    @Test func acceptsTheNestedClientSecretShape() async throws {
        let transport = ScriptedTransport { _ in
            .json(200, #"{"client_secret":{"value":"nested","expires_at":1900000000.5}}"#)
        }
        let secret = try await XAIClientSecretMinter(client: .test(transport: transport))
            .mintClientSecret(lifetime: .seconds(60))
        #expect(secret.value == "nested")
        #expect(secret.expiresAt == Date(timeIntervalSince1970: 1_900_000_000.5))
    }

    @Test func toleratesAMissingExpiry() async throws {
        let transport = ScriptedTransport { _ in .json(200, #"{"value":"v"}"#) }
        let secret = try await XAIClientSecretMinter(client: .test(transport: transport))
            .mintClientSecret(lifetime: .seconds(60))
        #expect(secret.expiresAt == nil)
    }

    @Test func rejectsAResponseWithoutASecret() async {
        let transport = ScriptedTransport { _ in .json(200, #"{"expires_at":1}"#) }
        await #expect {
            try await XAIClientSecretMinter(client: .test(transport: transport)).mintClientSecret(
                lifetime: .seconds(60))
        } throws: { error in
            if case .invalidResponse = error as? XAIError { true } else { false }
        }
    }

    @Test func clampsTheLifetimeToWhatXAIAccepts() {
        #expect(XAIClientSecretMinter.wholeSeconds(.seconds(600)) == 600)
        #expect(XAIClientSecretMinter.wholeSeconds(.milliseconds(1_999)) == 1)
        #expect(XAIClientSecretMinter.wholeSeconds(.zero) == 1)
        #expect(XAIClientSecretMinter.wholeSeconds(.seconds(7_200)) == 3_600)
    }

    @Test func secretsAreRedactedAndBuildTheWebSocketSubprotocol() {
        let secret = RealtimeClientSecret(value: "very-secret-value", expiresAt: nil)
        #expect(secret.webSocketSubprotocol == "xai-client-secret.very-secret-value")
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [secret.description, secret.debugDescription, "\(secret)", dumped] {
            #expect(!text.contains("very-secret-value"))
        }
    }
}

@Suite("XAIKeyValidator")
struct XAIKeyValidatorTests {
    private static let mintOK = ScriptedTransport.Reply.json(200, #"{"value":"probe","expires_at":1900000000}"#)

    private func validate(_ routes: [String: ScriptedTransport.Reply]) async throws(XAIError) -> (
        XAIKeyStatus, ScriptedTransport
    ) {
        let transport = ScriptedTransport(routes: routes)
        // Validation uses the candidate key, never what is stored.
        let client = XAIHTTPClient.test(store: InMemoryAPIKeyStore(key: TestKeys.secondary), transport: transport)
        return (try await XAIKeyValidator(client: client).validate(TestKeys.primary), transport)
    }

    @Test func acceptsAWorkingKey() async throws {
        let (status, transport) = try await validate([
            "/v1/api-key": .json(
                200,
                #"{"name":"blau","api_key_blocked":false,"api_key_disabled":false,"team_blocked":false,"acls":["api-key:model:*"]}"#
            ),
            "/v1/realtime/client_secrets": Self.mintOK,
        ])
        #expect(status == XAIKeyStatus(name: "blau", realtimeVerified: true))
        #expect(transport.requests.map { $0.url?.path } == ["/v1/api-key", "/v1/realtime/client_secrets"])
        #expect(
            transport.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.primaryRaw)"
            })
    }

    @Test func rejectsAWrongKey() async {
        await #expect(throws: XAIError.invalidAPIKey(message: "Incorrect API key provided")) {
            try await validate(["/v1/api-key": .json(400, #"{"error":"Incorrect API key provided"}"#)])
        }
    }

    @Test(arguments: [
        ("api_key_blocked", XAIError.KeyDisabledReason.keyBlocked),
        ("api_key_disabled", .keyDisabled),
        ("team_blocked", .teamBlocked),
    ])
    func rejectsSwitchedOffKeys(field: String, reason: XAIError.KeyDisabledReason) async {
        await #expect(throws: XAIError.keyDisabled(reason)) {
            try await validate([
                "/v1/api-key": .json(200, #"{"\#(field)":true}"#), "/v1/realtime/client_secrets": Self.mintOK,
            ])
        }
    }

    @Test func fallsBackToTheModelsEndpoint() async throws {
        let (status, transport) = try await validate([
            "/v1/models": .json(200, #"{"data":[]}"#), "/v1/realtime/client_secrets": Self.mintOK,
        ])
        #expect(status == XAIKeyStatus(name: nil, realtimeVerified: true))
        #expect(
            transport.requests.map { $0.url?.path } == ["/v1/api-key", "/v1/models", "/v1/realtime/client_secrets"])
    }

    @Test func rejectsAnUnfundedKey() async {
        let body = #"{"error":"Your newly created team doesn't have any credits yet."}"#
        await #expect(
            throws: XAIError.insufficientCredits(message: "Your newly created team doesn't have any credits yet.")
        ) {
            try await validate(["/v1/api-key": .json(200, "{}"), "/v1/realtime/client_secrets": .json(403, body)])
        }
    }

    @Test func rejectsAKeyWithoutRealtimeAccess() async {
        await #expect(throws: XAIError.permissionDenied(message: "forbidden endpoint")) {
            try await validate([
                "/v1/api-key": .json(200, "{}"),
                "/v1/realtime/client_secrets": .json(403, #"{"error":"forbidden endpoint"}"#),
            ])
        }
    }

    @Test func passesOnRetryableFailures() async {
        await #expect(throws: XAIError.network(code: URLError.notConnectedToInternet.rawValue)) {
            let transport = ScriptedTransport { _ in .failure(.notConnectedToInternet) }
            _ = try await XAIKeyValidator(client: .test(transport: transport)).validate(TestKeys.primary)
        }
    }

    @Test func anInconclusiveMintStillAcceptsTheKey() async throws {
        let (status, _) = try await validate([
            "/v1/api-key": .json(200, "{}"), "/v1/realtime/client_secrets": .json(422, #"{"error":"unknown field"}"#),
        ])
        #expect(status == XAIKeyStatus(name: nil, realtimeVerified: false))
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    let policy = RetryPolicy(maximumAttempts: 5, initialDelay: .seconds(1), multiplier: 2, maximumDelay: .seconds(8))

    @Test func backsOffExponentiallyUpToTheCap() {
        let delays = (0..<6).map { policy.delay(beforeRetry: $0, unitRandom: 0.5) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)])
        #expect(policy.delay(beforeRetry: 10_000, unitRandom: 0) == .seconds(8))
    }

    @Test func jitterSpreadsTheDelay() {
        var jittered = policy
        jittered.jitter = 0.25
        #expect(jittered.delay(beforeRetry: 1, unitRandom: 0) == .seconds(1.5))
        #expect(jittered.delay(beforeRetry: 1, unitRandom: 0.5) == .seconds(2))
        #expect(jittered.delay(beforeRetry: 1, unitRandom: 1) == .seconds(2.5))
    }

    @Test func honoursALongerRetryAfterWithinTheCap() {
        #expect(policy.delay(beforeRetry: 0, retryAfter: .seconds(5), unitRandom: 0) == .seconds(5))
        #expect(policy.delay(beforeRetry: 2, retryAfter: .seconds(1), unitRandom: 0) == .seconds(4))
        #expect(policy.delay(beforeRetry: 0, retryAfter: .seconds(60), unitRandom: 0) == .seconds(8))
    }

    @Test func tokenMintingDefaults() {
        #expect(RetryPolicy.tokenMinting.maximumAttempts == 4)
        #expect(RetryPolicy.noRetries.maximumAttempts == 1)
    }
}
