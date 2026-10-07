import BlauCore
import CryptoKit
import Foundation

/// Tiny synthetic models with real checksums, served from memory.
///
/// For SwiftUI previews, UI tests and unit tests: a ``ModelManager`` built
/// with ``manifest(bytesPerFile:)``, a ``Transport`` and a ``Warmer`` runs
/// the full download, verify, install and warm-up path without the network
/// or Core ML. The app switches to these when launched with
/// `BLAU_MODEL_FIXTURES=1`.
public enum ModelFixtures {
    /// A manifest with every ``ModelID``, three files each, whose contents
    /// come from ``contents(of:)``.
    public static func manifest(bytesPerFile: Int = 64 * 1024) -> ModelManifest {
        ModelManifest(
            models: ModelID.allCases.map { id in
                let bundle = "\(id.rawValue).mlmodelc"
                let files = [
                    ("\(bundle)/coremldata.bin", max(1, bytesPerFile / 64)),
                    ("\(bundle)/weights/weight.bin", bytesPerFile),
                    ("vocab.json", max(1, bytesPerFile / 16)),
                ]
                return ModelDescriptor(
                    id: id,
                    repository: "blau-fixtures/\(id.rawValue)",
                    revision: "0000000000000000000000000000000000000001",
                    remoteDirectory: "",
                    files: files.map { path, size in
                        let data = contents(path: "\(id.rawValue)/\(path)", size: size)
                        return ModelFile(path: path, size: Int64(size), sha256: sha256(data))
                    }
                )
            })
    }

    /// The bytes of `file` in `descriptor`: deterministic, so the
    /// checksums in ``manifest(bytesPerFile:)`` match.
    public static func contents(of file: ModelFile, in descriptor: ModelDescriptor) -> Data {
        contents(path: "\(descriptor.id.rawValue)/\(file.path)", size: Int(file.size))
    }

    static func contents(path: String, size: Int) -> Data {
        var seed = path.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                buffer[index] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Serves a manifest's files from memory, honoring resume offsets, in
    /// `chunkCount` pieces with `delayPerChunk` between them so progress is
    /// visible.
    public struct Transport: ModelTransport {
        private let files: [URL: Data]
        private let chunkCount: Int
        private let delayPerChunk: Duration
        private let clock: any BlauClock

        public init(
            manifest: ModelManifest,
            host: URL = ModelDescriptor.defaultHost,
            chunkCount: Int = 20,
            delayPerChunk: Duration = .zero,
            clock: any BlauClock = SystemClock()
        ) {
            var files: [URL: Data] = [:]
            for descriptor in manifest.models {
                for file in descriptor.files {
                    files[descriptor.remoteURL(for: file, host: host)] = ModelFixtures.contents(
                        of: file, in: descriptor)
                }
            }
            self.files = files
            self.chunkCount = max(1, chunkCount)
            self.delayPerChunk = delayPerChunk
            self.clock = clock
        }

        public func fetch(
            _ url: URL,
            into file: URL,
            resumingAt offset: Int64,
            allowsExpensiveNetwork: Bool,
            onProgress: @escaping @Sendable (Int64) -> Void
        ) async throws {
            guard let data = files[url] else { throw ModelTransportError.httpStatus(404) }
            let start = Int(min(offset, Int64(data.count)))
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(start))
            try handle.seek(toOffset: UInt64(start))

            let chunkSize = max(1, data.count / chunkCount)
            var position = start
            while position < data.count {
                try Task.checkCancellation()
                if delayPerChunk > .zero { try await clock.sleep(for: delayPerChunk) }
                let end = min(data.count, position + chunkSize)
                try handle.write(contentsOf: data[position..<end])
                position = end
                onProgress(Int64(position))
            }
        }
    }

    /// Pretends to load a model, taking `duration`.
    public struct Warmer: ModelWarmer {
        private let duration: Duration
        private let clock: any BlauClock

        public init(duration: Duration = .zero, clock: any BlauClock = SystemClock()) {
            self.duration = duration
            self.clock = clock
        }

        public func warmUp(_ descriptor: ModelDescriptor, at directory: URL) async throws {
            if duration > .zero { try await clock.sleep(for: duration) }
        }
    }
}
