import Foundation

/// The file operations the Markdown export needs. The exporter calls them on
/// its own serial queue, never on the main thread: file coordination blocks
/// until other readers and writers (iCloud Drive's sync daemon, Files, the
/// same file open on a Mac) are done.
public protocol MarkdownExportFileSystem: Sendable {
    /// Creates `directory` (and its parents) if needed.
    func prepareDirectory(_ directory: URL) throws
    /// The entries in `directory`, hidden ones included (iCloud Drive
    /// placeholders start with a dot).
    func contentsOfDirectory(_ directory: URL) throws -> [URL]
    func read(_ url: URL) throws -> Data
    /// Replaces the file at `url` with `data`, or creates it.
    func write(_ data: Data, to url: URL) throws
    /// Renames `source` to `destination`, which must not exist.
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
}

/// The real file system, every access coordinated with `NSFileCoordinator`
/// as iCloud Drive requires (the "Configuring iCloud services" and "Document
/// based apps" guides): the sync daemon sees each change as one unit, and a
/// file that is still downloading is read only once it is complete.
///
/// After writing to a file in iCloud Drive it also resolves version
/// conflicts. Two devices exporting the same conversation while offline
/// leave conflict versions behind; the export is regenerated from the synced
/// store, so the version just written wins and the others are removed.
public struct CoordinatedMarkdownFileSystem: MarkdownExportFileSystem {
    public init() {}

    public func prepareDirectory(_ directory: URL) throws {
        try coordinate(writing: directory, options: []) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func contentsOfDirectory(_ directory: URL) throws -> [URL] {
        try coordinate(reading: directory, options: [.withoutChanges]) { url in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        }
    }

    public func read(_ url: URL) throws -> Data {
        try coordinate(reading: url, options: []) { url in
            try Data(contentsOf: url)
        }
    }

    public func write(_ data: Data, to url: URL) throws {
        try coordinate(writing: url, options: [.forReplacing]) { url in
            try data.write(to: url, options: [.atomic])
            try Self.resolveConflicts(at: url)
        }
    }

    public func move(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .success(())
        coordinator.coordinate(
            writingItemAt: source, options: [.forMoving], writingItemAt: destination, options: [.forReplacing],
            error: &coordinationError
        ) { from, to in
            result = Result {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    public func remove(_ url: URL) throws {
        try coordinate(writing: url, options: [.forDeleting]) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Coordination

    private func coordinate<T>(
        reading url: URL,
        options: NSFileCoordinator.ReadingOptions,
        _ body: (URL) throws -> T
    ) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: options, error: &coordinationError
        ) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func coordinate<T>(
        writing url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> T
    ) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    /// Keeps the current version of an iCloud Drive file and drops any
    /// conflicting ones. Does nothing for a file outside iCloud Drive.
    static func resolveConflicts(at url: URL) throws {
        guard FileManager.default.isUbiquitousItem(at: url),
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty
        else { return }
        for version in conflicts {
            version.isResolved = true
        }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}
