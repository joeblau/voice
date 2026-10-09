import BlauTelemetry
import Foundation
import os

/// Writes a ``DataExport`` as files: Settings → Privacy & Data → Export All
/// Data (#79).
///
/// ```
/// Blau Export 2026-10-08/
///   README.md          what each file holds
///   blau-data.json     every record (DataExport, encoded)
///   Conversations.md   every conversation, as Settings → iCloud exports it
///   Knowledge.md       About Me, company, notes, collections, the profile
///                      summary and what Blau learned
/// ```
///
/// ``writeArchive(_:in:)`` zips that folder into `Blau Export 2026-10-08.zip`
/// for the share sheet, which handles one file far better than a folder.
public struct DataExporter: Sendable {
    public static let jsonFileName = "blau-data.json"
    public static let conversationsFileName = "Conversations.md"
    public static let knowledgeFileName = "Knowledge.md"
    public static let readmeFileName = "README.md"

    public var locale: Locale
    public var timeZone: TimeZone

    public init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    // MARK: JSON

    /// `export` as pretty-printed JSON with sorted keys and ISO 8601 dates.
    public func json(_ export: DataExport) throws -> Data {
        try Self.encoder.encode(export)
    }

    /// Decodes what ``json(_:)`` wrote.
    public static func decode(_ data: Data) throws -> DataExport {
        try decoder.decode(DataExport.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.iso8601))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Self.iso8601.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }()

    /// Milliseconds kept, so utterances a fraction of a second apart keep
    /// their order and timing.
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // MARK: Markdown

    /// Every conversation's committed lines, the same Markdown as Settings →
    /// iCloud → Export Conversations (`ConversationExporter`).
    public func conversationsMarkdown(_ export: DataExport) -> String {
        let snapshots = export.conversations.map { conversation in
            let topics = Dictionary(
                conversation.topics.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            return ConversationExporter.Snapshot(
                title: conversation.title, startedAt: conversation.startedAt, endedAt: conversation.endedAt,
                lines: conversation.utterances.filter(\.isFinal).map { utterance in
                    ConversationExporter.Snapshot.Line(
                        role: UtteranceRole(rawValue: utterance.role) ?? .system, text: utterance.text,
                        startedAt: utterance.startedAt, topic: utterance.topicID.flatMap { topics[$0] })
                })
        }
        return ConversationExporter(locale: locale, timeZone: timeZone)
            .markdown(for: snapshots, exportedAt: export.exportedAt)
    }

    /// The knowledge base and memory: the user's own pages first, then what
    /// Blau maintains and learned.
    public func knowledgeMarkdown(_ export: DataExport) -> String {
        var output = "# Blau knowledge and memory\n\nExported \(format(export.exportedAt, time: true))\n"

        func pages(_ kind: DocumentKind) -> [DataExport.DocumentRecord] {
            export.documents.filter { $0.kind == kind.rawValue }
        }
        let known = Set(DocumentKind.allCases.map(\.rawValue))
        let sections: [(String, [DataExport.DocumentRecord])] = [
            ("About Me", pages(.profile)),
            ("Company", pages(.company)),
            ("Notes", pages(.note)),
            ("Collections", pages(.collection)),
            ("Other pages", export.documents.filter { !known.contains($0.kind) }),
        ]
        for (heading, documents) in sections where !documents.isEmpty {
            output += "\n## \(heading)\n"
            for document in documents {
                output += page(document, titled: documents.count > 1 || !document.title.isEmpty)
            }
        }

        let profiles = export.profileBlocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !profiles.isEmpty {
            output += "\n## Profile summary\n\n"
            output += "What Blau tells Grok about you at the start of each conversation, kept up to date from what "
            output += "it learned.\n"
            for block in profiles {
                if profiles.count > 1 || block.key != ProfileBlock.userKey {
                    output += "\n### \(ConversationExporter.escapeHeading(block.key))\n"
                }
                output += "\n\(block.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                output += "\n_Updated \(format(block.updatedAt, time: true))_\n"
            }
        }

        if !export.facts.isEmpty || !export.entities.isEmpty {
            output += "\n## What Blau learned\n"
            let current = export.facts.filter(\.isCurrent)
            let past = export.facts.filter { !$0.isCurrent }
            if !current.isEmpty {
                output += "\n### Current\n\n"
                for fact in current {
                    output += "- \(Self.oneLine(fact.statement))\(sinceSuffix(fact))\n"
                }
            }
            if !past.isEmpty {
                output += "\n### No longer true\n\n"
                for fact in past {
                    output += "- \(Self.oneLine(fact.statement))\(spanSuffix(fact))\n"
                }
            }
            if !export.entities.isEmpty {
                output += "\n### People and things\n\n"
                for entity in export.entities {
                    var line = "- **\(Self.oneLine(entity.name))** (\(entity.type))"
                    if !entity.aliases.isEmpty {
                        line += ", also \(entity.aliases.map(Self.oneLine).joined(separator: ", "))"
                    }
                    if let summary = entity.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !summary.isEmpty
                    {
                        line += ": \(Self.oneLine(summary))"
                    }
                    output += line + "\n"
                }
            }
        }

        if export.documents.isEmpty && profiles.isEmpty && export.facts.isEmpty && export.entities.isEmpty {
            output += "\nNothing in the knowledge base yet.\n"
        }
        return output
    }

    /// What the export holds and what each file is.
    public func readme(_ export: DataExport) -> String {
        let counts = export.counts
        var output = "# Blau data export\n\n"
        output += "Exported \(format(export.exportedAt, time: true))"
        if let app = export.app { output += " from \(app)" }
        output += ".\n\n"
        output += "| File | What it holds |\n| ---- | ------------- |\n"
        output += "| `\(Self.jsonFileName)` | Every record Blau keeps, as JSON (format `\(export.format)`, "
        output += "version \(export.formatVersion), schema \(export.schemaVersion)) |\n"
        output += "| `\(Self.conversationsFileName)` | \(Self.plural(counts.conversations, "conversation")) as "
        output += "readable text |\n"
        output += "| `\(Self.knowledgeFileName)` | \(Self.plural(counts.documents, "knowledge base page")), "
        output += "the profile summary and \(Self.plural(counts.facts, "learned fact")) |\n"
        output += "\nThe JSON also lists \(Self.plural(counts.utterances, "transcribed line")) "
        output +=
            "(including unfinished ones), \(Self.plural(counts.entities, "person or thing", "people and things")) "
        output += "and \(Self.plural(counts.voiceprints, "voiceprint")). "
        output += "A voiceprint is described (model, enrollment dates, devices) without its vectors: they are a "
        output += "biometric template only Blau's speaker model can use.\n"
        output += "\nThis is a copy. Deleting it doesn't change what Blau keeps, and deleting data in Blau doesn't "
        output += "change this copy.\n"
        return output
    }

    // MARK: Files

    /// `Blau Export <yyyy-MM-dd>`: the folder (and, with `.zip`, the
    /// archive) name for an export made at `date`.
    public func baseName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "Blau Export %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Writes the export's files into a new folder in `parent` (replacing
    /// one of the same name) and returns the folder.
    public func writeFolder(_ export: DataExport, in parent: URL) throws -> URL {
        let folder = parent.appending(path: baseName(for: export.exportedAt), directoryHint: .isDirectory)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            (Self.readmeFileName, Data(readme(export).utf8)),
            (Self.jsonFileName, try json(export)),
            (Self.conversationsFileName, Data(conversationsMarkdown(export).utf8)),
            (Self.knowledgeFileName, Data(knowledgeMarkdown(export).utf8)),
        ]
        for (name, data) in files {
            #if os(iOS)
                try data.write(to: folder.appending(path: name), options: [.atomic, .completeFileProtection])
            #else
                try data.write(to: folder.appending(path: name), options: .atomic)
            #endif
        }
        return folder
    }

    /// Writes the export and zips it into `parent`/`Blau Export <date>.zip`
    /// (replacing one of the same name). The intermediate folder is
    /// removed.
    public func writeArchive(_ export: DataExport, in parent: URL) throws -> URL {
        let staging = parent.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let folder = try writeFolder(export, in: staging)
        let archive = parent.appending(path: baseName(for: export.exportedAt) + ".zip")
        try DataExportArchiver.zip(folder, to: archive)
        Log.data.notice(
            "Exported all data: \(export.counts.conversations, privacy: .public) conversations, \(export.counts.documents, privacy: .public) pages, \(export.counts.facts, privacy: .public) facts"
        )
        return archive
    }

    // MARK: Formatting

    private func page(_ document: DataExport.DocumentRecord, titled: Bool) -> String {
        var output = ""
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titled {
            output += "\n### \(title.isEmpty ? "Untitled" : ConversationExporter.escapeHeading(title))\n"
        }
        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            output += "\n\(body)\n"
        }
        if !document.collectionItems.isEmpty {
            output += "\n"
            for (index, item) in document.collectionItems.enumerated() {
                output += "\(index + 1). \(Self.oneLine(item.prompt))\n"
                if let answer = item.referenceAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !answer.isEmpty
                {
                    output += "   - Answer: \(Self.oneLine(answer))\n"
                }
                if item.practiceCount > 0 {
                    output += "   - Practiced \(Self.plural(item.practiceCount, "time"))"
                    if let last = item.lastPracticedAt { output += ", last \(format(last, time: false))" }
                    output += "\n"
                }
            }
        }
        return output
    }

    private func sinceSuffix(_ fact: DataExport.FactRecord) -> String {
        guard fact.validFrom > .distantPast else { return "" }
        return " (since \(format(fact.validFrom, time: false)))"
    }

    private func spanSuffix(_ fact: DataExport.FactRecord) -> String {
        guard let end = fact.invalidatedAt else { return sinceSuffix(fact) }
        guard fact.validFrom > .distantPast else { return " (until \(format(end, time: false)))" }
        return " (\(format(fact.validFrom, time: false)) – \(format(end, time: false)))"
    }

    private func format(_ date: Date, time: Bool) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// One line, so a value can't break a list item.
    static func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural ?? singular + "s")"
    }
}

/// Zips a folder with Foundation alone: `NSFileCoordinator`'s `.forUploading`
/// reading option hands the accessor a zip archive of a directory (iOS 8+,
/// macOS 10.10+), so Blau needs no compression library.
public enum DataExportArchiver {
    public enum ArchiveError: Error, Equatable {
        /// The coordinator didn't produce an archive.
        case noArchive
    }

    /// Zips `folder` (the archive holds the folder itself, so it unzips to
    /// one folder) into `destination`, replacing a file already there.
    public static func zip(_ folder: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var coordinationError: NSError?
        var copyError: (any Error)?
        var produced = false
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) {
            zipped in
            do {
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                // The coordinator deletes its temporary archive when the
                // accessor returns, so copy it out now.
                try fileManager.copyItem(at: zipped, to: destination)
                #if os(iOS)
                    // The copy gets the default protection class; the zip
                    // holds everything, so it is unreadable while the
                    // iPhone is locked, like the files it was made from.
                    try fileManager.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: destination.path(percentEncoded: false))
                #endif
                produced = true
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard produced else { throw ArchiveError.noArchive }
    }
}
