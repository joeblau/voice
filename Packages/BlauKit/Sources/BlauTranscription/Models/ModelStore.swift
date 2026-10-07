import CryptoKit
import Foundation

/// Where models live on disk, and the bookkeeping that says a model is
/// complete.
///
/// Layout under ``root`` (Application Support, excluded from backup):
///
///     <root>/
///       <model id>/<revision>/            installed model, loaded from here
///         .blau-receipt.json              written last; its presence means "complete"
///       .staging/<model id>/<revision>/   in-progress download
///         <file>.partial                  bytes received so far (resumable)
///
/// A model is installed only once every file has been downloaded and its
/// SHA-256 checked, and the whole staging directory has been renamed into
/// place. A crash or a deleted app can't leave a half-written model that
/// looks complete.
///
/// Methods do blocking file I/O; call them off the main actor.
public struct ModelStore: Sendable {
    /// Directory that holds every model.
    public let root: URL

    /// Free space for new downloads, in bytes, or `nil` when unknown.
    /// Injectable so tests can simulate a full disk.
    let availableCapacity: @Sendable (URL) -> Int64?

    public init(root: URL) {
        self.init(root: root, availableCapacity: ModelStore.volumeAvailableCapacity)
    }

    init(root: URL, availableCapacity: @escaping @Sendable (URL) -> Int64?) {
        self.root = root
        self.availableCapacity = availableCapacity
    }

    /// The app's model store: `Application Support/Blau/Models`.
    ///
    /// Application Support is not purged by the system (unlike Caches), so
    /// models survive low-storage conditions; ``prepare()`` excludes it
    /// from iCloud and device backups because the files can always be
    /// downloaded again.
    public static func applicationSupport() throws -> ModelStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ModelStore(root: base.appending(path: "Blau/Models", directoryHint: .isDirectory))
    }

    static let receiptName = ".blau-receipt.json"
    static let partialExtension = "partial"

    // MARK: Layout

    /// Where `descriptor` is installed (whether or not it is there yet).
    public func directory(for descriptor: ModelDescriptor) -> URL {
        modelRoot(for: descriptor.id).appending(path: descriptor.revision, directoryHint: .isDirectory)
    }

    func modelRoot(for id: ModelID) -> URL {
        root.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    var stagingRoot: URL { root.appending(path: ".staging", directoryHint: .isDirectory) }

    func stagingDirectory(for descriptor: ModelDescriptor) -> URL {
        stagingRoot
            .appending(path: descriptor.id.rawValue, directoryHint: .isDirectory)
            .appending(path: descriptor.revision, directoryHint: .isDirectory)
    }

    // MARK: Preparing the store

    /// Creates the store and excludes it from backup.
    ///
    /// - Returns: Whether the root reads back as excluded from backup.
    @discardableResult
    public func prepare() throws -> Bool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.excludeFromBackup(root)
        return Self.isExcludedFromBackup(root)
    }

    /// Sets `isExcludedFromBackup` on `url`. Excluding a directory excludes
    /// everything in it.
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Reads `isExcludedFromBackup` fresh from disk (not from the URL's cache).
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        let fresh = URL(filePath: url.path(percentEncoded: false))
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    /// Deletes everything that isn't a revision in `manifest`: models
    /// dropped from the manifest, older revisions of current models, and
    /// staging for either. Returns the model IDs it removed something for.
    @discardableResult
    public func removeStaleContent(keeping manifest: ModelManifest) -> Set<String> {
        let fileManager = FileManager.default
        var removed: Set<String> = []
        let current = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id.rawValue, $0.revision) })

        for base in [root, stagingRoot] {
            let entries = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                let id = entry.lastPathComponent
                guard let revision = current[id] else {
                    if (try? fileManager.removeItem(at: entry)) != nil { removed.insert(id) }
                    continue
                }
                let revisions = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                for old in revisions where old.lastPathComponent != revision {
                    if (try? fileManager.removeItem(at: old)) != nil { removed.insert(id) }
                }
            }
        }
        return removed
    }

    // MARK: Installed models

    /// The installed copy of `descriptor`, or `nil` if it is missing,
    /// incomplete, or from a different revision.
    ///
    /// This is the cheap check run at every launch: the receipt must match
    /// the manifest file for file, and every file must exist with the
    /// expected size. Checksums were verified when the files were
    /// downloaded; ``corruptFiles(in:)`` re-hashes them.
    public func installation(of descriptor: ModelDescriptor) -> ModelInstallation? {
        let directory = directory(for: descriptor)
        guard let receipt = readReceipt(in: directory), receipt.matches(descriptor) else { return nil }
        for file in descriptor.files where Self.size(of: directory.appending(path: file.path)) != file.size {
            return nil
        }
        return ModelInstallation(
            directory: directory, installedAt: receipt.installedAt, warmedUpOn: receipt.warmedUpOn)
    }

    /// Moves a fully downloaded and verified staging directory into place
    /// and writes its receipt.
    func install(_ descriptor: ModelDescriptor, installedAt: Date) throws -> ModelInstallation {
        let fileManager = FileManager.default
        let staging = stagingDirectory(for: descriptor)
        let receipt = ModelReceipt(descriptor: descriptor, installedAt: installedAt, warmedUpOn: nil)
        try writeReceipt(receipt, in: staging)

        let destination = directory(for: descriptor)
        try fileManager.createDirectory(at: modelRoot(for: descriptor.id), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        // Belt and braces: the root is excluded already, and that covers
        // its contents.
        try? Self.excludeFromBackup(destination)
        return ModelInstallation(directory: destination, installedAt: installedAt, warmedUpOn: nil)
    }

    /// Records that `descriptor` loaded successfully on `systemVersion`, so
    /// later launches on the same OS skip the warm-up.
    func markWarmedUp(_ descriptor: ModelDescriptor, systemVersion: String) throws {
        let directory = directory(for: descriptor)
        guard var receipt = readReceipt(in: directory) else { return }
        receipt.warmedUpOn = systemVersion
        try writeReceipt(receipt, in: directory)
    }

    /// Re-hashes every file of an installed model and returns the paths
    /// whose size or SHA-256 doesn't match the manifest. Slow: reads every
    /// byte.
    public func corruptFiles(in descriptor: ModelDescriptor) -> [String] {
        let directory = directory(for: descriptor)
        return descriptor.files.compactMap { file in
            let url = directory.appending(path: file.path)
            guard Self.size(of: url) == file.size, (try? Self.sha256(of: url)) == file.sha256 else { return file.path }
            return nil
        }
    }

    /// Deletes every installed revision and any partial download of `id`.
    public func remove(_ id: ModelID) throws {
        let fileManager = FileManager.default
        for url in [modelRoot(for: id), stagingRoot.appending(path: id.rawValue, directoryHint: .isDirectory)]
        where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: Disk usage

    /// Bytes `id` occupies on disk, installed and partial downloads
    /// included.
    public func diskUsage(of id: ModelID) -> Int64 {
        Self.allocatedSize(of: modelRoot(for: id))
            + Self.allocatedSize(of: stagingRoot.appending(path: id.rawValue, directoryHint: .isDirectory))
    }

    /// Free space on the store's volume for new downloads.
    func freeSpace() -> Int64? {
        availableCapacity(root)
    }

    static func volumeAvailableCapacity(_ url: URL) -> Int64? {
        // Ask about an existing ancestor: resource values of a missing path fail.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)), probe.pathComponents.count > 1
        {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: File helpers

    static func size(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// Lowercase hex SHA-256 of the file at `url`, read in 1 MiB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readReceipt(in directory: URL) -> ModelReceipt? {
        guard let data = try? Data(contentsOf: directory.appending(path: Self.receiptName)) else { return nil }
        return try? JSONDecoder.receipt.decode(ModelReceipt.self, from: data)
    }

    private func writeReceipt(_ receipt: ModelReceipt, in directory: URL) throws {
        let data = try JSONEncoder.receipt.encode(receipt)
        try data.write(to: directory.appending(path: Self.receiptName), options: .atomic)
    }
}

/// An installed model: where it is and what is known about it.
public struct ModelInstallation: Hashable, Sendable {
    /// The model's directory. Pass it to FluidAudio's loaders (see
    /// docs/models.md).
    public let directory: URL
    public let installedAt: Date
    /// The OS version the model was last loaded on, if it has been. Core ML
    /// caches a model's device-specific compilation per OS version.
    public let warmedUpOn: String?
}

/// Written into an installed model's directory after every file checked
/// out. Describes exactly what was installed.
struct ModelReceipt: Codable, Equatable {
    var id: ModelID
    var revision: String
    /// SHA-256 by path.
    var files: [String: String]
    var installedAt: Date
    var warmedUpOn: String?

    init(descriptor: ModelDescriptor, installedAt: Date, warmedUpOn: String?) {
        id = descriptor.id
        revision = descriptor.revision
        files = Dictionary(uniqueKeysWithValues: descriptor.files.map { ($0.path, $0.sha256) })
        self.installedAt = installedAt
        self.warmedUpOn = warmedUpOn
    }

    func matches(_ descriptor: ModelDescriptor) -> Bool {
        id == descriptor.id && revision == descriptor.revision
            && files == Dictionary(uniqueKeysWithValues: descriptor.files.map { ($0.path, $0.sha256) })
    }
}

extension JSONEncoder {
    fileprivate static var receipt: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var receipt: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
