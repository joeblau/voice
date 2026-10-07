import BlauTelemetry
import SwiftUI

/// Developer diagnostics: a summary of the MetricKit payloads stored on this
/// device (hangs, memory, stability, launch time, Blau's signposts) and an
/// export of all of them through the share sheet.
///
/// Pushed from Settings → Developer → Diagnostics, so it has no navigation
/// stack of its own; present it inside one.
struct DiagnosticsView: View {
    enum Identifier {
        /// The Settings row that opens this screen.
        static let open = "settings.developer.diagnostics"
        static let view = "diagnostics.view"
        static let export = "diagnostics.export"
        static let addSamples = "diagnostics.addSamples"
        static let deleteAll = "diagnostics.deleteAll"
        static let metricPayloads = "diagnostics.metricPayloads"
        static let diagnosticPayloads = "diagnostics.diagnosticPayloads"
        static let hangReports = "diagnostics.hangReports"
        static let peakMemory = "diagnostics.peakMemory"
    }

    @Environment(AppDiagnostics.self) private var diagnostics
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if diagnostics.overview.isEmpty {
                emptySection
            }
            payloadSection
            if !diagnostics.overview.isEmpty {
                hangSection
                memorySection
                stabilitySection
                launchSection
                signpostSection
                recentSection
            }
            actionSection
        }
        .accessibilityIdentifier(Identifier.view)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await diagnostics.refresh() }
        .refreshable { await diagnostics.refresh() }
        .confirmationDialog(
            "Delete all stored MetricKit payloads?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Payloads", role: .destructive) {
                Task { await diagnostics.removeAll() }
            }
        } message: {
            Text("Export them first if you still need them. MetricKit won't deliver them again.")
        }
    }

    // MARK: Sections

    private var overview: DiagnosticsOverview { diagnostics.overview }

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label("No Payloads Yet", systemImage: "waveform.path.ecg")
            } description: {
                Text(
                    "MetricKit delivers metrics about once a day and hang and crash reports at the next launch. "
                        + "Payloads arrive on devices and TestFlight builds, not in the Simulator.")
            }
        }
    }

    private var payloadSection: some View {
        Section("MetricKit") {
            LabeledContent("Collecting", value: diagnostics.isCollecting ? "On" : "Off")
            LabeledContent("Metric payloads", value: overview.metricPayloadCount.formatted())
                .accessibilityIdentifier(Identifier.metricPayloads)
            LabeledContent("Diagnostic payloads", value: overview.diagnosticPayloadCount.formatted())
                .accessibilityIdentifier(Identifier.diagnosticPayloads)
            if !overview.isEmpty {
                LabeledContent("From TestFlight", value: overview.testFlightPayloadCount.formatted())
                if let start = overview.firstPeriodStart, let end = overview.lastPeriodEnd {
                    LabeledContent("Covers") {
                        Text((start..<max(start, end)).formatted(.interval.day().month().year()))
                    }
                }
                if let received = overview.lastReceivedAt {
                    LabeledContent("Last received") { Text(received, format: .relative(presentation: .named)) }
                }
                if let version = overview.latestAppVersion {
                    LabeledContent("Latest app version", value: version)
                }
            }
            if let error = diagnostics.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var hangSection: some View {
        Section {
            LabeledContent("Hang reports", value: overview.hangReportCount.formatted())
                .accessibilityIdentifier(Identifier.hangReports)
            if let longest = overview.longestHangSeconds {
                LabeledContent("Longest reported hang", value: Self.seconds(longest))
            }
            if let hangs = overview.hangTime {
                LabeledContent("Hangs in daily metrics", value: hangs.sampleCount.formatted())
                LabeledContent("Estimated hang time", value: Self.seconds(hangs.estimatedTotal))
                if let p95 = hangs.estimatedQuantile(0.95) {
                    LabeledContent("p95 hang", value: "≤ " + Self.seconds(p95))
                }
            }
        } header: {
            Text("Hangs")
        } footer: {
            Text("Hang reports include call stacks; the daily metrics count every hang over 250 ms.")
        }
    }

    private var memorySection: some View {
        Section("Memory") {
            if let peak = overview.peakMemoryBytes {
                LabeledContent("Peak, all payloads", value: Self.bytes(peak))
                    .accessibilityIdentifier(Identifier.peakMemory)
            }
            if let latest = overview.latestPeakMemoryBytes {
                LabeledContent("Peak, latest day", value: Self.bytes(latest))
            }
            if let suspended = overview.latestAverageSuspendedMemoryBytes {
                LabeledContent("Average while suspended", value: Self.bytes(suspended))
            }
            LabeledContent("Memory terminations", value: overview.memoryExitCount.formatted())
        }
    }

    private var stabilitySection: some View {
        Section("Stability") {
            LabeledContent("Crashes", value: overview.crashCount.formatted())
            ForEach(overview.topCrashes.prefix(5), id: \.label) { crash in
                LabeledContent(crash.label, value: crash.count.formatted())
                    .font(.footnote)
                    .padding(.leading)
            }
            LabeledContent("Unexpected exits", value: overview.unexpectedExitCount.formatted())
            LabeledContent("CPU exceptions", value: overview.cpuExceptionCount.formatted())
            LabeledContent("Disk-write exceptions", value: overview.diskWriteExceptionCount.formatted())
        }
    }

    @ViewBuilder
    private var launchSection: some View {
        if let launch = overview.timeToFirstDraw, launch.sampleCount > 0 || overview.slowLaunchReportCount > 0 {
            Section("Launch") {
                LabeledContent("Launches measured", value: launch.sampleCount.formatted())
                if let median = launch.estimatedQuantile(0.5) {
                    LabeledContent("Time to first draw, median", value: "≤ " + Self.seconds(median))
                }
                if let p95 = launch.estimatedQuantile(0.95) {
                    LabeledContent("Time to first draw, p95", value: "≤ " + Self.seconds(p95))
                }
                LabeledContent("Slow launch reports", value: overview.slowLaunchReportCount.formatted())
            }
        }
    }

    @ViewBuilder
    private var signpostSection: some View {
        if !overview.signposts.isEmpty {
            Section {
                ForEach(overview.signposts, id: \.name) { signpost in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signpost.name).font(.body.monospaced())
                        Text(Self.signpostDetail(signpost))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Signposts")
            } footer: {
                Text("Pipeline intervals Blau reports to MetricKit. See docs/performance.md.")
            }
        }
    }

    private var recentSection: some View {
        Section("Recent payloads") {
            ForEach(diagnostics.records.prefix(20)) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.kind == .metrics ? "Metrics" : "Diagnostics")
                    Text(Self.recordDetail(record))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actionSection: some View {
        Section {
            if let file = diagnostics.exportFile {
                ShareLink(
                    item: file,
                    preview: SharePreview("Blau diagnostics", image: Image(systemName: "waveform.path.ecg"))
                ) {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(Identifier.export)
            }
            #if DEBUG
                Button {
                    Task { await diagnostics.addSamplePayloads() }
                } label: {
                    Label("Add Sample Payloads", systemImage: "plus.circle")
                }
                .accessibilityIdentifier(Identifier.addSamples)
            #endif
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete Stored Payloads", systemImage: "trash")
            }
            .disabled(overview.isEmpty)
            .accessibilityIdentifier(Identifier.deleteAll)
        } footer: {
            Text(
                "Exports one JSON file with every stored payload and its summary. "
                    + "Payloads stay on this device and are not synced to iCloud.")
        }
    }

    // MARK: Formatting

    static func seconds(_ value: Double) -> String {
        if value < 1 {
            return Duration.milliseconds(Int64((value * 1_000).rounded())).formatted(
                .units(allowed: [.milliseconds], width: .abbreviated))
        }
        return value.formatted(.number.precision(.fractionLength(0...2))) + " s"
    }

    static func bytes(_ value: Double) -> String {
        Int64(value).formatted(.byteCount(style: .memory))
    }

    static func signpostDetail(_ signpost: SignpostMetricSummary) -> String {
        var parts = ["\(signpost.totalCount.formatted()) intervals"]
        if let median = signpost.duration?.estimatedQuantile(0.5) {
            parts.append("median ≤ " + seconds(median))
        }
        if let p95 = signpost.duration?.estimatedQuantile(0.95) {
            parts.append("p95 ≤ " + seconds(p95))
        }
        return parts.joined(separator: " · ")
    }

    static func recordDetail(_ record: DiagnosticsRecord) -> String {
        var parts = [
            (record.summary.periodStart..<max(record.summary.periodStart, record.summary.periodEnd))
                .formatted(.interval.day().month().hour().minute())
        ]
        if let version = record.summary.environment.appVersion {
            parts.append(version)
        }
        if record.summary.environment.isTestFlightApp == true {
            parts.append("TestFlight")
        }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
    #Preview("With samples") {
        let diagnostics = AppDiagnostics(
            store: FileDiagnosticsStore(
                directory: URL.temporaryDirectory.appending(path: "DiagnosticsPreview-\(UUID().uuidString)")))
        NavigationStack {
            DiagnosticsView()
        }
        .environment(diagnostics)
        .task { await diagnostics.addSamplePayloads() }
    }

    #Preview("Empty") {
        NavigationStack {
            DiagnosticsView()
        }
        .environment(AppDiagnostics(store: nil))
    }
#endif
