#if DEBUG || BLAU_BENCHMARKS
    import BlauTelemetry
    import BlauTranscription
    import SwiftUI

    /// The debug-only on-device benchmark screen (#22).
    ///
    /// Runs the model benchmarks on this iPhone and the background Neural
    /// Engine probe, and shares the reports. The numbers that go into
    /// docs/benchmarks.md come from Release runs (`make bench`); this screen
    /// is for the probe, which needs a human to lock the device, and for
    /// quick looks.
    struct BenchmarkView: View {
        @State private var model = BenchmarkViewModel()
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    if model.buildConfiguration != "Release" {
                        Section {
                            Label(
                                "\(model.buildConfiguration) build: Swift code runs unoptimized, so ASR numbers "
                                    + "here are pessimistic. Run make bench for the results table.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                        }
                    }
                    suiteSection
                    if let report = model.report {
                        reportSection(report)
                    }
                    probeSection
                }
                .navigationTitle("Benchmarks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        // MARK: Suite

        private var suiteSection: some View {
            Section {
                ForEach($model.entries) { $entry in
                    BenchmarkRow(entry: $entry)
                        .disabled(model.isRunning)
                }
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Button("Run selected") { model.runSelected() }
                        .disabled(model.isProbeRunning || !model.entries.contains(where: \.isSelected))
                }
            } header: {
                Text("Models")
            } footer: {
                Text(
                    "Models download on first run. Keep Blau open and the device cool; the screen stays on while "
                        + "the suite runs.")
            }
        }

        private func reportSection(_ report: BenchmarkReport) -> some View {
            Section("Report") {
                ForEach(model.reportURLs, id: \.self) { url in
                    ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Text(report.markdownSummary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }

        // MARK: Probe

        private var probeSection: some View {
            Section {
                Stepper("Duration: \(model.probeMinutes) min", value: $model.probeMinutes, in: 2...60)
                    .disabled(model.isProbeRunning)
                switch model.probeState {
                case .idle:
                    EmptyView()
                case .running(let status):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status)
                        Text(Self.sampleSummary(model.probeSamples))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .finished(let report, let url):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.analysis.verdict.summary).font(.headline)
                        Text("Mitigation: \(report.mitigation.summary)")
                        Text(Self.analysisSummary(report.analysis))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let url {
                        ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
                if model.isProbeRunning {
                    Button("Stop and analyse", role: .destructive) { model.stopProbe() }
                } else {
                    Button("Start probe") { model.startProbe() }
                        .disabled(model.isRunning)
                }
            } header: {
                Text("Background Neural Engine probe")
            } footer: {
                Text(
                    "Runs Parakeet EOU 320 ms on a live cadence with the microphone on. After the status says "
                        + "Running, use Blau for a minute, then press the side button to lock the device for most "
                        + "of the run (the device needs a passcode). Unlock and come back to see the verdict.")
            }
        }

        private static func sampleSummary(_ samples: [InferenceSample]) -> String {
            guard let last = samples.last else { return "No samples yet" }
            let latency = last.latencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? (last.error ?? "error")
            let counts = ExecutionPhase.allCases.map { phase in
                "\(phase.rawValue) \(samples.count { $0.phase == phase })"
            }
            return "\(samples.count) samples · last \(latency) · " + counts.joined(separator: " · ")
        }

        private static func analysisSummary(_ analysis: BackgroundInferenceAnalysis) -> String {
            func p50(_ summary: LatencySummary?) -> String {
                summary.map { "\(Int($0.p50.rounded())) ms" } ?? "–"
            }
            var parts = [
                "foreground p50 \(p50(analysis.foreground))",
                "background p50 \(p50(analysis.background))",
                "locked p50 \(p50(analysis.locked))",
                "CPU-only p50 \(p50(analysis.cpuBaseline))",
                "background errors \(analysis.backgroundErrorCount)",
            ]
            if let coverage = analysis.backgroundCoverage {
                parts.append("coverage \(Int((coverage * 100).rounded()))%")
            }
            if let listed = analysis.neuralEngineListedInBackground {
                parts.append("ANE listed off screen: \(listed ? "yes" : "no")")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// One case: a selection toggle, its progress while running, and its
    /// numbers when done.
    private struct BenchmarkRow: View {
        @Binding var entry: BenchmarkViewModel.Entry

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(entry.title, isOn: $entry.isSelected)
                    .font(.body)
                switch entry.state {
                case .idle:
                    EmptyView()
                case .waiting:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .running(let fraction, let message):
                    if let fraction {
                        ProgressView(value: fraction) { Text(message).font(.caption) }
                    } else {
                        ProgressView { Text(message).font(.caption) }
                    }
                case .finished(let result):
                    Text(Self.summary(result))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(result.outcome.isCompleted ? Color.secondary : Color.red)
                }
            }
            .accessibilityElement(children: .combine)
        }

        static func summary(_ result: BenchmarkResult) -> String {
            switch result.outcome {
            case .skipped(let reason): return "Skipped: \(reason)"
            case .failed(let message): return "Failed: \(message)"
            case .completed:
                var parts = result.metrics.map { "\($0.key) \($0.formatted)" }
                for key in result.latencies.keys.sorted() {
                    guard let summary = result.latencies[key] else { continue }
                    parts.append("\(key) p50 \(Int(summary.p50.rounded())) / p95 \(Int(summary.p95.rounded())) ms")
                }
                if result.wasThrottled { parts.append("thermally throttled") }
                return parts.joined(separator: "\n")
            }
        }
    }

    #Preview {
        BenchmarkView()
    }
#endif
