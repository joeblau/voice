import BlauTelemetry
import Foundation
import Synchronization
import os

/// A topic summary a consolidation rewrote.
public struct TopicSummaryChange: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { topicID }
    public var topicID: UUID
    public var title: String
    public var before: String?
    public var after: String

    public init(topicID: UUID, title: String, before: String?, after: String) {
        self.topicID = topicID
        self.title = title
        self.before = before
        self.after = after
    }

    public var diff: ProfileDiff { ProfileDiff(before: before ?? "", after: after) }
}

/// One consolidation that changed something: what the profile summary was
/// and became, and the topic summaries it rewrote. The diff view shows it.
public struct ProfileConsolidationRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var reason: ProfileConsolidationReason
    /// The summary before (`ProfileBlock.text`); empty for the first.
    public var before: String
    public var after: String
    public var topicChanges: [TopicSummaryChange]
    /// How many facts, notes and topics the model was shown.
    public var factCount: Int
    public var noteCount: Int
    public var topicCount: Int

    public init(
        id: UUID = UUID(), date: Date, reason: ProfileConsolidationReason, before: String, after: String,
        topicChanges: [TopicSummaryChange] = [], factCount: Int = 0, noteCount: Int = 0, topicCount: Int = 0
    ) {
        self.id = id
        self.date = date
        self.reason = reason
        self.before = before
        self.after = after
        self.topicChanges = topicChanges
        self.factCount = factCount
        self.noteCount = noteCount
        self.topicCount = topicCount
    }

    /// The word-level diff of the profile summary.
    public var diff: ProfileDiff { ProfileDiff(before: before, after: after) }

    /// Whether the profile summary itself changed (rather than only topic
    /// summaries).
    public var changedProfile: Bool { before != after }

    /// The new summary's estimated tokens.
    public var tokenCount: Int { ProfileComposer.tokens(after) }
}

/// This device's consolidation log: when it last ran and the most recent
/// changes, newest first.
public struct ProfileConsolidationLog: Codable, Hashable, Sendable {
    /// The most records kept.
    public static let capacity = 30

    /// The last successful run here, changed or not.
    public var lastRunAt: Date?
    /// The last run here that didn't finish (it failed or was skipped):
    /// the start of the retry backoff.
    public var lastAttemptAt: Date?
    /// Runs in a row that didn't finish since the last successful one;
    /// each one doubles the retry backoff
    /// (`ProfileConsolidationSchedule.retryDelay(afterFailedAttempts:)`).
    public var failedAttempts: Int
    /// Facts the user removed (deleted or forgot) that no finished run has
    /// read memory without yet. Any makes the next run due on its own
    /// (`ProfileConsolidationReason.removedFacts`).
    public var pendingRemovals: Int
    /// Newest first, at most `capacity`.
    public var records: [ProfileConsolidationRecord]

    public init(
        lastRunAt: Date? = nil, lastAttemptAt: Date? = nil, failedAttempts: Int = 0, pendingRemovals: Int = 0,
        records: [ProfileConsolidationRecord] = []
    ) {
        self.lastRunAt = lastRunAt
        self.lastAttemptAt = lastAttemptAt
        self.failedAttempts = max(0, failedAttempts)
        self.pendingRemovals = max(0, pendingRemovals)
        self.records = records
    }

    /// Notes that the user removed `count` facts.
    public mutating func recordRemovals(_ count: Int) {
        guard count > 0 else { return }
        pendingRemovals += count
    }

    /// Notes a run that didn't finish at `date`.
    public mutating func recordFailedAttempt(at date: Date) {
        lastAttemptAt = date
        failedAttempts += 1
    }

    /// Notes a run that finished at `date`, changed or not.
    ///
    /// - Parameter removals: The `pendingRemovals` there were when the run
    ///   started reading memory; the run saw memory without them, so they
    ///   are cleared. Removals noted while it ran wait for the next one.
    public mutating func recordSuccessfulRun(at date: Date, removals: Int = 0) {
        lastRunAt = date
        lastAttemptAt = nil
        failedAttempts = 0
        pendingRemovals = max(0, pendingRemovals - max(0, removals))
    }

    private enum CodingKeys: String, CodingKey {
        case lastRunAt, lastAttemptAt, failedAttempts, pendingRemovals, records
    }

    /// Reads logs written before the retry backoff and removal count
    /// existed too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastRunAt: try container.decodeIfPresent(Date.self, forKey: .lastRunAt),
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            failedAttempts: try container.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0,
            pendingRemovals: try container.decodeIfPresent(Int.self, forKey: .pendingRemovals) ?? 0,
            records: try container.decodeIfPresent([ProfileConsolidationRecord].self, forKey: .records) ?? [])
    }

    /// Adds `record` first and drops the oldest past `capacity`.
    public mutating func insert(_ record: ProfileConsolidationRecord) {
        records.insert(record, at: 0)
        if records.count > Self.capacity {
            records.removeLast(records.count - Self.capacity)
        }
    }
}

/// Keeps the consolidation log. Per device: the profile block itself syncs,
/// while the history of how this device changed it stays here.
public protocol ProfileConsolidationLogStore: Sendable {
    func load() -> ProfileConsolidationLog
    func save(_ log: ProfileConsolidationLog)
}

/// The log as a JSON file (Application Support in the app), written
/// atomically. It holds profile text, so on iOS it is protected until the
/// first unlock after a restart, which still lets a background task read
/// and write it while the device is locked.
public final class FileProfileConsolidationLogStore: ProfileConsolidationLogStore {
    public let url: URL
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Memory/profile-consolidations.json`.
    public static func applicationSupport(fileManager: FileManager = .default) -> FileProfileConsolidationLogStore {
        let base =
            (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return FileProfileConsolidationLogStore(
            url: base.appending(path: "Memory", directoryHint: .isDirectory)
                .appending(path: "profile-consolidations.json"))
    }

    public func load() -> ProfileConsolidationLog {
        lock.withLock { _ in
            guard let data = try? Data(contentsOf: url) else { return ProfileConsolidationLog() }
            do {
                return try Self.decoder.decode(ProfileConsolidationLog.self, from: data)
            } catch {
                Log.memory.error(
                    "Unreadable profile consolidation log, starting over: \(String(describing: error), privacy: .public)"
                )
                return ProfileConsolidationLog()
            }
        }
    }

    public func save(_ log: ProfileConsolidationLog) {
        lock.withLock { _ in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Self.encoder.encode(log)
                #if os(iOS)
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                    try data.write(to: url, options: .atomic)
                #endif
            } catch {
                Log.memory.error(
                    "Couldn't save the profile consolidation log: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The log in memory. For tests, previews and UI-test launches.
public final class InMemoryProfileConsolidationLogStore: ProfileConsolidationLogStore {
    private let log: Mutex<ProfileConsolidationLog>

    public init(_ log: ProfileConsolidationLog = ProfileConsolidationLog()) {
        self.log = Mutex(log)
    }

    public func load() -> ProfileConsolidationLog { log.withLock { $0 } }

    public func save(_ log: ProfileConsolidationLog) { self.log.withLock { $0 = log } }
}

// MARK: - Notes from extraction

/// Keeps the extraction notes (`ProfileConsolidationNote`) waiting for the
/// next consolidation, across launches.
public protocol ProfileConsolidationNoteStore: Sendable {
    func load() -> [ProfileConsolidationNote]
    func save(_ notes: [ProfileConsolidationNote])
}

/// The notes in `UserDefaults`, as JSON. Per device, like the extraction
/// queue: the device that extracted a topic has its note.
public struct UserDefaultsProfileConsolidationNoteStore: ProfileConsolidationNoteStore {
    public static let defaultKey = "blau.memory.profileConsolidationNotes"

    private let suiteName: String?
    private let key: String

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> [ProfileConsolidationNote] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ProfileConsolidationNote].self, from: data)) ?? []
    }

    public func save(_ notes: [ProfileConsolidationNote]) {
        if notes.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(notes) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The notes in memory. For tests, previews and UI-test launches.
public final class InMemoryProfileConsolidationNoteStore: ProfileConsolidationNoteStore {
    private let notes: Mutex<[ProfileConsolidationNote]>

    public init(_ notes: [ProfileConsolidationNote] = []) {
        self.notes = Mutex(notes)
    }

    public func load() -> [ProfileConsolidationNote] { notes.withLock { $0 } }

    public func save(_ notes: [ProfileConsolidationNote]) { self.notes.withLock { $0 = notes } }
}
