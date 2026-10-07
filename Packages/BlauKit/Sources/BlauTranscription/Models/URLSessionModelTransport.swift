import Foundation
import Synchronization

/// Downloads model files with `URLSession`, streaming the body straight to
/// disk so received bytes survive a dropped connection or a killed app.
///
/// - Resume: a non-zero offset sends `Range: bytes=<offset>-`. A `206` whose
///   `Content-Range` starts at the offset is appended; a `200` rewrites the
///   file from the start.
/// - Network policy: `allowsExpensiveNetwork == false` turns off
///   `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess`, so
///   the system itself refuses cellular, hotspot and Low Data Mode paths.
/// - No caching: model files are hundreds of megabytes and are kept in the
///   model store, never in `URLCache`.
public struct URLSessionModelTransport: ModelTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter configuration: Builds the base session configuration for
    ///   each transfer. Tests pass one with a stub `URLProtocol`.
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .default }) {
        self.makeConfiguration = configuration
    }

    public func fetch(
        _ url: URL,
        into file: URL,
        resumingAt offset: Int64,
        allowsExpensiveNetwork: Bool,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let configuration = makeConfiguration()
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Idle timeout: resets whenever bytes arrive.
        configuration.timeoutIntervalForRequest = 60

        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let delegate = TransferDelegate(file: file, offset: offset, onProgress: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    /// Maps a `URLError` to the transport's error classes.
    static func classify(_ error: URLError) -> any Error {
        if error.networkUnavailableReason == .expensive || error.networkUnavailableReason == .constrained {
            return ModelTransportError.expensiveNetworkDisallowed
        }
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return ModelTransportError.offline
        default:
            return ModelTransportError.interrupted("URLError \(error.code.rawValue)")
        }
    }

    /// Parses the first byte position of `Content-Range: bytes <first>-<last>/<length>`.
    static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let range = header.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[..<dash].trimmingCharacters(in: .whitespaces))
    }
}

/// Receives one transfer's callbacks and writes the body to disk.
///
/// `URLSession` calls the delegate on its own serial queue; `cancel()` and
/// `start` come from the awaiting task. All mutable state is behind the
/// mutex.
private final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Void, any Error>?
        var handle: FileHandle?
        var length: Int64 = 0
        var failure: (any Error)?
        var isCancelled = false
    }

    private let file: URL
    private let offset: Int64
    private let onProgress: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    init(file: URL, offset: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.offset = offset
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
        let cancelled = state.withLock { state in
            state.task = task
            state.continuation = continuation
            return state.isCancelled
        }
        if cancelled {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse else {
                throw ModelTransportError.interrupted("Not an HTTP response")
            }
            let handle: FileHandle
            let length: Int64
            switch http.statusCode {
            case 206
            where URLSessionModelTransport.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range"))
                == offset:
                handle = try openFile()
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                length = offset
            case 200:
                handle = try openFile()
                try handle.truncate(atOffset: 0)
                length = 0
            case 206:
                // A range we didn't ask for: never splice it in.
                throw ModelTransportError.interrupted("Unexpected Content-Range")
            default:
                throw ModelTransportError.httpStatus(http.statusCode)
            }
            state.withLock { state in
                state.handle = handle
                state.length = length
            }
            onProgress(length)
            completionHandler(.allow)
        } catch {
            let failure = (error as? ModelTransportError) ?? .writeFailed(error.localizedDescription)
            state.withLock { $0.failure = failure }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result: Result<Int64, any Error> = state.withLock { state in
            guard let handle = state.handle else {
                return .failure(ModelTransportError.interrupted("Body before response"))
            }
            do {
                try handle.write(contentsOf: data)
                state.length += Int64(data.count)
                return .success(state.length)
            } catch {
                return .failure(ModelTransportError.writeFailed(error.localizedDescription))
            }
        }
        switch result {
        case .success(let length):
            onProgress(length)
        case .failure(let error):
            state.withLock { $0.failure = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure, isCancelled) = state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.failure, state.isCancelled)
        }
        guard let continuation else { return }
        if isCancelled {
            continuation.resume(throwing: CancellationError())
        } else if let failure {
            continuation.resume(throwing: failure)
        } else if let error = error as? URLError {
            continuation.resume(throwing: URLSessionModelTransport.classify(error))
        } else if let error {
            continuation.resume(throwing: ModelTransportError.interrupted(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    private func openFile() throws -> FileHandle {
        let path = file.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw ModelTransportError.writeFailed("Couldn't create \(file.lastPathComponent)")
            }
        }
        return try FileHandle(forWritingTo: file)
    }
}
