import BlauCore
import BlauTelemetry
import Dispatch
import Foundation
import os

/// What one export did.
public struct MarkdownExportReport: Sendable, Equatable {
    /// What happened to one conversation's file.
    public enum Outcome: String, Sendable, Equatable {
        /// A new file.
        case created
        /// The file existed and its contents changed.
        case updated
        /// The title (or time zone) changed, so the file was renamed, and
        /// its contents updated if they changed too.
        case renamed
        /// The file already had exactly these contents; it wasn't touched.
        case unchanged
    }

    /// The folder the files are in.
    public var directory: URL
    public var created = 0
    public var updated = 0
    public var renamed = 0
    public var unchanged = 0
    /// Extra copies of a conversation's file that were removed (for example
    /// from two devices exporting a renamed conversation at once).
    public var removedDuplicates = 0
    /// Conversations with no utterances yet, which get no file.
    public var skippedEmpty = 0
    /// Conversations still being recorded, left for when they end (only
    /// automatic exports skip them).
    public var skippedOpen = 0
    /// Conversations whose file couldn't be written, with the error.
    public var failures: [UUID: String] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Conversations that have an up-to-date file after the export.
    public var exportedCount: Int { created + updated + renamed + unchanged }

    /// Files that were created, changed or renamed.
    public var changedCount: Int { created + updated + renamed }

    mutating func record(_ outcome: Outcome) {
        switch outcome {
        case .created: created += 1
        case .updated: updated += 1
        case .renamed: renamed += 1
        case .unchanged: unchanged += 1
        }
    }
}

/// Writes conversations as Markdown files into a folder, normally Blau's
/// folder in iCloud Drive (#78, docs/export.md).
///
/// **Off the main thread.** The exporter is an actor whose executor is its
/// own serial dispatch queue, so SwiftData reads and the blocking
/// `NSFileCoordinator` calls run there, never on the main thread and never
/// on (and starving) the Swift concurrency pool.
///
/// **Idempotent.** Every file carries its conversation's id in its name and
/// front matter. Re-exporting finds the conversation's file and:
///
/// - leaves it untouched when the rendered bytes are the same (no write, no
///   new modification date, nothing for iCloud Drive to upload);
/// - rewrites it when the conversation changed;
/// - renames it when its title changed, rather than adding a second file;
/// - removes extra copies of it.
///
/// Files that aren't Blau exports, and exports of conversations that no
/// longer exist, are never touched. The time zone recorded in an existing
/// file is reused, so devices in different time zones don't keep rewriting
/// each other's exports.
public actor MarkdownExporter {
    private let queue: DispatchSerialQueue
    private let source: any ConversationExportSource
    private let destination: MarkdownExportDestination
    private let fileSystem: any MarkdownExportFileSystem
    private let timeZone: @Sendable () -> TimeZone
    private let clock: any BlauClock

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// - Parameters:
    ///   - source: Where conversations are read.
    ///   - destination: The folder to export into.
    ///   - fileSystem: Coordinated file access; a fake in tests.
    ///   - timeZone: The time zone for conversations that have no file yet.
    ///   - clock: Measures how long an export takes (for the log).
    public init(
        source: any ConversationExportSource,
        destination: MarkdownExportDestination,
        fileSystem: any MarkdownExportFileSystem = CoordinatedMarkdownFileSystem(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        clock: any BlauClock = SystemClock()
    ) {
        self.queue = DispatchSerialQueue(label: "com.joeblau.blau.export.markdown", qos: .utility)
        self.source = source
        self.destination = destination
        self.fileSystem = fileSystem
        self.timeZone = timeZone
        self.clock = clock
    }

    /// Exports every conversation, including one still being recorded.
    ///
    /// - Parameter includeOpen: `false` skips conversations that haven't
    ///   ended (automatic exports wait for them to end).
    public func exportAll(includeOpen: Bool = true) throws(MarkdownExportError) -> MarkdownExportReport {
        let ids: [UUID]
        do {
            ids = try source.conversationIDs()
        } catch {
            Log.data.error("Export: reading conversations failed: \(String(describing: error), privacy: .public)")
            throw .storeUnavailable
        }
        return try export(ids, includeOpen: includeOpen)
    }

    /// Exports the conversations with `ids` that still exist.
    public func export(
        conversationIDs ids: some Collection<UUID>,
        includeOpen: Bool = true
    ) throws(MarkdownExportError) -> MarkdownExportReport {
        try export(Array(ids), includeOpen: includeOpen)
    }

    /// Exports the conversations `changes` touched that have ended, or
    /// every ended conversation if history was reset.
    public func export(affectedBy changes: StoreChangeSet) throws(MarkdownExportError) -> MarkdownExportReport {
        if changes.historyWasReset {
            return try exportAll(includeOpen: false)
        }
        let ids: Set<UUID>
        do {
            ids = try source.conversationIDs(affectedBy: changes)
        } catch {
            Log.data.error("Export: reading changes failed: \(String(describing: error), privacy: .public)")
            throw .storeUnavailable
        }
        // Sorted so the work (and the log) is in the same order every time.
        return try export(ids.sorted { $0.uuidString < $1.uuidString }, includeOpen: false)
    }

    // MARK: - Export

    private func export(_ ids: [UUID], includeOpen: Bool) throws(MarkdownExportError) -> MarkdownExportReport {
        let start = clock.uptime
        let directory = try destination.directory()
        var folder: Folder
        do {
            try fileSystem.prepareDirectory(directory)
            folder = Folder(directory: directory, entries: try fileSystem.contentsOfDirectory(directory))
        } catch {
            Log.data.error("Export: folder unavailable: \(String(describing: error), privacy: .public)")
            throw .folderUnavailable(String(describing: error))
        }

        var report = MarkdownExportReport(directory: directory)
        for id in ids {
            do {
                guard let snapshot = try source.snapshot(of: id) else { continue }
                if snapshot.isEmpty {
                    report.skippedEmpty += 1
                    continue
                }
                if snapshot.isOpen && !includeOpen {
                    report.skippedOpen += 1
                    continue
                }
                let result = try write(snapshot, into: &folder)
                report.record(result.outcome)
                report.removedDuplicates += result.removedDuplicates
            } catch {
                report.failures[id] = String(describing: error)
                Log.data.error(
                    "Export of \(id.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        let elapsed = clock.uptime - start
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        Log.data.notice(
            """
            Exported \(report.exportedCount) conversations to Markdown in \(milliseconds) ms: \
            \(report.created) created, \(report.updated) updated, \(report.renamed) renamed, \
            \(report.unchanged) unchanged, \(report.failures.count) failed
            """)
        return report
    }

    /// Writes one conversation's file and returns what happened.
    private func write(
        _ snapshot: ConversationExportSnapshot,
        into folder: inout Folder
    ) throws -> (outcome: MarkdownExportReport.Outcome, removedDuplicates: Int) {
        // This conversation's existing files: the name says so and the
        // front matter confirms it. A file that can't be read (still
        // downloading, say) is left alone rather than risk touching
        // someone else's.
        let existing: [ExistingFile] = folder.candidates(for: snapshot.id).compactMap { url in
            guard let data = try? fileSystem.read(url), let metadata = MarkdownExportMetadata.parse(data),
                metadata.conversationID == snapshot.id
            else { return nil }
            return ExistingFile(url: url, data: data, metadata: metadata)
        }

        let renderer = ConversationMarkdownRenderer(
            timeZone: existing.lazy.compactMap(\.metadata.timeZone).first ?? timeZone())
        let data = Data(renderer.render(snapshot).utf8)
        var target = folder.directory.appending(path: renderer.fileName(for: snapshot), directoryHint: .notDirectory)
        let isOurs = { (url: URL) in existing.contains { $0.url.lastPathComponent == url.lastPathComponent } }
        if folder.contains(target) && !isOurs(target) {
            // Another file has the short name: use the whole id.
            target = folder.directory.appending(
                path: renderer.fileName(for: snapshot, longID: true), directoryHint: .notDirectory)
        }

        let outcome: MarkdownExportReport.Outcome
        var kept: URL?
        if let current = existing.first(where: { $0.url.lastPathComponent == target.lastPathComponent }) {
            kept = current.url
            if current.data == data {
                outcome = .unchanged
            } else {
                try fileSystem.write(data, to: current.url)
                outcome = .updated
            }
        } else if let previous = existing.first {
            try fileSystem.move(previous.url, to: target)
            folder.moved(previous.url, to: target)
            kept = previous.url
            if previous.data != data {
                try fileSystem.write(data, to: target)
            }
            outcome = .renamed
        } else {
            try fileSystem.write(data, to: target)
            folder.added(target)
            outcome = .created
        }

        var removed = 0
        for duplicate in existing where duplicate.url.lastPathComponent != kept?.lastPathComponent {
            try fileSystem.remove(duplicate.url)
            folder.removed(duplicate.url)
            removed += 1
        }
        return (outcome, removed)
    }

    private struct ExistingFile {
        let url: URL
        let data: Data
        let metadata: MarkdownExportMetadata
    }

    /// The export folder's listing, read once per export and kept current
    /// as files are added, renamed and removed.
    private struct Folder {
        let directory: URL
        /// Logical file names (placeholders mapped to the real name).
        private var names: Set<String> = []
        /// Names of files that look like exports, by short id.
        private var byShortID: [String: Set<String>] = [:]

        init(directory: URL, entries: [URL]) {
            self.directory = directory
            for entry in entries {
                add(MarkdownExportFileName.logicalName(ofListedName: entry.lastPathComponent))
            }
        }

        func contains(_ url: URL) -> Bool {
            names.contains(url.lastPathComponent)
        }

        /// The files whose name carries `id`, in name order.
        func candidates(for id: UUID) -> [URL] {
            (byShortID[MarkdownExportFileName.shortID(id)] ?? []).sorted().map {
                directory.appending(path: $0, directoryHint: .notDirectory)
            }
        }

        mutating func added(_ url: URL) {
            add(url.lastPathComponent)
        }

        mutating func removed(_ url: URL) {
            let name = url.lastPathComponent
            names.remove(name)
            if let key = MarkdownExportFileName.shortID(inFileName: name) {
                byShortID[key]?.remove(name)
            }
        }

        mutating func moved(_ source: URL, to destination: URL) {
            removed(source)
            added(destination)
        }

        private mutating func add(_ name: String) {
            names.insert(name)
            if let key = MarkdownExportFileName.shortID(inFileName: name) {
                byShortID[key, default: []].insert(name)
            }
        }
    }
}
