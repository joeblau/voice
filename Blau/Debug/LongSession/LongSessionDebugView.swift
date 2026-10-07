#if DEBUG
    import BlauAudio
    import BlauTranscription
    import SwiftUI

    /// The accessibility identifiers for the long-session screen.
    enum LongSessionAccessibility {
        static let openLink = "blau.debug.longSession"
        static let startButton = "blau.debug.longSession.start"
        static let stopButton = "blau.debug.longSession.stop"
    }

    /// Runs the 30-minute locked-screen soak test on a device and shows
    /// what the conversation audio, the VAD and background inference are
    /// doing (#26, docs/background.md). DEBUG builds only.
    struct LongSessionDebugView: View {
        @Environment(AppEnvironment.self) private var environment
        @State private var soak = LongSessionSoak()

        var body: some View {
            Form {
                controlSection
                if let keeper = soak.keeper {
                    audioSection(keeper)
                }
                if let inference = soak.inference, !inference.stages.isEmpty || !inference.switches.isEmpty {
                    inferenceSection(inference)
                }
                if let vad = soak.vad {
                    vadSection(vad)
                }
                if let capture = soak.capture {
                    captureSection(capture)
                }
                if let report = soak.report {
                    reportSection(report)
                }
            }
            .navigationTitle("Long session")
            .navigationBarTitleDisplayMode(.inline)
        }

        private var controlSection: some View {
            Section {
                if soak.isRunning {
                    Button("Stop and report", systemImage: "stop.circle", role: .destructive) {
                        Task { await soak.stop(environment) }
                    }
                    .accessibilityIdentifier(LongSessionAccessibility.stopButton)
                } else {
                    Button("Start session", systemImage: "mic.circle") {
                        Task { await soak.start(environment) }
                    }
                    .accessibilityIdentifier(LongSessionAccessibility.startButton)
                }
                if let error = soak.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(
                    "Start, talk for a minute, then lock the device (it needs a passcode) and leave it for at "
                        + "least 30 minutes, talking now and then. Unlock, come back here and stop: the report "
                        + "says whether audio stayed live, stalls recovered and the VAD kept up."
                )
            }
        }

        private func audioSection(_ keeper: AudioSessionKeeper.Snapshot) -> some View {
            Section("Conversation audio") {
                LabeledContent("Status", value: "\(keeper.status)")
                LabeledContent("Phase", value: keeper.phase.rawValue)
                if let startedAt = keeper.startedAt, soak.isRunning {
                    LabeledContent("Elapsed") {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                    }
                }
                let statistics = keeper.statistics
                LabeledContent("Locked", value: Self.minutes(statistics.lockedSeconds))
                LabeledContent("Background (unlocked)", value: Self.minutes(statistics.backgroundSeconds))
                LabeledContent("Not live", value: Self.seconds(statistics.notLiveSeconds))
                LabeledContent(
                    "Stalls (recovered)", value: "\(statistics.stallsDetected) (\(statistics.stallsRecovered))")
                LabeledContent("Longest silent capture", value: Self.seconds(statistics.longestSilentCaptureSeconds))
                LabeledContent("Interruptions", value: "\(statistics.interruptions)")
                LabeledContent("Resumed on return", value: "\(statistics.foregroundResumes)")
            }
        }

        private func inferenceSection(_ inference: BackgroundInferenceMonitor.Snapshot) -> some View {
            Section {
                LabeledContent("Mitigation", value: inference.mitigation.rawValue)
                ForEach(inference.stages, id: \.stage) { stage in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stage.stage): \(stage.current.rawValue)\(stage.isExhausted ? " (can't keep up)" : "")")
                        Text(
                            "p95 \(stage.recentP95Milliseconds.map { "\(Int($0.rounded())) ms" } ?? "n/a") of "
                                + "\(Int(stage.budgetMilliseconds)) ms, \(stage.completedInferences) ok, "
                                + "\(stage.failedInferences) failed, next off screen: \(stage.nextBackgroundBackend.rawValue)"
                                + (stage.exhaustedOffScreen > 0
                                    ? ", ran out off screen \(stage.exhaustedOffScreen)×" : "")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(inference.switches.suffix(5).enumerated()), id: \.offset) { _, record in
                    Text(
                        "\(record.stage) \(record.from.rawValue) → \(record.to.rawValue) (\(record.phase.rawValue))"
                            + (record.error.map { ": failed, \($0)" } ?? "")
                    )
                    .font(.caption)
                }
            } header: {
                Text("Background inference")
            }
        }

        private func vadSection(_ vad: VoiceActivityStatistics) -> some View {
            Section("VAD") {
                LabeledContent("Model", value: soak.vadModel)
                LabeledContent("Audio analysed", value: Self.minutes(Double(vad.samplesProcessed) / 16_000))
                LabeledContent("Chunks run / skipped", value: "\(vad.chunksAnalyzed) / \(vad.chunksSkipped)")
                LabeledContent("Model failures", value: "\(vad.modelFailures)")
                LabeledContent("Speech segments", value: "\(vad.segments)")
            }
        }

        private func captureSection(_ capture: CaptureStatistics) -> some View {
            Section("Capture") {
                LabeledContent("Frames", value: "\(capture.framesPublished)")
                LabeledContent("Dropped buffers", value: "\(capture.droppedBuffers)")
                LabeledContent("Graph builds", value: "\(capture.segments)")
            }
        }

        private func reportSection(_ report: LongSessionReport) -> some View {
            Section("Report") {
                Label(
                    report.verdict.passed ? "Passed" : "Failed",
                    systemImage: report.verdict.passed ? "checkmark.seal" : "xmark.seal"
                )
                .foregroundStyle(report.verdict.passed ? .green : .red)
                ForEach(report.verdict.findings, id: \.self) { finding in
                    Text(finding).font(.caption)
                }
                if let url = soak.reportURL {
                    ShareLink("Share JSON report", item: url)
                }
            }
        }

        private static func minutes(_ seconds: Double) -> String {
            "\((seconds / 60).formatted(.number.precision(.fractionLength(1)))) min"
        }

        private static func seconds(_ seconds: Double) -> String {
            "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
        }
    }
#endif
