import BlauTelemetry
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings → Developer → Latency Budget (#74): every turn measured since
/// launch against the latency budget, hop by hop, with the audio route's
/// hardware latency, a JSON export and the Markdown row docs/performance.md
/// records per release.
///
/// Pushed from Settings → Developer, so it has no navigation stack of its
/// own. It reads `LatencyBudgetTracker.shared`, which the turn orchestrator
/// records to; it is in every build, TestFlight included.
struct LatencyBudgetView: View {
    enum Identifier {
        /// The Settings row that opens this screen.
        static let open = "settings.developer.latencyBudget"
        static let view = "latencyBudget.view"
        static let turns = "latencyBudget.turns"
        static let export = "latencyBudget.export"
        static let copyRow = "latencyBudget.copyRow"
        static let reset = "latencyBudget.reset"
    }

    var tracker: LatencyBudgetTracker = .shared
    /// How often the screen picks up new turns while it is open.
    var refreshInterval: Duration = .seconds(2)

    @State private var report: LatencyBudgetReport?
    @State private var copiedRow = false
    @State private var confirmingReset = false

    var body: some View {
        List {
            if let report, report.turnCount > 0 {
                summarySection(report)
                hopsSection(report)
                hardwareSection(report)
                turnsSection(report)
            } else {
                emptySection
            }
            actionSection
        }
        .accessibilityIdentifier(Identifier.view)
        .navigationTitle("Latency Budget")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
        .refreshable { refresh() }
        .confirmationDialog(
            "Forget the measured turns?", isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                tracker.reset()
                refresh()
            }
        } message: {
            Text("Reset before measuring a release, so the report covers only that session.")
        }
    }

    private func refresh() {
        report = tracker.report(context: AppDiagnostics.exportContext())
    }

    // MARK: Sections

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label("No Turns Yet", systemImage: "stopwatch")
            } description: {
                Text(
                    "Every reply Grok speaks is measured from the end of what you said to its first sound. "
                        + "Hold a conversation, then come back.")
            }
        }
    }

    private func summarySection(_ report: LatencyBudgetReport) -> some View {
        Section {
            LabeledContent("Turns", value: report.turnCount.formatted())
                .accessibilityIdentifier(Identifier.turns)
            LabeledContent("Verdict") {
                Text(Self.verdict(report))
                    .foregroundStyle(report.isWithinBudget == false ? .red : .primary)
            }
        } footer: {
            Text("Within budget when every hop's median is at or below its target. See docs/performance.md.")
        }
    }

    private func hopsSection(_ report: LatencyBudgetReport) -> some View {
        Section("Hops (p50 / p95)") {
            ForEach(report.hops, id: \.hop) { hop in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(hop.hop.title)
                        Spacer()
                        Text(Self.percentiles(hop.summary))
                            .monospacedDigit()
                            .foregroundStyle(hop.isWithinBudget == false ? .red : .primary)
                    }
                    Text("Target \(hop.target.description)" + (hop.summary.map { " · n=\($0.count)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let acoustic = report.acousticTotal {
                LabeledContent("With hardware I/O") {
                    Text(Self.percentiles(acoustic)).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func hardwareSection(_ report: LatencyBudgetReport) -> some View {
        Section {
            if let hardware = report.hardware {
                LabeledContent("Route", value: hardware.route)
                LabeledContent("Input latency", value: Self.milliseconds(hardware.inputMilliseconds))
                LabeledContent("Output latency", value: Self.milliseconds(hardware.outputMilliseconds))
                LabeledContent("I/O buffer", value: Self.milliseconds(hardware.ioBufferMilliseconds))
            }
            if report.routes.count > 1 {
                LabeledContent("Routes measured", value: report.routes.joined(separator: ", "))
            }
        } header: {
            Text("Audio hardware")
        } footer: {
            Text(
                "AVAudioSession's input and output latency, which the signposts can't see. "
                    + "Measure a release on the built-in microphone and speaker.")
        }
    }

    private func turnsSection(_ report: LatencyBudgetReport) -> some View {
        Section("Recent turns") {
            ForEach(report.turns.suffix(20).reversed(), id: \.self) { turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.totalMilliseconds.map { Self.milliseconds($0) } ?? "–").monospacedDigit()
                    Text(turn.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actionSection: some View {
        Section {
            if let report, report.turnCount > 0 {
                ShareLink(
                    item: LatencyReportFile(report: report),
                    preview: SharePreview("Blau latency report", image: Image(systemName: "stopwatch"))
                ) {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(Identifier.export)

                Button {
                    UIPasteboard.general.string = report.markdownRow
                    copiedRow = true
                } label: {
                    Label(copiedRow ? "Copied" : "Copy Table Row", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier(Identifier.copyRow)
            }
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(report?.turnCount ?? 0 == 0)
            .accessibilityIdentifier(Identifier.reset)
        } footer: {
            Text(
                "Turns are kept in memory until the app quits: timings and the audio route only, never what was said.")
        }
    }

    // MARK: Formatting

    static func verdict(_ report: LatencyBudgetReport) -> String {
        switch report.isWithinBudget {
        case nil: "–"
        case true?: "Within budget"
        case false?: "Over budget: " + report.hopsOverBudget.map(\.title).joined(separator: ", ")
        }
    }

    static func percentiles(_ summary: LatencySummary?) -> String {
        guard let summary else { return "–" }
        return "\(Int(summary.p50.rounded())) / \(Int(summary.p95.rounded())) ms"
    }

    static func milliseconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) ms"
    }
}

/// The latency report as a share-sheet item: one JSON file
/// (`LatencyBudgetReport.write(to:)`).
struct LatencyReportFile: Transferable, Sendable {
    let report: LatencyBudgetReport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "LatencyExport-\(UUID().uuidString)", directoryHint: .isDirectory)
            return SentTransferredFile(try file.report.write(to: folder))
        }
    }
}

#if DEBUG
    #Preview("Measured turns") {
        let tracker = LatencyBudgetTracker()
        for turn in 1...12 {
            tracker.record(
                TurnLatencySample(
                    turn: turn, recordedAt: .now, endOfUtteranceMilliseconds: 600 + Double(turn * 9),
                    voiceGateMilliseconds: 8 + Double(turn), firstAudioMilliseconds: 520 + Double(turn * 31),
                    firstBufferMilliseconds: 40 + Double(turn % 4), totalMilliseconds: 1_180 + Double(turn * 41),
                    hardware: AudioHardwareLatency(
                        inputMilliseconds: 12, outputMilliseconds: 19, ioBufferMilliseconds: 10.7,
                        sampleRate: 48_000, route: "builtInMic -> builtInSpeaker")))
        }
        return NavigationStack {
            LatencyBudgetView(tracker: tracker)
        }
    }

    #Preview("Empty") {
        NavigationStack {
            LatencyBudgetView(tracker: LatencyBudgetTracker())
        }
    }
#endif
