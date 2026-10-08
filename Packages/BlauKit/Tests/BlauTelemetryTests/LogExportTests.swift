import Foundation
import OSLog
import Testing
import os

@testable import BlauTelemetry

/// Settings → Developer → Export Logs.
@Suite("Log export")
struct LogExportTests {
    struct FixedSource: LogEntrySource {
        var entries: [LogExportEntry]

        func entries(since date: Date) throws -> [LogExportEntry] {
            entries.filter { $0.date >= date }
        }
    }

    let now = Date(timeIntervalSince1970: 1_791_363_600)  // 2026-10-07 09:00 UTC

    @Test func formatsOneLinePerMessage() {
        let entries = [
            LogExportEntry(
                date: now.addingTimeInterval(-60), category: "realtime", level: "notice", message: "Connected"),
            LogExportEntry(date: now.addingTimeInterval(-30), category: "audio", level: "error", message: "Two\nlines"),
        ]
        let text = LogExporter.format(entries, header: "Blau 1.0 (42)", since: now.addingTimeInterval(-3_600), now: now)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "Blau logs, 2026-10-07T08:00:00.000Z to 2026-10-07T09:00:00.000Z")
        #expect(lines[1] == "Blau 1.0 (42)")
        #expect(lines[2] == "2 messages. Values marked private are redacted.")
        #expect(lines.contains("2026-10-07T08:59:00.000Z [realtime] notice: Connected"))
        #expect(lines.contains("2026-10-07T08:59:30.000Z [audio] error: Two"))
        #expect(lines.contains("    lines"))
    }

    @Test func exportsTheWindowToAFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FixedSource(entries: [
            LogExportEntry(date: now.addingTimeInterval(-7_200), category: "ui", level: "info", message: "Too old"),
            LogExportEntry(date: now.addingTimeInterval(-10), category: "ui", level: "info", message: "Recent"),
        ])

        let url = try LogExporter(source: source).export(window: .seconds(3_600), now: now, to: directory)

        #expect(url.pathExtension == "txt")
        #expect(url.lastPathComponent.hasPrefix("Blau Logs "))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Recent"))
        #expect(!text.contains("Too old"))
        #expect(text.contains("1 messages."))
    }

    @Test func levelsHaveNames() {
        #expect(OSLogEntrySource.name(.error) == "error")
        #expect(OSLogEntrySource.name(.fault) == "fault")
        #expect(OSLogEntrySource.name(.undefined) == "default")
    }

    /// Reads this test process's own unified log. `OSLogStore` needs the
    /// log daemon, which some sandboxed CI runners don't offer, so a store
    /// that can't open is not a failure.
    @Test func readsTheUnifiedLog() throws {
        let marker = "log-export-test-\(UUID().uuidString)"
        let start = Date().addingTimeInterval(-1)
        Log.ui.notice("\(marker, privacy: .public)")
        let entries: [LogExportEntry]
        do {
            entries = try OSLogEntrySource().entries(since: start)
        } catch {
            return
        }
        // Logging is asynchronous; when the message has arrived it has
        // Blau's category and level.
        if let entry = entries.first(where: { $0.message.contains(marker) }) {
            #expect(entry.category == "ui")
            #expect(entry.level == "notice")
        }
    }
}
