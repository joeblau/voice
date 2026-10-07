#if DEBUG || BLAU_BENCHMARKS
    import BlauAudio
    import BlauTelemetry
    import BlauTranscription
    import Foundation
    import Observation
    import UIKit

    /// Benchmark work in flight, shared by every `BenchmarkViewModel`.
    ///
    /// A run started from a sheet that has since closed is cancelled but
    /// needs a moment to wind down (the current case or model load has to
    /// return). Tracking it here, rather than in the view model the sheet
    /// owned, stops a reopened sheet from starting a second suite or a
    /// second probe (with its own microphone session) on top of it.
    @MainActor
    @Observable
    final class BenchmarkActivity {
        static let shared = BenchmarkActivity()

        fileprivate(set) var isSuiteActive = false
        fileprivate(set) var isProbeActive = false
    }

    /// Drives the debug benchmark screen: runs the selected cases one after
    /// another off the main actor, saves the report, and runs the
    /// background Neural Engine probe.
    @MainActor
    @Observable
    final class BenchmarkViewModel {
        enum CaseState: Equatable {
            case idle
            case waiting
            case running(fraction: Double?, message: String)
            case finished(BenchmarkResult)
        }

        struct Entry: Identifiable {
            let benchmark: any BenchmarkCase
            var isSelected = true
            var state = CaseState.idle

            var id: String { benchmark.id }
            var title: String { benchmark.title }
        }

        enum ProbeState: Equatable {
            case idle
            case running(status: String)
            case finished(BackgroundProbeReport, url: URL?)
            case failed(String)
        }

        var entries: [Entry]
        private(set) var isRunning = false
        private(set) var report: BenchmarkReport?
        private(set) var reportURLs: [URL] = []
        private(set) var errorMessage: String?

        private(set) var probeState = ProbeState.idle
        private(set) var probeSamples: [InferenceSample] = []
        var probeMinutes = 10

        private let audio: AudioFixtureStore
        private let activity: BenchmarkActivity
        private var runTask: Task<Void, Never>?
        private var probeTask: Task<Void, Never>?

        init(
            audio: AudioFixtureStore = BenchmarkCatalog.audioStore(),
            activity: BenchmarkActivity = .shared
        ) {
            self.audio = audio
            self.activity = activity
            entries = BenchmarkCatalog.cases(audio: audio).map { Entry(benchmark: $0) }
        }

        var buildConfiguration: String { BenchmarkCatalog.buildConfiguration }

        var isProbeRunning: Bool {
            if case .running = probeState { true } else { false }
        }

        /// Whether a suite or a probe is in flight anywhere, including one
        /// from a closed sheet that is still stopping.
        var isBusy: Bool { activity.isSuiteActive || activity.isProbeActive || isRunning || isProbeRunning }

        /// Whether work from a previously closed sheet is still stopping.
        var isPreviousRunStopping: Bool { isBusy && !isRunning && !isProbeRunning }

        /// Cancels this screen's suite and probe. The screen calls it when it
        /// goes away, so neither keeps running (with the idle timer off, or
        /// the microphone on) with no UI to stop it. Each task still finishes
        /// its cleanup: the suite turns the idle timer back on, the probe
        /// stops its audio session.
        func cancelAll() {
            runTask?.cancel()
            probeTask?.cancel()
        }

        // MARK: Suite

        func runSelected() {
            guard !isBusy else { return }
            let selected = entries.filter(\.isSelected).map(\.benchmark)
            guard !selected.isEmpty else { return }
            for index in entries.indices {
                entries[index].state = entries[index].isSelected ? .waiting : .idle
            }
            isRunning = true
            errorMessage = nil
            report = nil
            reportURLs = []
            // A locked screen would background the app mid-run.
            UIApplication.shared.isIdleTimerDisabled = true
            activity.isSuiteActive = true
            let activity = activity

            runTask = Task { [weak self] in
                // Runs even if the screen (and `self`) went away mid-run.
                defer {
                    activity.isSuiteActive = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                let runner = BenchmarkRunner { progress in
                    Task { @MainActor in self?.apply(progress) }
                }
                var report = BenchmarkReport(
                    device: .current, startedAt: .now, results: [],
                    buildConfiguration: BenchmarkCatalog.buildConfiguration)
                for benchmark in selected {
                    if Task.isCancelled { break }
                    self?.setState(.running(fraction: nil, message: "Starting"), for: benchmark.id)
                    // Detached so no benchmark work runs on the main actor.
                    let work = Task.detached(priority: .userInitiated) { await runner.run(benchmark) }
                    let result = await withTaskCancellationHandler {
                        await work.value
                    } onCancel: {
                        work.cancel()
                    }
                    report.merge(result)
                    self?.setState(.finished(result), for: benchmark.id)
                }
                self?.complete(report)
            }
        }

        func cancel() {
            runTask?.cancel()
        }

        private func apply(_ progress: BenchmarkProgress) {
            guard let index = entries.firstIndex(where: { $0.id == progress.benchmarkID }),
                case .running = entries[index].state
            else { return }
            entries[index].state = .running(fraction: progress.fraction, message: progress.message)
        }

        private func setState(_ state: CaseState, for id: String) {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].state = state
        }

        private func complete(_ report: BenchmarkReport) {
            for index in entries.indices where entries[index].state == .waiting {
                entries[index].state = .idle
            }
            self.report = report
            isRunning = false
            runTask = nil
            do {
                let base = (report.suggestedFileName as NSString).deletingPathExtension
                reportURLs = [
                    try BenchmarkCatalog.save(report.jsonData(), named: "\(base).json"),
                    try BenchmarkCatalog.save(Data(report.markdownSummary.utf8), named: "\(base).md"),
                ]
            } catch {
                errorMessage = "Could not save the report: \(error.localizedDescription)"
            }
        }

        // MARK: Background probe

        func startProbe() {
            guard !isBusy else { return }
            probeSamples = []
            probeState = .running(status: "Starting")
            let configuration = BackgroundInferenceProbe.Configuration(duration: .seconds(probeMinutes * 60))
            let audio = audio
            activity.isProbeActive = true
            let activity = activity

            probeTask = Task { [weak self] in
                // Declared first so it runs last, after the audio stops.
                defer { activity.isProbeActive = false }
                let keepAlive = BackgroundAudioKeepAlive()
                do {
                    try await keepAlive.start()
                } catch {
                    self?.probeState = .failed(String(describing: error))
                    return
                }
                defer { keepAlive.stop() }
                let phases = ApplicationExecutionPhaseProvider()
                let probe = BackgroundInferenceProbe.parakeetEou(
                    .ms320, phases: phases, audio: audio, configuration: configuration)
                let work = Task.detached(priority: .userInitiated) {
                    try await probe.run(
                        onStatus: { status in Task { @MainActor in self?.probeStatusChanged(status) } },
                        onSample: { sample in Task { @MainActor in self?.probeSamples.append(sample) } }
                    )
                }
                do {
                    let report = try await withTaskCancellationHandler {
                        try await work.value
                    } onCancel: {
                        work.cancel()
                    }
                    let name =
                        "background-probe-\(report.startedAt.formatted(.iso8601))-\(report.device.modelIdentifier).json"
                        .replacingOccurrences(of: ":", with: "-")
                    let url = try? BenchmarkCatalog.save(report.jsonData(), named: name)
                    self?.probeState = .finished(report, url: url)
                } catch {
                    self?.probeState = .failed(BenchmarkRunner.describe(error))
                }
            }
        }

        /// Ends the live run early; the samples so far are analysed.
        func stopProbe() {
            probeTask?.cancel()
        }

        private func probeStatusChanged(_ status: String) {
            if case .running = probeState {
                probeState = .running(status: status)
            }
        }
    }
#endif
