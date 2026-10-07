#if DEBUG
    import BlauRealtime
    import Foundation

    /// Hermetic xAI responses for UI tests, selected with the
    /// `BLAU_UI_TEST_XAI` launch environment variable. With a stub active the
    /// app also uses an in-memory key store, so UI tests never touch the
    /// Keychain or the network. Compiled into DEBUG builds only.
    enum XAIUITestStub: String {
        /// Every key is accepted.
        case accept
        /// Every key is rejected as invalid (HTTP 400, like xAI).
        case reject
        /// The key is valid but its team has no credits.
        case unfunded
        /// No network connection.
        case offline

        static let environmentKey = "BLAU_UI_TEST_XAI"

        static var current: XAIUITestStub? {
            ProcessInfo.processInfo.environment[environmentKey].flatMap(XAIUITestStub.init(rawValue:))
        }

        var transport: any HTTPTransport { Transport(stub: self) }

        private struct Transport: HTTPTransport {
            let stub: XAIUITestStub

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let path = request.url?.path ?? ""
                let (status, body): (Int, String)
                switch (stub, path) {
                case (.offline, _):
                    throw URLError(.notConnectedToInternet)
                case (.reject, _):
                    (status, body) = (
                        400, #"{"code":"Client specified an invalid argument","error":"Incorrect API key provided"}"#
                    )
                case (.unfunded, "/v1/realtime/client_secrets"):
                    (status, body) = (403, #"{"error":"Your newly created team doesn't have any credits yet."}"#)
                case (_, "/v1/api-key"):
                    (status, body) = (200, #"{"name":"UI test key","api_key_blocked":false,"team_blocked":false}"#)
                case (_, "/v1/realtime/client_secrets"):
                    let expiry = Int(Date().timeIntervalSince1970) + 600
                    (status, body) = (200, #"{"value":"ui-test-secret","expires_at":\#(expiry)}"#)
                default:
                    (status, body) = (404, #"{"error":"not stubbed"}"#)
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (Data(body.utf8), response)
            }
        }
    }
#endif
