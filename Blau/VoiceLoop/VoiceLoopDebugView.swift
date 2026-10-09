#if DEBUG
    import BlauRealtime
    import BlauVoiceID
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
                    if let status = loop.voiceIDStatus {
                        LabeledContent("Voice ID", value: status.summary)
                    }
                } footer: {
                    if !loop.isAvailable {
                        Text("Only the live environment runs the voice loop.")
                    }
                }

                Section("Now") {
                    LabeledContent("You", value: loop.snapshot.userPartial ?? "–")
                    LabeledContent("Grok", value: loop.snapshot.agentText.isEmpty ? "–" : loop.snapshot.agentText)
                }

                IgnoredSpeechSection(ignored: loop.ignoredSpeech)

                Section("Metrics") {
                    ForEach(loop.hudReadout.rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    LabeledContent("Completed turns", value: "\(loop.snapshot.completedTurns)")
                    LabeledContent(
                        "Replies cut short", value: "\(loop.snapshot.interruptedAgentUtterances.count)")
                }
            }
            .navigationTitle("Voice Loop")
        }

        static let ignoredSpeechIdentifier = "blau.voiceLoop.ignoredSpeech"

        private var phaseDescription: String {
            switch loop.phase {
            case .idle: "Idle"
            case .starting: "Starting…"
            case .running: loop.snapshot.session.isReconnecting ? "Reconnecting…" : "Running"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    /// The "ignored speech" lane (#47): what the voice ID gate kept from Grok
    /// this conversation, greyed out, newest first, with the decision and
    /// score. Never sent anywhere; DEBUG builds only.
    struct IgnoredSpeechSection: View {
        let ignored: [GatedUtterance]

        var body: some View {
            Section {
                if ignored.isEmpty {
                    Text("Nothing ignored yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignored.reversed()) { verdict in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verdict.utterance.text)
                                .foregroundStyle(.secondary)
                            Text(Self.detail(verdict))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Ignored Speech")
            } footer: {
                Text(
                    "Speech voice ID didn't send to Grok: someone else, uncertain and dropped by the policy, or in "
                        + "another language.")
            }
            .accessibilityIdentifier(VoiceLoopDebugView.ignoredSpeechIdentifier)
        }

        static func detail(_ verdict: GatedUtterance) -> String {
            let score = verdict.representativeScore.map { String(format: "%.2f", $0) } ?? "–"
            let reason =
                switch verdict.disposition {
                case .rejected: "Rejected"
                case .uncertainDiscarded: "Uncertain, dropped"
                case .otherLanguage: "Other language"
                case .accepted, .uncertainCommitted: "Sent"
                }
            // The language filter's call (#50): "es 0.97".
            let language =
                verdict.language?.language.map { " · \($0.language.code) " + String(format: "%.2f", $0.probability) }
                ?? ""
            return "\(reason) · score \(score)\(language) · \(verdict.segments.count) segment(s)"
        }
    }
#endif
