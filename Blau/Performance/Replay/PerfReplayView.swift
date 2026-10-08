import BlauTranscription
import SwiftUI

extension View {
    /// In Debug builds and builds with the `BLAU_PERF` condition (`make
    /// perf`), shows the scripted-session replay screen instead of the app
    /// when it is launched with `BLAU_PERF_REPLAY=1`, as `BlauPerfTests`
    /// does. Does nothing otherwise, and isn't compiled into App Store
    /// builds.
    ///
    /// - Parameter models: The speech models, for replays on the installed
    ///   Parakeet models (`BLAU_PERF_REPLAY_ASR=parakeet`).
    func perfReplayEntry(models: ModelManager) -> some View {
        #if DEBUG || BLAU_PERF
            modifier(PerfReplayEntry(models: models))
        #else
            self
        #endif
    }
}

#if DEBUG || BLAU_PERF
    /// Accessibility identifiers the perf tests drive the screen with.
    enum PerfReplayAccessibility {
        static let start = "blau.perf.replay.start"
        static let status = "blau.perf.replay.status"
        static let summary = "blau.perf.replay.summary"
    }

    /// Runs replays one at a time and publishes their status.
    @MainActor
    @Observable
    final class PerfReplayController {
        enum Status: Equatable {
            case idle
            case running(Int)
            case finished(Int)
            case failed(Int, String)

            /// What the status label shows: `idle`, `running 2`,
            /// `finished 2` or `failed 2: <reason>`. The tests wait for it.
            var label: String {
                switch self {
                case .idle: "idle"
                case .running(let run): "running \(run)"
                case .finished(let run): "finished \(run)"
                case .failed(let run, let reason): "failed \(run): \(reason)"
                }
            }
        }

        let configuration: PerfReplayConfiguration
        private(set) var status = Status.idle
        private(set) var report: PerfReplayReport?
        private var runs = 0

        init(configuration: PerfReplayConfiguration = PerfReplayConfiguration()) {
            self.configuration = configuration
        }

        var isRunning: Bool {
            if case .running = status { true } else { false }
        }

        /// Starts the next replay. Each one builds its whole pipeline and
        /// temporary stores, and releases them when it ends.
        func start(models: ModelManager) {
            guard !isRunning else { return }
            runs += 1
            let run = runs
            status = .running(run)
            let parakeet = configuration.recognizer == .parakeet
            let replay = PerfReplay(
                configuration: configuration,
                vadModelDirectory: parakeet ? models.directory(for: .sileroVAD) : nil,
                asrModelDirectory: parakeet ? models.directory(for: .parakeetRealtimeEOU) : nil)
            Task {
                do {
                    report = try await replay.run()
                    status = .finished(run)
                } catch {
                    status = .failed(run, String(describing: error))
                }
            }
        }
    }

    /// The replay screen: a start button, the status and the last run's
    /// summary. Deliberately plain: it exists for the perf tests.
    struct PerfReplayView: View {
        let models: ModelManager
        @State private var controller = PerfReplayController()

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scripted session replay")
                    .font(.headline)
                Text(configurationDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Start replay") {
                    controller.start(models: models)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning)
                .accessibilityIdentifier(PerfReplayAccessibility.start)
                Text(controller.status.label)
                    .monospaced()
                    .accessibilityIdentifier(PerfReplayAccessibility.status)
                Text(controller.report?.summary ?? "No run yet")
                    .font(.footnote)
                    .accessibilityIdentifier(PerfReplayAccessibility.summary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                // Parakeet runs read the installed models; nothing else in
                // the app starts the model manager on this screen.
                if controller.configuration.recognizer == .parakeet {
                    await models.start()
                }
            }
        }

        private var configurationDescription: String {
            let configuration = controller.configuration
            let speed = configuration.speed.map { "\($0.formatted())x" } ?? "max speed"
            return
                "\(Int(configuration.duration.timeInterval)) s session at \(speed), \(configuration.recognizer.rawValue) ASR"
        }
    }

    /// Replaces the whole app with the replay screen when requested, so no
    /// other screen (onboarding, the main screen) and none of the app's
    /// launch work runs alongside the measured sessions.
    private struct PerfReplayEntry: ViewModifier {
        let models: ModelManager
        private let isRequested = PerfReplayConfiguration.isRequested()

        func body(content: Content) -> some View {
            if isRequested {
                PerfReplayView(models: models)
            } else {
                content
            }
        }
    }
#endif
