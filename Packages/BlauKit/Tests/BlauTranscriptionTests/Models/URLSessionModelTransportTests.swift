import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// Answers requests in-process. Each test registers its own host so tests
/// can run in parallel.
private final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Fail with this after sending the body.
        var error: URLError?
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    private static let handlers = Mutex<[String: Handler]>([:])

    static func register(host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { _ = $0.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            // Two chunks, so progress is reported more than once.
            let middle = response.body.count / 2
            client?.urlProtocol(self, didLoad: response.body.prefix(middle))
            client?.urlProtocol(self, didLoad: response.body.dropFirst(middle))
        }
        if let error = response.error {
            // Like a real connection, fail a moment after the bytes, so the
            // session delivers what it already received.
            Thread.sleep(forTimeInterval: 0.1)
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class RangeLog: Sendable {
    let values = Mutex<[String?]>([])
}

@Suite("URLSession model transport")
struct URLSessionModelTransportTests {
    let host = "models-\(UUID().uuidString.lowercased()).test"
    let body = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    var transport: URLSessionModelTransport {
        URLSessionModelTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return configuration
        }
    }

    var url: URL { URL(string: "https://\(host)/o/r/resolve/abc/weights/weight.bin")! }

    /// Serves `body`, honoring `Range` like Hugging Face's CDN.
    func serveWithRanges(record: (@Sendable (String?) -> Void)? = nil) {
        let body = body
        StubURLProtocol.register(host: host) { request in
            let range = request.value(forHTTPHeaderField: "Range")
            record?(range)
            guard let range, let start = Int(range.dropFirst("bytes=".count).dropLast()) else {
                return .init(status: 200, body: body)
            }
            return .init(
                status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                body: body.dropFirst(start))
        }
    }

    @Test func downloadsTheWholeFile() async throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "dir/weight.bin.partial")
        serveWithRanges()
        defer { StubURLProtocol.unregister(host: host) }
        let progress = Mutex<[Int64]>([])

        try await transport.fetch(url, into: file, resumingAt: 0, allowsExpensiveNetwork: false) { bytes in
            progress.withLock { $0.append(bytes) }
        }

        #expect(try Data(contentsOf: file) == body)
        #expect(progress.withLock { $0.last } == Int64(body.count))
    }

    @Test func resumesWithARangeRequest() async throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "weight.bin.partial")
        try body.prefix(4000).write(to: file)
        let requests = RangeLog()
        serveWithRanges { range in requests.values.withLock { $0.append(range) } }
        defer { StubURLProtocol.unregister(host: host) }

        try await transport.fetch(url, into: file, resumingAt: 4000, allowsExpensiveNetwork: false) { _ in }

        #expect(requests.values.withLock { $0 } == ["bytes=4000-"])
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func aFullResponseToARangeRequestRewritesTheFile() async throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "weight.bin.partial")
        try Data(repeating: 0xEE, count: 4000).write(to: file)
        let body = body
        StubURLProtocol.register(host: host) { _ in .init(status: 200, body: body) }
        defer { StubURLProtocol.unregister(host: host) }

        try await transport.fetch(url, into: file, resumingAt: 4000, allowsExpensiveNetwork: false) { _ in }

        #expect(try Data(contentsOf: file) == body)
    }

    @Test func aRangeThatDoesNotStartAtTheOffsetIsRejected() async throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "weight.bin.partial")
        try body.prefix(4000).write(to: file)
        let body = body
        StubURLProtocol.register(host: host) { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 0-9999/10000"], body: body)
        }
        defer { StubURLProtocol.unregister(host: host) }

        await #expect(throws: ModelTransportError.interrupted("Unexpected Content-Range")) {
            try await transport.fetch(url, into: file, resumingAt: 4000, allowsExpensiveNetwork: false) { _ in }
        }
        // The bytes already on disk are untouched.
        #expect(try Data(contentsOf: file) == body.prefix(4000))
    }

    @Test func httpErrorsCarryTheStatus() async throws {
        let temp = try TemporaryDirectory()
        StubURLProtocol.register(host: host) { _ in .init(status: 404, body: Data("Not found".utf8)) }
        defer { StubURLProtocol.unregister(host: host) }

        await #expect(throws: ModelTransportError.httpStatus(404)) {
            try await transport.fetch(
                url, into: temp.url.appending(path: "f.partial"), resumingAt: 0, allowsExpensiveNetwork: false
            ) { _ in }
        }
    }

    @Test func aDroppedConnectionKeepsTheBytesReceived() async throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "f.partial")
        let body = body
        StubURLProtocol.register(host: host) { _ in
            .init(status: 200, body: body.prefix(6000), error: URLError(.networkConnectionLost))
        }
        defer { StubURLProtocol.unregister(host: host) }

        await #expect(throws: ModelTransportError.self) {
            try await transport.fetch(url, into: file, resumingAt: 0, allowsExpensiveNetwork: false) { _ in }
        }
        #expect(try Data(contentsOf: file) == body.prefix(6000))
    }

    @Test func offlineIsReportedAsOffline() async throws {
        let temp = try TemporaryDirectory()
        StubURLProtocol.register(host: host) { _ in .init(status: 200, error: URLError(.notConnectedToInternet)) }
        defer { StubURLProtocol.unregister(host: host) }

        await #expect(throws: ModelTransportError.offline) {
            try await transport.fetch(
                url, into: temp.url.appending(path: "f.partial"), resumingAt: 0, allowsExpensiveNetwork: false
            ) { _ in }
        }
    }

    @Test func cancellingTheTaskCancelsTheTransfer() async throws {
        let temp = try TemporaryDirectory()
        serveWithRanges()
        defer { StubURLProtocol.unregister(host: host) }
        let transport = transport
        let url = url

        let task = Task {
            try await transport.fetch(
                url, into: temp.url.appending(path: "f.partial"), resumingAt: 0, allowsExpensiveNetwork: false
            ) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func classifiesURLErrors() {
        func classify(_ code: URLError.Code) -> ModelTransportError? {
            URLSessionModelTransport.classify(URLError(code)) as? ModelTransportError
        }
        #expect(classify(.notConnectedToInternet) == .offline)
        #expect(classify(.dataNotAllowed) == .offline)
        #expect(classify(.timedOut) == .interrupted("URLError \(URLError.Code.timedOut.rawValue)"))
        #expect(
            classify(.networkConnectionLost) == .interrupted("URLError \(URLError.Code.networkConnectionLost.rawValue)")
        )
        #expect(URLSessionModelTransport.classify(URLError(.cancelled)) is CancellationError)
    }

    @Test func transientStatusesAreRetryable() {
        #expect(ModelTransportError.httpStatus(503).isTransient)
        #expect(ModelTransportError.httpStatus(429).isTransient)
        #expect(ModelTransportError.httpStatus(500).isTransient)
        #expect(!ModelTransportError.httpStatus(404).isTransient)
        #expect(!ModelTransportError.httpStatus(403).isTransient)
        #expect(ModelTransportError.interrupted("x").isTransient)
        #expect(!ModelTransportError.offline.isTransient)
    }

    @Test func parsesContentRange() {
        #expect(URLSessionModelTransport.contentRangeStart("bytes 4000-9999/10000") == 4000)
        #expect(URLSessionModelTransport.contentRangeStart("bytes 0-0/*") == 0)
        #expect(URLSessionModelTransport.contentRangeStart("items 1-2/3") == nil)
        #expect(URLSessionModelTransport.contentRangeStart(nil) == nil)
    }
}
