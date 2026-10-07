import BlauCore
import BlauTelemetry
import Foundation
import os

/// How hard to try before giving up on a file.
public struct ModelRetryPolicy: Hashable, Sendable {
    /// Consecutive failed attempts per file that made no progress. An
    /// attempt that received bytes resets the count, so a long download on
    /// a flaky network keeps going as long as it advances.
    public var maxAttempts: Int
    /// Delay before the first retry; doubles each time.
    public var initialDelay: Duration
    /// Upper bound on the delay.
    public var maxDelay: Duration

    public init(maxAttempts: Int = 5, initialDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30)) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// Exponential backoff: `initialDelay * 2^(attempt - 1)`, capped.
    public func delay(afterAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 30)
        return min(initialDelay * (1 << exponent), maxDelay)
    }

    public static let `default` = ModelRetryPolicy()
}

/// Why a model couldn't be downloaded.
public enum ModelDownloadError: Error, Hashable, Sendable {
    /// No connection. Downloading resumes when one appears.
    case offline
    /// Only cellular or Low Data Mode is available and the policy is
    /// Wi-Fi only.
    case requiresUnmeteredNetwork
    /// Not enough free space. `required` is what is still to download.
    case insufficientStorage(required: Int64, available: Int64)
    /// A file kept failing its SHA-256 check.
    case checksumMismatch(path: String)
    /// The server refused the file (for example 404 for a revision that
    /// was removed).
    case server(status: Int, path: String)
    /// Retries ran out on a dropped or failing connection.
    case transferFailed(path: String, reason: String)
    /// Writing to disk failed.
    case storage(String)
}

/// Downloads every file of one model into its staging directory, resuming
/// partial files, retrying transient failures and verifying each file's
/// size and SHA-256 before accepting it.
struct ModelDownloader: Sendable {
    let transport: any ModelTransport
    let clock: any BlauClock
    let retryPolicy: ModelRetryPolicy
    let host: URL

    /// Free space kept in reserve beyond the download itself.
    static let storageHeadroom: Int64 = 50 * 1024 * 1024

    /// Downloads whatever of `descriptor` isn't in staging yet.
    ///
    /// Files already in staging under their final name were verified when
    /// they were renamed there, so a resumed download skips them. A
    /// `.partial` file resumes from its length.
    ///
    /// - Parameter progress: Bytes of the model on disk so far, out of
    ///   `descriptor.totalBytes`. Called from any thread.
    @concurrent
    func download(
        _ descriptor: ModelDescriptor,
        store: ModelStore,
        allowsExpensiveNetwork: Bool,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let staging = store.stagingDirectory(for: descriptor)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try? ModelStore.excludeFromBackup(store.stagingRoot)
        } catch {
            throw ModelDownloadError.storage(error.localizedDescription)
        }

        var completed: Int64 = 0
        var pending: [ModelFile] = []
        for file in descriptor.files {
            if ModelStore.size(of: staging.appending(path: file.path)) == file.size {
                completed += file.size
            } else {
                pending.append(file)
            }
        }
        progress(completed)

        let partialBytes = pending.reduce(Int64(0)) { total, file in
            total + (ModelStore.size(of: Self.partialURL(for: file, in: staging)) ?? 0)
        }
        let remaining = descriptor.totalBytes - completed - partialBytes
        if let available = store.freeSpace(), available < remaining + Self.storageHeadroom {
            throw ModelDownloadError.insufficientStorage(required: remaining, available: available)
        }

        for file in pending {
            try Task.checkCancellation()
            let base = completed
            try await download(
                file, of: descriptor, into: staging, allowsExpensiveNetwork: allowsExpensiveNetwork
            ) { fileBytes in
                progress(base + fileBytes)
            }
            completed += file.size
            progress(completed)
        }
    }

    static func partialURL(for file: ModelFile, in staging: URL) -> URL {
        staging.appending(path: file.path).appendingPathExtension(ModelStore.partialExtension)
    }

    /// One file: fetch into `<path>.partial` (resuming), verify, rename.
    private func download(
        _ file: ModelFile,
        of descriptor: ModelDescriptor,
        into staging: URL,
        allowsExpensiveNetwork: Bool,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let destination = staging.appending(path: file.path)
        let partial = Self.partialURL(for: file, in: staging)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ModelDownloadError.storage(error.localizedDescription)
        }

        var failedAttempts = 0
        var checksumFailures = 0
        while true {
            try Task.checkCancellation()
            var offset = ModelStore.size(of: partial) ?? 0
            if offset > file.size {
                try? fileManager.removeItem(at: partial)
                offset = 0
            }

            let failure: ModelDownloadError
            do {
                if offset < file.size || file.size == 0 {
                    try await fetch(
                        file, of: descriptor, to: partial, offset: offset,
                        allowsExpensiveNetwork: allowsExpensiveNetwork, progress: progress)
                }
                try verify(file, at: partial)
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: partial, to: destination)
                return
            } catch let error as VerificationFailure {
                try? fileManager.removeItem(at: partial)
                checksumFailures += 1
                Log.asr.error(
                    "Model file failed verification (\(error.reason, privacy: .public)): \(descriptor.id.rawValue, privacy: .public)/\(file.path, privacy: .public)"
                )
                // A fresh download that fails twice isn't a network blip.
                guard checksumFailures < 2 else { throw ModelDownloadError.checksumMismatch(path: file.path) }
                failure = .checksumMismatch(path: file.path)
            } catch let error as ModelTransportError {
                switch error {
                case .offline: throw ModelDownloadError.offline
                case .expensiveNetworkDisallowed: throw ModelDownloadError.requiresUnmeteredNetwork
                case .writeFailed(let reason): throw ModelDownloadError.storage(reason)
                case .httpStatus(let status) where !error.isTransient:
                    // 416: our partial file doesn't fit the resource; start over.
                    if status == 416, offset > 0 {
                        try? fileManager.removeItem(at: partial)
                        failure = .server(status: status, path: file.path)
                    } else {
                        throw ModelDownloadError.server(status: status, path: file.path)
                    }
                case .httpStatus(let status):
                    failure = .server(status: status, path: file.path)
                case .interrupted(let reason):
                    failure = .transferFailed(path: file.path, reason: reason)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ModelDownloadError {
                throw error
            } catch {
                throw ModelDownloadError.storage(error.localizedDescription)
            }

            let madeProgress = (ModelStore.size(of: partial) ?? 0) > offset
            failedAttempts = madeProgress ? 1 : failedAttempts + 1
            guard failedAttempts < retryPolicy.maxAttempts else { throw failure }
            let delay = retryPolicy.delay(afterAttempt: failedAttempts)
            Log.asr.notice(
                "Retrying \(descriptor.id.rawValue, privacy: .public)/\(file.path, privacy: .public) in \(delay.components.seconds, privacy: .public)s (attempt \(failedAttempts + 1, privacy: .public))"
            )
            try await clock.sleep(for: delay)
        }
    }

    private func fetch(
        _ file: ModelFile,
        of descriptor: ModelDescriptor,
        to partial: URL,
        offset: Int64,
        allowsExpensiveNetwork: Bool,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard file.size > 0 else {
            // Hugging Face answers empty files with an error; there is
            // nothing to fetch.
            guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: Data()) else {
                throw ModelTransportError.writeFailed("Couldn't create \(file.path)")
            }
            return
        }
        try await transport.fetch(
            descriptor.remoteURL(for: file, host: host),
            into: partial,
            resumingAt: offset,
            allowsExpensiveNetwork: allowsExpensiveNetwork,
            onProgress: progress
        )
    }

    private struct VerificationFailure: Error {
        let reason: String
    }

    private func verify(_ file: ModelFile, at url: URL) throws {
        let size = ModelStore.size(of: url) ?? -1
        guard size == file.size else {
            // Short: the body ended early. Long: never valid.
            if size < file.size { throw ModelTransportError.interrupted("Body ended at \(size) of \(file.size) bytes") }
            throw VerificationFailure(reason: "size \(size), expected \(file.size)")
        }
        let digest: String
        do {
            digest = try ModelStore.sha256(of: url)
        } catch {
            throw ModelDownloadError.storage(error.localizedDescription)
        }
        guard digest == file.sha256 else { throw VerificationFailure(reason: "SHA-256 mismatch") }
    }
}
