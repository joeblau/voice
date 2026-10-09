import BlauTelemetry
import Foundation
import Testing

@Suite("Canonical pipeline intervals")
struct PipelineIntervalTests {
    static let names = PipelineInterval.allCases.map(\.name.description)

    @Test func coversTheDocumentedStages() {
        #expect(
            Self.names == [
                "capture.frame", "vad.chunk", "asr.chunk", "asr.eou", "asr.secondPass", "model.download",
                "model.warmUp", "voiceid.embed", "voiceid.verify", "voiceid.gate", "voiceid.language",
                "realtime.turn",
                "realtime.firstAudio",
                "realtime.connect", "realtime.event", "playback.firstBuffer", "topics.segment", "topics.label",
                "memory.embed", "memory.search", "memory.extract", "memory.consolidate", "db.save",
                "session.start", "timeline.expand",
            ]
        )
    }

    @Test func namesAreUnique() {
        #expect(Set(Self.names).count == Self.names.count)
    }

    /// `<stage>.<step>`: a lowercase stage, a dot, a lower camel case step.
    @Test(arguments: PipelineInterval.allCases)
    func nameFollowsTheConvention(interval: PipelineInterval) throws {
        let parts = interval.name.description.split(separator: ".", omittingEmptySubsequences: false)
        try #require(parts.count == 2, "\(interval.name)")
        let stage = parts[0]
        let step = parts[1]
        #expect(!stage.isEmpty && stage.allSatisfy { $0.isASCII && $0.isLowercase }, "\(interval.name)")
        #expect(step.first?.isLowercase == true, "\(interval.name)")
        #expect(step.allSatisfy { $0.isASCII && $0.isLetter }, "\(interval.name)")
    }

    @Test func categoriesMatchTheOwningSubsystem() {
        let categories = Dictionary(
            uniqueKeysWithValues: PipelineInterval.allCases.map { ($0.name.description, $0.category) })
        #expect(categories["capture.frame"] == .audio)
        #expect(categories["vad.chunk"] == .asr)
        #expect(categories["asr.chunk"] == .asr)
        #expect(categories["asr.eou"] == .asr)
        #expect(categories["model.download"] == .asr)
        #expect(categories["model.warmUp"] == .asr)
        #expect(categories["voiceid.embed"] == .voiceID)
        #expect(categories["voiceid.verify"] == .voiceID)
        #expect(categories["voiceid.gate"] == .voiceID)
        #expect(categories["voiceid.language"] == .voiceID)
        #expect(categories["realtime.turn"] == .realtime)
        #expect(categories["realtime.firstAudio"] == .realtime)
        #expect(categories["realtime.connect"] == .realtime)
        #expect(categories["realtime.event"] == .realtime)
        #expect(categories["playback.firstBuffer"] == .audio)
        #expect(categories["topics.segment"] == .topics)
        #expect(categories["topics.label"] == .topics)
        #expect(categories["memory.embed"] == .memory)
        #expect(categories["memory.search"] == .memory)
        #expect(categories["memory.extract"] == .memory)
        #expect(categories["memory.consolidate"] == .memory)
        #expect(categories["db.save"] == .data)
        #expect(categories["session.start"] == .ui)
        #expect(categories["timeline.expand"] == .ui)
    }

    /// docs/performance.md is the reference people read; it must list exactly
    /// the intervals the code emits, each under the right category.
    @Test func performanceDocListsEveryInterval() throws {
        let doc = try Self.performanceDoc()
        let documented = Self.documentedIntervals(in: doc)

        #expect(Set(documented.keys) == Set(Self.names))
        for interval in PipelineInterval.allCases {
            #expect(
                documented[interval.name.description] == interval.category.rawValue,
                "\(interval.name) should be documented under category `\(interval.category.rawValue)`"
            )
        }
    }

    @Test func performanceDocListsEveryCategory() throws {
        let doc = try Self.performanceDoc()
        for category in LogCategory.allCases {
            #expect(doc.contains("| `\(category.rawValue)` "), "docs/performance.md is missing category \(category)")
        }
    }

    // MARK: Helpers

    /// The repo's docs/performance.md, found relative to this file.
    static func performanceDoc() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()  // BlauTelemetryTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // BlauKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appending(path: "docs/performance.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Rows of the "Canonical intervals" table: interval name to category.
    static func documentedIntervals(in doc: String) -> [String: String] {
        var rows: [String: String] = [:]
        var inSection = false
        for line in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                inSection = line.hasPrefix("## Canonical intervals")
                continue
            }
            guard inSection, line.hasPrefix("| `") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            let unquote = { (cell: String) in cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            rows[unquote(cells[0])] = unquote(cells[1])
        }
        return rows
    }
}
