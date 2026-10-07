import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// A fresh, empty directory under the system temp directory, deleted when
/// the value goes out of scope.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "blau-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// One step a `ScriptedTransport` takes for a request.
enum TransportStep: Sendable {
    /// Serve the requested range in full.
    case serve
    /// Serve `bytes` bytes of the requested range, then fail as if the
    /// connection dropped.
    case drop(afterBytes: Int64)
    /// Ignore the `Range` request and serve the whole file (a `200`).
    case ignoreRange
    /// Serve bytes that don't match the checksum.
    case corrupt
    /// Throw without writing anything.
    case fail(ModelTransportError)
    /// Serve `bytes` bytes, then wait for `gate` to open before the rest.
    case pause(afterBytes: Int64, gate: Gate)
}

/// A recorded request.
struct TransportCall: Hashable, Sendable {
    let path: String
    let offset: Int64
    let allowsExpensiveNetwork: Bool
}

/// Serves fixture model files from memory and follows a per-file script of
/// failures. Files without a script (or once it runs out) are served
/// normally.
final class ScriptedTransport: ModelTransport {
    private struct State {
        var scripts: [String: [TransportStep]] = [:]
        var calls: [TransportCall] = []
        var defaultStep: TransportStep = .serve
    }

    private let files: [URL: (path: String, data: Data)]
    private let state = Mutex(State())

    init(manifest: ModelManifest, host: URL = ModelDescriptor.defaultHost) {
        var files: [URL: (String, Data)] = [:]
        for descriptor in manifest.models {
            for file in descriptor.files {
                files[descriptor.remoteURL(for: file, host: host)] = (
                    "\(descriptor.id.rawValue)/\(file.path)", ModelFixtures.contents(of: file, in: descriptor)
                )
            }
        }
        self.files = files
    }

    /// Steps for `path` (`<model id>/<file path>`), consumed one per request.
    func script(_ path: String, _ steps: TransportStep...) {
        state.withLock { $0.scripts[path, default: []] += steps }
    }

    /// The step for every request without a script.
    func setDefault(_ step: TransportStep) {
        state.withLock { $0.defaultStep = step }
    }

    var calls: [TransportCall] { state.withLock { $0.calls } }

    func fetch(
        _ url: URL,
        into file: URL,
        resumingAt offset: Int64,
        allowsExpensiveNetwork: Bool,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let (path, data) = files[url] else { throw ModelTransportError.httpStatus(404) }
        let step = state.withLock { state -> TransportStep in
            state.calls.append(
                TransportCall(path: path, offset: offset, allowsExpensiveNetwork: allowsExpensiveNetwork))
            guard var steps = state.scripts[path], !steps.isEmpty else { return state.defaultStep }
            let step = steps.removeFirst()
            state.scripts[path] = steps
            return step
        }

        switch step {
        case .fail(let error):
            throw error
        case .serve:
            try write(data, from: offset, count: nil, to: file, onProgress: onProgress)
        case .ignoreRange:
            try write(data, from: 0, count: nil, to: file, onProgress: onProgress)
        case .corrupt:
            var damaged = data
            if !damaged.isEmpty { damaged[damaged.startIndex] ^= 0xFF }
            try write(damaged, from: offset, count: nil, to: file, onProgress: onProgress)
        case .drop(let bytes):
            try write(data, from: offset, count: bytes, to: file, onProgress: onProgress)
            throw ModelTransportError.interrupted("scripted drop")
        case .pause(let bytes, let gate):
            try write(data, from: offset, count: bytes, to: file, onProgress: onProgress)
            await gate.wait()
            try Task.checkCancellation()
            try write(data, from: offset + bytes, count: nil, to: file, onProgress: onProgress)
        }
    }

    private func write(
        _ data: Data, from offset: Int64, count: Int64?, to file: URL, onProgress: @Sendable (Int64) -> Void
    ) throws {
        let start = Int(min(offset, Int64(data.count)))
        let end = count.map { min(data.count, start + Int($0)) } ?? data.count
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(start))
        try handle.seek(toOffset: UInt64(start))
        try handle.write(contentsOf: data[start..<end])
        onProgress(Int64(end))
    }
}

/// Opens once; everyone waiting (before or after) continues. A waiting
/// task that is cancelled stops waiting.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    func wait() async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.isOpen || state.cancelled.contains(id) { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled.insert(id)
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume()
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Counts warm-ups and can fail them.
final class RecordingWarmer: ModelWarmer {
    private let state = Mutex<(warmed: [ModelID], failing: Set<ModelID>)>(([], []))

    var warmed: [ModelID] { state.withLock { $0.warmed } }

    func fail(_ id: ModelID) { state.withLock { _ = $0.failing.insert(id) } }

    func warmUp(_ descriptor: ModelDescriptor, at directory: URL) async throws {
        let failing = state.withLock { state in
            state.warmed.append(descriptor.id)
            return state.failing.contains(descriptor.id)
        }
        // A warm-up reads the model from disk, so it must be there.
        for bundle in descriptor.bundles {
            #expect(
                FileManager.default.fileExists(atPath: directory.appending(path: bundle).path(percentEncoded: false)))
        }
        if failing { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// Polls `condition` on the main actor until it holds, failing the test
/// after `timeout`.
@MainActor
func waitUntil(
    _ description: Comment,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting: \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// A retry policy that never waits, for tests that don't care about
/// backoff.
extension ModelRetryPolicy {
    static let immediate = ModelRetryPolicy(maxAttempts: 3, initialDelay: .zero, maxDelay: .zero)
}
