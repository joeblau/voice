import BlauCore
import BlauTelemetry
import Foundation
import Testing

@Suite("File diagnostics store")
struct FileDiagnosticsStoreTests {
    let directory: URL
    let clock = ManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "FileDiagnosticsStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func makeStore(retention: DiagnosticsRetention = .standard) -> FileDiagnosticsStore {
        FileDiagnosticsStore(directory: directory, clock: clock, retention: retention)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    var metrics: CapturedPayload { DiagnosticsSamples.metricPayload(periodEnd: clock.now) }
    var diagnostics: CapturedPayload { DiagnosticsSamples.diagnosticPayload(periodEnd: clock.now) }

    @Test func startsEmptyWithoutCreatingTheDirectory() throws {
        defer { cleanUp() }
        #expect(try makeStore().records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    @Test func savesAndListsRecordsNewestFirst() throws {
        defer { cleanUp() }
        let store = makeStore()
        let first = try #require(try store.save(metrics))
        clock.advance(by: .seconds(60))
        let second = try #require(try store.save(diagnostics))

        #expect(first.receivedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first.kind == .metrics)
        #expect(second.kind == .diagnostics)
        #expect(try store.records() == [second, first])
    }

    @Test func storesThePayloadVerbatim() throws {
        defer { cleanUp() }
        let store = makeStore()
        let payload = metrics
        let record = try #require(try store.save(payload))
        #expect(try store.rawPayload(for: record) == payload.json)
        #expect(record.id == FileDiagnosticsStore.recordID(for: payload.json))
        #expect(record.id.count == 32)
    }

    @Test func ignoresDuplicatePayloads() throws {
        defer { cleanUp() }
        let store = makeStore()
        let payload = metrics
        #expect(try store.save(payload) != nil)
        clock.advance(by: .seconds(3_600))
        #expect(try store.save(payload) == nil, "the same JSON delivered again (e.g. via pastPayloads)")
        #expect(try store.records().count == 1)
    }

    @Test func survivesANewStoreInstance() throws {
        defer { cleanUp() }
        let record = try #require(try makeStore().save(metrics))
        #expect(try makeStore().records() == [record])
    }

    @Test func excludesTheDirectoryFromBackups() throws {
        defer { cleanUp() }
        try makeStore().save(metrics)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func reappliesTheBackupExclusionToAnExistingFolder() throws {
        defer { cleanUp() }
        // The folder exists without the flag: restored from a backup, or
        // created by an earlier build.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try root.setResourceValues(values)

        try makeStore().save(metrics)

        root.removeAllCachedResourceValues()
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func keepsAtMostTheConfiguredNumberPerKind() throws {
        defer { cleanUp() }
        let store = makeStore(retention: DiagnosticsRetention(maxRecordsPerKind: 2, maxAge: .seconds(1_000_000)))
        var saved: [DiagnosticsRecord] = []
        for _ in 0..<4 {
            saved.append(try #require(try store.save(metrics)))
            clock.advance(by: .seconds(60))
        }
        let kept = try #require(try store.save(diagnostics))

        let records = try store.records()
        #expect(records.filter { $0.kind == .metrics } == [saved[3], saved[2]])
        #expect(records.filter { $0.kind == .diagnostics } == [kept], "limits are per kind")
        #expect(throws: DiagnosticsStoreError.payloadMissing(id: saved[0].id)) { try store.rawPayload(for: saved[0]) }
    }

    @Test func dropsRecordsOlderThanMaxAge() throws {
        defer { cleanUp() }
        let store = makeStore(retention: DiagnosticsRetention(maxRecordsPerKind: 100, maxAge: .seconds(3_600)))
        let old = try #require(try store.save(metrics))
        clock.advance(by: .seconds(1_800))
        let recent = try #require(try store.save(metrics))
        clock.advance(by: .seconds(2_000))
        let newest = try #require(try store.save(metrics))

        #expect(try store.records() == [newest, recent])
        #expect(!(try store.records()).contains(old))
    }

    @Test func skipsUnreadableRecords() throws {
        defer { cleanUp() }
        let store = makeStore()
        let good = try #require(try store.save(metrics))
        let corrupt = directory.appending(path: "metrics/deadbeef.record.json")
        try Data("not json".utf8).write(to: corrupt)
        #expect(try store.records() == [good])
    }

    @Test func removeAllDeletesEverything() throws {
        defer { cleanUp() }
        let store = makeStore()
        try store.save(metrics)
        try store.save(diagnostics)
        try store.removeAll()
        #expect(try store.records().isEmpty)
        try store.removeAll()  // idempotent
    }

    @Test func deletedPayloadsAreNotStoredAgain() throws {
        defer { cleanUp() }
        let store = makeStore()
        let metricsPayload = metrics
        let diagnosticsPayload = diagnostics
        _ = try #require(try store.save(metricsPayload))
        _ = try #require(try store.save(diagnosticsPayload))
        try store.removeAll()

        // MetricKit hands the same payloads back through `pastPayloads` at
        // the next launch, here with a new store instance.
        clock.advance(by: .seconds(3_600))
        let relaunched = makeStore()
        #expect(try relaunched.save(metricsPayload) == nil)
        #expect(try relaunched.save(diagnosticsPayload) == nil)
        #expect(try relaunched.records().isEmpty)

        // New payloads are still stored.
        let next = DiagnosticsSamples.metricPayload(periodEnd: clock.now)
        #expect(try relaunched.save(next) != nil)
        #expect(try relaunched.records().count == 1)
    }

    @Test func prunedPayloadsAreNotStoredAgain() throws {
        defer { cleanUp() }
        let store = makeStore(retention: DiagnosticsRetention(maxRecordsPerKind: 1, maxAge: .seconds(1_000_000)))
        let first = metrics
        _ = try #require(try store.save(first))
        clock.advance(by: .seconds(60))
        let second = DiagnosticsSamples.metricPayload(periodEnd: clock.now)
        let kept = try #require(try store.save(second))
        #expect(try store.records() == [kept])

        clock.advance(by: .seconds(60))
        #expect(try store.save(first) == nil, "pruned by the per-kind limit, then delivered again")
        #expect(try store.records() == [kept])
    }

    @Test func tombstonesExpireWithTheRetentionPeriod() throws {
        defer { cleanUp() }
        let store = makeStore(retention: DiagnosticsRetention(maxRecordsPerKind: 100, maxAge: .seconds(3_600)))
        let old = metrics
        _ = try #require(try store.save(old))
        try store.removeAll()

        // A later delete, past the retention period, forgets the old
        // tombstone, so the file doesn't grow forever.
        clock.advance(by: .seconds(7_200))
        _ = try #require(try store.save(DiagnosticsSamples.metricPayload(periodEnd: clock.now)))
        try store.removeAll()
        #expect(try store.save(old) != nil)
    }

    @Test func isSafeToUseFromManyThreads() async throws {
        defer { cleanUp() }
        let store = makeStore()
        let payloads = (0..<20).map { index in
            DiagnosticsSamples.metricPayload(periodEnd: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads + payloads {
                group.addTask { _ = try store.save(payload) }
                group.addTask { _ = try store.records() }
            }
            try await group.waitForAll()
        }
        #expect(try store.records().count == 20)
    }

    // MARK: Export

    @Test func exportWritesOneJSONFileWithEveryPayload() throws {
        defer { cleanUp() }
        let store = makeStore()
        let metricsPayload = metrics
        let metricsRecord = try #require(try store.save(metricsPayload))
        clock.advance(by: .seconds(60))
        let diagnosticsRecord = try #require(try store.save(diagnostics))
        clock.advance(by: .seconds(60))

        let context = DiagnosticsExportContext(
            appVersion: "0.1.0", appBuild: "7", bundleIdentifier: "com.joeblau.blau", osVersion: "26.1",
            deviceModel: "iPhone17,1")
        let exportDirectory = directory.appending(path: "export", directoryHint: .isDirectory)
        let url = try store.export(context: context, to: exportDirectory)

        #expect(url.lastPathComponent == "Blau-Diagnostics-20270115-080200.json")
        #expect(url.deletingLastPathComponent().standardizedFileURL == exportDirectory.standardizedFileURL)

        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["format"] as? String == FileDiagnosticsStore.exportFormat)
        #expect(document["exportedAt"] as? String == "2027-01-15T08:02:00Z")

        let exportedContext = try #require(document["context"] as? [String: Any])
        #expect(exportedContext["appBuild"] as? String == "7")
        #expect(exportedContext["deviceModel"] as? String == "iPhone17,1")

        let overview = try #require(document["overview"] as? [String: Any])
        #expect(overview["metricPayloadCount"] as? Int == 1)
        #expect(overview["diagnosticPayloadCount"] as? Int == 1)
        #expect(overview["hangReportCount"] as? Int == 1)

        let payloads = try #require(document["payloads"] as? [[String: Any]])
        #expect(payloads.map { $0["id"] as? String } == [metricsRecord.id, diagnosticsRecord.id], "oldest first")
        #expect(payloads.map { $0["kind"] as? String } == ["metrics", "diagnostics"])
        let embedded = try #require(payloads.first?["payload"] as? [String: Any])
        let original = try #require(try JSONSerialization.jsonObject(with: metricsPayload.json) as? [String: Any])
        #expect(NSDictionary(dictionary: embedded).isEqual(to: original), "MetricKit JSON is embedded unchanged")
        #expect(payloads.first?["summary"] is [String: Any])
    }

    @Test func exportOfAnEmptyStoreIsValid() throws {
        defer { cleanUp() }
        let url = try makeStore().export(context: DiagnosticsExportContext(), to: directory)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((document["payloads"] as? [Any])?.isEmpty == true)
    }

    @Test func exportFileNameIsUTCTimestamped() {
        #expect(
            DiagnosticsExport.fileName(exportedAt: Date(timeIntervalSince1970: 0))
                == "Blau-Diagnostics-19700101-000000.json")
    }

    @Test func defaultDirectoryIsInApplicationSupport() throws {
        let url = try FileDiagnosticsStore.defaultDirectory()
        #expect(url.path(percentEncoded: false).contains("Application Support"))
        #expect(url.path(percentEncoded: false).hasSuffix("Diagnostics/MetricKit/"))
    }
}
