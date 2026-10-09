import BlauTelemetry
import BlauTranscription
import SwiftUI

extension View {
    /// In Debug builds and builds with the `BLAU_PERF` condition (`make
    /// soak`), shows the long-session soak screen (#76) instead of the app
    /// when it is launched with `BLAU_SOAK=1`, as `SoakTests` does. Does
    /// nothing otherwise, and isn't compiled into App Store builds.
    ///
    /// - Parameter models: The speech models, for soaks on the installed
    ///   Parakeet models (`BLAU_SOAK_ASR=parakeet`).
    func soakEntry(models: ModelManager) -> some View {
        #if DEBUG || BLAU_PERF
            modifier(SoakEntry(models: models))
        #else
            self
        #endif
    }
}

#if DEBUG || BLAU_PERF

    /// Accessibility identifiers `SoakTests` drives the screen with.
    enum SoakAccessibility {
        /// Disabled until the models a Parakeet soak needs are installed.
        static let start = "blau.soak.start"
        /// Which installed models a Parakeet soak is still waiting for.
        static let models = "blau.soak.models"
        /// `idle`, `running`, `passed`, `failed: <checks>` or
        /// `error: <reason>`.
        static let status = "blau.soak.status"
        static let progress = "blau.soak.progress"
        /// The one-line summary; its accessibility value holds the whole
        /// report as JSON, which the test attaches to its result.
        static let report = "blau.soak.report"
        static let markdown = "blau.soak.markdown"
    }

    /// Runs one soak and publishes its progress and report.
    @MainActor
    @Observable
    final class SoakController {
        enum Status: Equatable {
            case idle
            case running
            case finished(passed: Bool, failures: [String])
            case error(String)

            var label: String {
                switch self {
                case .idle: "idle"
                case .running: "running"
                case .finished(true, _): "passed"
                case .finished(false, let failures): "failed: \(failures.joined(separator: ", "))"
                case .error(let reason): "error: \(reason)"
                }
            }
        }

        let configuration: SoakConfiguration
        private(set) var status = Status.idle
        private(set) var progress: SoakProgress?
        private(set) var report: SoakReport?
        private(set) var reportJSON = ""
        private(set) var reportURL: URL?

        init(configuration: SoakConfiguration = SoakConfiguration()) {
            self.configuration = configuration
        }

        var isRunning: Bool { status == .running }

        /// The installed models a run needs and doesn't have yet: Silero and
        /// Parakeet for a Parakeet soak, nothing for the scripted one.
        func missingModels(_ models: ModelManager) -> [String] {
            guard configuration.recognizer == .parakeet else { return [] }
            return [
                models.directory(for: .sileroVAD) == nil ? "Silero VAD" : nil,
                models.directory(for: .parakeetRealtimeEOU) == nil ? "Parakeet EOU" : nil,
            ].compactMap { $0 }
        }

        /// Starts a run. A Parakeet run whose models aren't installed ends
        /// at once in `error` (`SoakRun.SetupError.modelsMissing`); the
        /// screen keeps Start disabled until they are.
        func start(models: ModelManager) {
            guard !isRunning else { return }
            status = .running
            progress = nil
            report = nil
            reportJSON = ""
            SoakReportStore.clearLatest()
            let parakeet = configuration.recognizer == .parakeet
            let run = SoakRun(
                configuration: configuration,
                vadModelDirectory: parakeet ? models.directory(for: .sileroVAD) : nil,
                asrModelDirectory: parakeet ? models.directory(for: .parakeetRealtimeEOU) : nil,
                progress: { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                })
            Task {
                do {
                    let report = try await run.run()
                    self.report = report
                    reportJSON = String(decoding: try report.jsonData(), as: UTF8.self)
                    do {
                        reportURL = try SoakReportStore.save(report)
                    } catch {
                        Log.performance.error(
                            "Soak: couldn't save the report: \(String(describing: error), privacy: .public)")
                    }
                    status = .finished(passed: report.passed, failures: report.failures)
                } catch {
                    status = .error(String(describing: error))
                }
            }
        }
    }

    /// The soak screen: a start button, progress, and the verdict with the
    /// checks. Deliberately plain: it exists for `SoakTests` and for a
    /// device run started by hand.
    struct SoakView: View {
        let models: ModelManager
        @State private var controller = SoakController()

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Long-session soak")
                        .font(.headline)
                    Text(controller.configuration.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    let missing = controller.missingModels(models)
                    Button("Start soak") {
                        controller.start(models: models)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning || !missing.isEmpty)
                    .accessibilityIdentifier(SoakAccessibility.start)
                    if !missing.isEmpty {
                        Text("Waiting for the installed speech models: \(missing.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(SoakAccessibility.models)
                    }
                    Text(controller.status.label)
                        .monospaced()
                        .accessibilityIdentifier(SoakAccessibility.status)
                    if let progress = controller.progress {
                        ProgressView(value: progress.fraction) {
                            Text(progressText(progress))
                                .font(.footnote)
                                .monospacedDigit()
                        }
                        .accessibilityIdentifier(SoakAccessibility.progress)
                    }
                    if let report = controller.report {
                        Text(report.summary)
                            .font(.footnote)
                            .accessibilityIdentifier(SoakAccessibility.report)
                            .accessibilityValue(controller.reportJSON)
                        ForEach(report.checks, id: \.name) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(check.name, systemImage: check.passed ? "checkmark.circle" : "xmark.octagon")
                                    .foregroundStyle(check.passed ? .green : .red)
                                Text("\(check.measured) (\(check.limit))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(report.markdown)
                            .font(.caption2)
                            .monospaced()
                            .lineLimit(3)
                            .accessibilityIdentifier(SoakAccessibility.markdown)
                            .accessibilityValue(report.markdown)
                        if let url = controller.reportURL {
                            ShareLink("Share JSON report", item: url)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task {
                if controller.configuration.recognizer == .parakeet {
                    await models.start()
                }
            }
        }

        private func progressText(_ progress: SoakProgress) -> String {
            let sample = progress.latest
            let footprint = sample.footprintBytes.map { " · \(Int($0.megabytes.rounded())) MB" } ?? ""
            return "\(Int(progress.audioSeconds / 60)) of \(Int(progress.totalSeconds / 60)) min · "
                + "\(sample.agentReplies) replies · \(sample.rollovers) renewed\(footprint)"
        }
    }

    /// Replaces the whole app with the soak screen when requested, so none
    /// of the app's own launch work runs alongside the soak.
    private struct SoakEntry: ViewModifier {
        let models: ModelManager
        private let isRequested = SoakConfiguration.isRequested()

        func body(content: Content) -> some View {
            if isRequested {
                SoakView(models: models)
            } else {
                content
            }
        }
    }
#endif
