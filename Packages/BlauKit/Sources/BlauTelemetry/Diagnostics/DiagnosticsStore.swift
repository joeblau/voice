import BlauCore
import CryptoKit
import Foundation
import Synchronization
import os

/// Keeps MetricKit payloads on this device and exports them.
///
/// Payloads are diagnostics about this install, not user content, so they
/// stay local: they are never written to SwiftData or CloudKit, and the
/// default directory is excluded from iCloud backups.
public protocol DiagnosticsStoring: Sendable {
    /// Stores `payload` unless an identical one is already stored, or was
    /// stored and then deleted (by `removeAll()` or retention).
    ///
    /// - Returns: The stored record, or `nil` if it was a duplicate or had
    ///   been deleted.
    @discardableResult
    func save(_ payload: CapturedPayload) throws -> DiagnosticsRecord?

    /// Every stored record, newest delivery first.
    func records() throws -> [DiagnosticsRecord]

    /// The MetricKit JSON stored for `record`.
    func rawPayload(for record: DiagnosticsRecord) throws -> Data

    /// Writes every stored payload into one JSON file in `directory` and
    /// returns its URL.
    func export(context: DiagnosticsExportContext, to directory: URL) throws -> URL

    /// Deletes every stored payload. Deleted payloads stay deleted: when
    /// MetricKit hands one back again (`pastPayloads` at the next launch),
    /// `save` ignores it.
    func removeAll() throws
}

/// How long the store keeps payloads.
public struct DiagnosticsRetention: Sendable, Hashable {
    /// The most records kept per `DiagnosticsPayloadKind`; the oldest
    /// deliveries go first.
    public var maxRecordsPerKind: Int
    /// Records delivered longer ago than this are deleted.
    public var maxAge: Duration

    public init(maxRecordsPerKind: Int, maxAge: Duration) {
        self.maxRecordsPerKind = maxRecordsPerKind
        self.maxAge = maxAge
    }

    /// 90 days, at most 120 payloads of each kind. MetricKit delivers about
    /// one metric payload a day, so this covers a whole beta cycle.
    public static let standard = DiagnosticsRetention(maxRecordsPerKind: 120, maxAge: .seconds(90 * 24 * 60 * 60))
}

/// Who and what an export describes. Filled in by the app.
public struct DiagnosticsExportContext: Codable, Sendable, Hashable {
    public var appVersion: String?
    public var appBuild: String?
    public var bundleIdentifier: String?
    public var osVersion: String?
    public var deviceModel: String?

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        bundleIdentifier: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }
}

/// Why the store could not do something.
public enum DiagnosticsStoreError: Error, Equatable, Sendable {
    /// The record's raw payload file is missing.
    case payloadMissing(id: String)
}

// MARK: - FileDiagnosticsStore

/// A `DiagnosticsStoring` backed by JSON files:
///
///     <directory>/metrics/<id>.payload.json       MetricKit's JSON, verbatim
///     <directory>/metrics/<id>.record.json        DiagnosticsRecord (summary)
///     <directory>/diagnostics/<id>.payload.json
///     <directory>/diagnostics/<id>.record.json
///     <directory>/<kind>/tombstones.json          IDs deleted, and when
///
/// Deleting a payload (`removeAll()`, or retention pruning it) leaves its ID
/// in `tombstones.json`, so a payload MetricKit delivers again at the next
/// launch isn't stored again. Tombstones are kept as long as records are
/// (`DiagnosticsRetention.maxAge`).
///
/// Each payload lives in its own files, written atomically, so a crash
/// mid-write can't corrupt the others and a record that fails to decode is
/// skipped rather than hiding the rest. Thread safe: MetricKit calls in on a
/// background queue while the UI reads.
public final class FileDiagnosticsStore: DiagnosticsStoring {
    /// The export file format; bump when its shape changes.
    public static let exportFormat = "com.joeblau.blau.diagnostics.v1"

    public let directory: URL
    private let clock: any BlauClock
    private let retention: DiagnosticsRetention
    private let excludeFromBackup: Bool
    /// Serializes file access. The store keeps no other state.
    private let lock = Mutex(())

    /// - Parameters:
    ///   - directory: Where payloads are kept. Created on first write.
    ///   - clock: Timestamps deliveries and drives retention.
    ///   - retention: How many payloads to keep and for how long.
    ///   - excludeFromBackup: Marks `directory` as excluded from iCloud and
    ///     device backups on every write, so a folder that lost the flag
    ///     (restored, or created by an older build) gets it back.
    public init(
        directory: URL,
        clock: any BlauClock = SystemClock(),
        retention: DiagnosticsRetention = .standard,
        excludeFromBackup: Bool = true
    ) {
        self.directory = directory
        self.clock = clock
        self.retention = retention
        self.excludeFromBackup = excludeFromBackup
    }

    /// `Application Support/Diagnostics/MetricKit` in the app's container.
    /// Outside the SwiftData store and never synced.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Diagnostics/MetricKit", directoryHint: .isDirectory)
    }

    /// The record ID for a payload: the first 16 bytes of its SHA-256, hex.
    public static func recordID(for json: Data) -> String {
        SHA256.hash(data: json).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: DiagnosticsStoring

    @discardableResult
    public func save(_ payload: CapturedPayload) throws -> DiagnosticsRecord? {
        try lock.withLock { _ in
            let id = Self.recordID(for: payload.json)
            let folder = try folder(for: payload.kind, create: true)
            let recordURL = Self.recordURL(id: id, in: folder)
            guard !FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)),
                loadTombstones(in: folder)[id] == nil
            else {
                return nil
            }

            let record = DiagnosticsRecord(id: id, receivedAt: clock.now, summary: payload.summary)
            // Payload first: a record file only exists once its payload does.
            try payload.json.write(to: Self.payloadURL(id: id, in: folder), options: .atomic)
            try Self.encoder.encode(record).write(to: recordURL, options: .atomic)
            try prune(kind: payload.kind)
            return record
        }
    }

    public func records() throws -> [DiagnosticsRecord] {
        try lock.withLock { _ in
            try DiagnosticsPayloadKind.allCases.flatMap { try loadRecords(kind: $0) }
                .sorted { ($0.receivedAt, $0.id) > ($1.receivedAt, $1.id) }
        }
    }

    public func rawPayload(for record: DiagnosticsRecord) throws -> Data {
        try lock.withLock { _ in
            let url = Self.payloadURL(id: record.id, in: try folder(for: record.kind, create: false))
            guard let data = try? Data(contentsOf: url) else {
                throw DiagnosticsStoreError.payloadMissing(id: record.id)
            }
            return data
        }
    }

    public func export(context: DiagnosticsExportContext, to destination: URL) throws -> URL {
        // Read under the lock, build and write the file outside it.
        let (records, payloads) = try lock.withLock { _ in
            let records = try DiagnosticsPayloadKind.allCases.flatMap { try loadRecords(kind: $0) }
                .sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
            var payloads: [String: Data] = [:]
            for record in records {
                let url = Self.payloadURL(id: record.id, in: try folder(for: record.kind, create: false))
                payloads[record.id] = try? Data(contentsOf: url)
            }
            return (records, payloads)
        }

        let exportedAt = clock.now
        let data = try DiagnosticsExport.make(
            records: records, payloads: payloads, context: context, exportedAt: exportedAt)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appending(path: DiagnosticsExport.fileName(exportedAt: exportedAt))
        try data.write(to: url, options: .atomic)
        return url
    }

    public func removeAll() throws {
        try lock.withLock { _ in
            for kind in DiagnosticsPayloadKind.allCases {
                let folder = try folder(for: kind, create: false)
                guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
                // Tombstones first, so a failure part-way never lets a
                // deleted payload come back.
                let ids = try loadRecords(kind: kind).map(\.id)
                try addTombstones(ids, in: folder)
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                for name in names where name != Self.tombstonesName {
                    try FileManager.default.removeItem(at: folder.appending(path: name))
                }
            }
        }
    }

    // MARK: Files

    private static let recordSuffix = ".record.json"
    private static let payloadSuffix = ".payload.json"
    private static let tombstonesName = "tombstones.json"

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

    private static func recordURL(id: String, in folder: URL) -> URL {
        folder.appending(path: id + recordSuffix)
    }

    private static func payloadURL(id: String, in folder: URL) -> URL {
        folder.appending(path: id + payloadSuffix)
    }

    /// Call with the lock held.
    private func folder(for kind: DiagnosticsPayloadKind, create: Bool) throws -> URL {
        let folder = directory.appending(path: kind.rawValue, directoryHint: .isDirectory)
        guard create else { return folder }
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if excludeFromBackup {
            try excludeRootFromBackup()
        }
        return folder
    }

    /// Call with the lock held. Sets `isExcludedFromBackup` on `directory`
    /// unless it is already set, whoever created the folder.
    private func excludeRootFromBackup() throws {
        var root = directory
        root.removeAllCachedResourceValues()
        guard try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true else {
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private static func tombstonesURL(in folder: URL) -> URL {
        folder.appending(path: tombstonesName)
    }

    /// Call with the lock held. Deleted record IDs and when they were
    /// deleted; empty when there are none or the file doesn't decode.
    private func loadTombstones(in folder: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: Self.tombstonesURL(in: folder)) else { return [:] }
        do {
            return try Self.decoder.decode([String: Date].self, from: data)
        } catch {
            Log.data.error("Ignoring unreadable diagnostics tombstones: \(error, privacy: .public)")
            return [:]
        }
    }

    /// Call with the lock held. Records `ids` as deleted now, and forgets
    /// tombstones older than the retention period.
    private func addTombstones(_ ids: [String], in folder: URL) throws {
        let now = clock.now
        let oldestKept = now.addingTimeInterval(-retention.maxAge.timeInterval)
        var tombstones = loadTombstones(in: folder).filter { $0.value >= oldestKept }
        for id in ids {
            tombstones[id] = now
        }
        try Self.encoder.encode(tombstones).write(to: Self.tombstonesURL(in: folder), options: .atomic)
    }

    /// Call with the lock held. Skips (and logs) records that don't decode.
    private func loadRecords(kind: DiagnosticsPayloadKind) throws -> [DiagnosticsRecord] {
        let folder = try folder(for: kind, create: false)
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        else { return [] }

        return names.filter { $0.hasSuffix(Self.recordSuffix) }.compactMap { name in
            let url = folder.appending(path: name)
            do {
                return try Self.decoder.decode(DiagnosticsRecord.self, from: Data(contentsOf: url))
            } catch {
                Log.data.error(
                    "Skipping unreadable diagnostics record \(name, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    /// Call with the lock held. Deletes the oldest records of `kind` beyond
    /// the retention limits.
    private func prune(kind: DiagnosticsPayloadKind) throws {
        let folder = try folder(for: kind, create: false)
        let oldestKept = clock.now.addingTimeInterval(-retention.maxAge.timeInterval)
        let newestFirst = try loadRecords(kind: kind).sorted { ($0.receivedAt, $0.id) > ($1.receivedAt, $1.id) }

        let pruned = newestFirst.enumerated()
            .filter { index, record in index >= retention.maxRecordsPerKind || record.receivedAt < oldestKept }
            .map(\.element)
        guard !pruned.isEmpty else { return }
        try addTombstones(pruned.map(\.id), in: folder)
        for record in pruned {
            try? FileManager.default.removeItem(at: Self.recordURL(id: record.id, in: folder))
            try? FileManager.default.removeItem(at: Self.payloadURL(id: record.id, in: folder))
        }
    }
}

// MARK: - Export format

/// Builds the single JSON file the share sheet exports:
///
/// ```json
/// {
///   "format": "com.joeblau.blau.diagnostics.v1",
///   "exportedAt": "2026-10-07T12:00:00Z",
///   "context": { "appVersion": "0.1.0", "appBuild": "42", ... },
///   "overview": { "hangReportCount": 2, "peakMemoryBytes": 312000000, ... },
///   "payloads": [
///     { "kind": "metrics", "id": "…", "receivedAt": "…", "summary": { … }, "payload": { …MetricKit JSON… } }
///   ]
/// }
/// ```
///
/// `payload` is MetricKit's own JSON, embedded as an object so Xcode
/// Organizer-style tooling and `jq` can read it directly.
public enum DiagnosticsExport {
    public static func make(
        records: [DiagnosticsRecord],
        payloads: [String: Data],
        context: DiagnosticsExportContext,
        exportedAt: Date
    ) throws -> Data {
        let entries: [[String: Any]] = try records.map { record in
            var entry: [String: Any] = [
                "id": record.id,
                "kind": record.kind.rawValue,
                "receivedAt": iso8601(record.receivedAt),
                "summary": try jsonObject(record.summary),
            ]
            if let data = payloads[record.id] {
                // MetricKit's JSON is always an object; keep anything else as text.
                entry["payload"] =
                    (try? JSONSerialization.jsonObject(with: data))
                    ?? String(decoding: data, as: UTF8.self)
            } else {
                entry["payload"] = NSNull()
            }
            return entry
        }

        let document: [String: Any] = [
            "format": FileDiagnosticsStore.exportFormat,
            "exportedAt": iso8601(exportedAt),
            "context": try jsonObject(context),
            "overview": try jsonObject(DiagnosticsOverview(records: records)),
            "payloads": entries,
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    /// `Blau-Diagnostics-20261007-120000.json` (UTC).
    public static func fileName(exportedAt: Date) -> String {
        "Blau-Diagnostics-\(exportedAt.formatted(fileStamp)).json"
    }

    private static let fileStamp = Date.VerbatimFormatStyle(
        format:
            "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
}
