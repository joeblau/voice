import Foundation

/// A session's turns measured against the latency budget (#74): p50 and p95
/// for every hop, the budget verdict, the audio hardware's latency and the
/// raw turns. Exported as JSON from Settings → Developer → Latency Budget;
/// `markdownRow` is the line docs/performance.md records per release and
/// device.
public struct LatencyBudgetReport: Codable, Sendable, Hashable {
    /// The export file format; bump when its shape changes.
    public static let exportFormat = "com.joeblau.blau.latency.v1"

    /// One hop's statistics.
    public struct HopSummary: Codable, Sendable, Hashable {
        public var hop: LatencyHop
        public var target: LatencyBudget.Target
        /// Order statistics over the turns that measured the hop, in
        /// milliseconds. `nil` when none did.
        public var summary: LatencySummary?
        /// Whether the p50 is within the target; `nil` without samples.
        public var isWithinBudget: Bool?

        public init(hop: LatencyHop, target: LatencyBudget.Target, summary: LatencySummary?) {
            self.hop = hop
            self.target = target
            self.summary = summary
            isWithinBudget = summary.map { $0.p50 <= target.p50Milliseconds }
        }
    }

    public var format: String
    public var generatedAt: Date
    public var context: DiagnosticsExportContext
    public var budget: LatencyBudget
    /// One summary per hop, in `LatencyHop` order.
    public var hops: [HopSummary]
    /// The total plus the hardware's input and output latency, over turns
    /// that know their route's latency: end of speech at the microphone →
    /// the reply's first sound at the speaker.
    public var acousticTotal: LatencySummary?
    /// The audio routes the turns ran on (port kinds), most frequent first.
    public var routes: [String]
    /// The hardware latency when the report was made.
    public var hardware: AudioHardwareLatency?
    /// Every turn, oldest first.
    public var turns: [TurnLatencySample]

    public init(
        samples: [TurnLatencySample], budget: LatencyBudget = .standard, context: DiagnosticsExportContext,
        hardware: AudioHardwareLatency? = nil, generatedAt: Date = .now
    ) {
        format = Self.exportFormat
        self.generatedAt = generatedAt
        self.context = context
        self.budget = budget
        hops = LatencyHop.allCases.map { hop in
            HopSummary(
                hop: hop, target: budget[hop],
                summary: LatencySummary(milliseconds: samples.compactMap { $0.milliseconds(for: hop) }))
        }
        acousticTotal = LatencySummary(milliseconds: samples.compactMap(\.acousticTotalMilliseconds))
        var routeCounts: [String: Int] = [:]
        for route in samples.compactMap(\.hardware?.route) {
            routeCounts[route, default: 0] += 1
        }
        routes = routeCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        self.hardware = hardware
        turns = samples
    }

    /// The summary of `hop`.
    public func summary(for hop: LatencyHop) -> HopSummary? {
        hops.first { $0.hop == hop }
    }

    /// How many turns the report covers.
    public var turnCount: Int { turns.count }

    /// Whether every measured hop's p50 is within budget; `nil` when no hop
    /// was measured.
    public var isWithinBudget: Bool? {
        let verdicts = hops.compactMap(\.isWithinBudget)
        return verdicts.isEmpty ? nil : verdicts.allSatisfy { $0 }
    }

    /// The hops over budget.
    public var hopsOverBudget: [LatencyHop] {
        hops.filter { $0.isWithinBudget == false }.map(\.hop)
    }

    // MARK: Per-release table

    /// The header of the per-release table in docs/performance.md.
    public static let markdownHeader = """
        | Release | Device | OS | Route | Turns | EOU p50 / p95 | Gate p50 / p95 | First audio p50 / p95 | First buffer p50 / p95 | Total p50 / p95 | + hardware I/O p50 / p95 | Budget | Date |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        """

    /// This report as one row of the per-release table: milliseconds, p50 /
    /// p95 per hop, "within" or the hops over budget.
    public var markdownRow: String {
        let release = [context.appVersion, context.appBuild.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
        let budgetCell: String =
            switch isWithinBudget {
            case nil: "–"
            case true?: "within"
            case false?: "over: " + hopsOverBudget.map(\.rawValue).joined(separator: ", ")
            }
        let cells =
            [
                release.isEmpty ? "–" : release,
                context.deviceModel ?? "–",
                context.osVersion.map(Self.shortOSVersion) ?? "–",
                routes.first.map { "`\($0)`" } ?? "–",
                "\(turnCount)",
            ] + LatencyHop.allCases.map { Self.percentiles(summary(for: $0)?.summary) } + [
                Self.percentiles(acousticTotal),
                budgetCell,
                generatedAt.formatted(Self.dateStamp),
            ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    /// `640 / 820`, or `–`.
    static func percentiles(_ summary: LatencySummary?) -> String {
        guard let summary else { return "–" }
        return "\(Int(summary.p50.rounded())) / \(Int(summary.p95.rounded()))"
    }

    /// `Version 26.1 (Build 23B85)` → `26.1 (23B85)`.
    static func shortOSVersion(_ version: String) -> String {
        version.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
    }

    private static let dateStamp = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    // MARK: Export

    /// The JSON export: pretty-printed with sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads an export back.
    public static func decode(_ data: Data) throws -> LatencyBudgetReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LatencyBudgetReport.self, from: data)
    }

    /// `Blau-Latency-20261009-120000.json` (UTC).
    public static func fileName(generatedAt: Date) -> String {
        "Blau-Latency-\(generatedAt.formatted(fileStamp)).json"
    }

    /// Writes the export into `directory` and returns the file.
    public func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(generatedAt: generatedAt))
        try encoded().write(to: url, options: .atomic)
        return url
    }

    private static let fileStamp = Date.VerbatimFormatStyle(
        format:
            "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )
}
