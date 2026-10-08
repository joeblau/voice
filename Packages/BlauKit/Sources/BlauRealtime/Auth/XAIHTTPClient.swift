import BlauCore
import Foundation

/// Sends one HTTP request. The seam that keeps every xAI REST test hermetic:
/// production uses ``URLSessionHTTPTransport``, tests a scripted fake.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns the body and response, whatever the status
    /// code. Throws only when no response arrived (`URLError`) or the task was
    /// cancelled.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport.
public struct URLSessionHTTPTransport: HTTPTransport {
    /// Shared transport on an ephemeral session: no cookies, no credential
    /// storage and no on-disk cache, so neither the key nor minted client
    /// secrets are ever written to disk by the URL loading system.
    public static let shared = URLSessionHTTPTransport(session: makeSession())

    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// REST client for `https://api.x.ai` that authenticates with the user's
/// key from the ``APIKeyStore``.
///
/// Used for token minting (``XAIClientSecretMinter``), key validation
/// (``XAIKeyValidator``) and, later, the REST features that don't need the
/// realtime socket (topic-label fallback, fact extraction). BlauTopics and
/// BlauMemory sit beside BlauRealtime in the layer graph, so they reach this
/// client through protocols of their own that the app's composition root
/// fulfils (docs/architecture.md, rule 2).
///
/// The key goes only into the `Authorization` header of requests to
/// ``baseURL``; it is never logged.
public struct XAIHTTPClient: Sendable {
    /// One request, relative to ``XAIHTTPClient/baseURL``.
    public struct Request: Sendable, Equatable {
        public var method: String
        public var path: String
        public var body: Data?
        public var timeout: Duration
        /// The `Accept` header: JSON for the REST API, an audio type for
        /// text to speech (`/v1/tts`), which answers with raw audio bytes.
        public var accept: String

        public init(
            method: String, path: String, body: Data? = nil, timeout: Duration = .seconds(20),
            accept: String = "application/json"
        ) {
            self.method = method
            self.path = path
            self.body = body
            self.timeout = timeout
            self.accept = accept
        }

        public static func get(_ path: String) -> Request {
            Request(method: "GET", path: path)
        }

        public static func post(_ path: String, json: some Encodable) throws(XAIError) -> Request {
            do {
                return Request(method: "POST", path: path, body: try XAIHTTPClient.encoder.encode(json))
            } catch {
                throw .invalidResponse("Could not encode the request body: \(error)")
            }
        }
    }

    /// `https://api.x.ai` (from `AppConfig.xaiAPIBaseURL`).
    public let baseURL: URL
    private let keyStore: any APIKeyStore
    private let transport: any HTTPTransport

    public init(baseURL: URL, keyStore: any APIKeyStore, transport: any HTTPTransport = URLSessionHTTPTransport.shared)
    {
        self.baseURL = baseURL
        self.keyStore = keyStore
        self.transport = transport
    }

    /// Whether a key is stored. `false` when the store can't be read either
    /// (for example before the first unlock).
    public func hasAPIKey() async -> Bool {
        ((try? await keyStore.load()) ?? nil) != nil
    }

    /// Sends `request` with the stored key.
    ///
    /// - Throws: ``XAIError/missingAPIKey`` when no key is stored, or the
    ///   classified failure.
    public func send(_ request: Request) async throws(XAIError) -> Data {
        let key: XAIAPIKey?
        do {
            key = try await keyStore.load()
        } catch {
            throw .keyStore(error)
        }
        guard let key else { throw .missingAPIKey }
        return try await send(request, apiKey: key)
    }

    /// Sends `request` with an explicit key, e.g. one the user just typed and
    /// that isn't stored yet.
    public func send(_ request: Request, apiKey: XAIAPIKey) async throws(XAIError) -> Data {
        let urlRequest = makeURLRequest(request, apiKey: apiKey)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch let error as URLError {
            throw .network(code: error.code.rawValue)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(code: URLError.unknown.rawValue)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw XAIError.classify(status: response.statusCode, body: data, headers: response.allHeaderFields)
        }
        return data
    }

    /// Sends `request` and decodes a JSON response.
    public func send<Response: Decodable>(
        _ request: Request, apiKey: XAIAPIKey? = nil, decoding type: Response.Type
    ) async throws(XAIError) -> Response {
        let body: Data
        if let apiKey {
            body = try await send(request, apiKey: apiKey)
        } else {
            body = try await send(request)
        }
        do {
            return try Self.decoder.decode(Response.self, from: body)
        } catch {
            throw .invalidResponse("Unexpected \(Response.self) payload: \(error)")
        }
    }

    func makeURLRequest(_ request: Request, apiKey: XAIAPIKey) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: request.path))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout.timeInterval
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("Bearer \(apiKey.rawValue)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
