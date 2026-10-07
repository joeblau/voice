import Foundation
import OSLog
import os

/// One log message, as exported.
public struct LogExportEntry: Sendable, Hashable {
    public var date: Date
    /// The `LogCategory` raw value (`audio`, `realtime`...).
    public var category: String
    /// `debug`, `info`, `notice`, `error` or `fault`.
    public var level: String
    public var message: String

    public init(date: Date, category: String, level: String, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Where exported log messages come from. The seam that keeps the export
/// testable: the app reads the unified log, tests pass a fixed list.
public protocol LogEntrySource: Sendable {
    /// Blau's messages logged at or after `date`, oldest first.
    func entries(since date: Date) throws -> [LogExportEntry]
}

/// Reads Blau's messages (`Log.subsystem`) from the unified log of the
/// running process with `OSLogStore`. iOS only gives an app its own
/// process's log, so this covers the current run.
///
/// Values logged as `.private` (what the user said, see
/// docs/performance.md) come back redacted as `<private>`, so an export
/// never contains the conversation.
public struct OSLogEntrySource: LogEntrySource {
    public var subsystem: String

    public init(subsystem: String = Log.subsystem) {
        self.subsystem = subsystem
    }

    public func entries(since date: Date) throws -> [LogExportEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: date)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog, entry.date >= date else { return nil }
            return LogExportEntry(
                date: log.date, category: log.category, level: Self.name(log.level), message: log.composedMessage)
        }
    }

    static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "default"
        @unknown default: "default"
        }
    }
}

/// Writes Blau's recent log messages to a text file for Settings →
/// Developer → Export Logs (shared through the share sheet).
public struct LogExporter: Sendable {
    /// How far back an export reaches by default.
    public static let defaultWindow: Duration = .seconds(60 * 60)

    private let source: any LogEntrySource

    public init(source: any LogEntrySource = OSLogEntrySource()) {
        self.source = source
    }

    /// Writes the messages logged in the `window` before `now` to a file
    /// in `directory` and returns its URL.
    public func export(
        window: Duration = defaultWindow, now: Date = Date(), to directory: URL = .temporaryDirectory,
        header: String = ""
    ) throws -> URL {
        let since = now.addingTimeInterval(-Double(window.components.seconds))
        let entries = try source.entries(since: since)
        let text = Self.format(entries, header: header, since: since, now: now)
        let url = directory.appending(path: "Blau Logs \(Self.fileStamp(now)).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        Log.ui.notice("Exported \(entries.count, privacy: .public) log messages")
        return url
    }

    /// The export's text: a header, then one line per message:
    /// `2026-10-08T09:41:00.123Z [realtime] notice: Connected`.
    public static func format(_ entries: [LogExportEntry], header: String, since: Date, now: Date) -> String {
        let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var lines = ["Blau logs, \(since.formatted(timestamp)) to \(now.formatted(timestamp))"]
        if !header.isEmpty {
            lines.append(header)
        }
        lines.append("\(entries.count) messages. Values marked private are redacted.")
        lines.append("")
        for entry in entries {
            let message = entry.message.replacingOccurrences(of: "\n", with: "\n    ")
            lines.append("\(entry.date.formatted(timestamp)) [\(entry.category)] \(entry.level): \(message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
    }
}
