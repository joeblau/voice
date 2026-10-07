#if DEBUG
    import BlauRealtime
    import SwiftUI

    /// The debug menu's entry to the voice loop, until the record button
    /// (#41) and the transcript view (#42) exist.
    struct VoiceLoopDebugSection: View {
        @Environment(AppEnvironment.self) private var environment

        var body: some View {
            Section {
                NavigationLink("Voice Loop") {
                    VoiceLoopDebugView(loop: environment.voiceLoop)
                }
                .accessibilityIdentifier(VoiceLoopDebugView.openIdentifier)
            } footer: {
                Text("Talk with Grok end to end: microphone, VAD, Parakeet, the realtime session and playback.")
            }
        }
    }

    /// Starts and stops a conversation and shows what the turn orchestrator
    /// sees: state, live text both ways, latency and usage. DEBUG builds
    /// only.
    struct VoiceLoopDebugView: View {
        static let openIdentifier = "blau.voiceLoop.open"
        static let toggleIdentifier = "blau.voiceLoop.toggle"

        let loop: VoiceLoop

        var body: some View {
            Form {
                Section {
                    Button(
                        loop.phase.isActive ? "Stop" : "Start",
                        systemImage: loop.phase.isActive ? "stop.fill" : "mic.fill"
                    ) {
                        Task {
                            if loop.phase.isActive {
                                await loop.stop()
                            } else {
                                await loop.start()
                            }
                        }
                    }
                    .disabled(!loop.isAvailable || loop.phase == .starting)
                    .accessibilityIdentifier(Self.toggleIdentifier)
                    LabeledContent("Loop", value: phaseDescription)
                } footer: {
                    if !loop.isAvailable {
                        Text("Only the live environment runs the voice loop.")
                    }
                }

                Section("Now") {
                    LabeledContent("You", value: loop.snapshot.userPartial ?? "–")
                    LabeledContent("Grok", value: loop.snapshot.agentText.isEmpty ? "–" : loop.snapshot.agentText)
                }

                Section("Metrics") {
                    ForEach(loop.hudReadout.rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    LabeledContent("Completed turns", value: "\(loop.snapshot.completedTurns)")
                }
            }
            .navigationTitle("Voice Loop")
        }

        private var phaseDescription: String {
            switch loop.phase {
            case .idle: "Idle"
            case .starting: "Starting…"
            case .running: loop.snapshot.session.isReconnecting ? "Reconnecting…" : "Running"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }
#endif
