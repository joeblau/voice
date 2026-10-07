import BlauRealtime
import SwiftUI

/// The main screen's primary control, bottom-right (#41). It shows the
/// conversation's state (`RecordButtonModel.state`) and starts, pauses and
/// ends it.
///
/// - **Tap** starts a conversation, or ends the one that is running.
/// - **Touch and hold** (while one runs) opens a menu with Pause Listening /
///   Resume Listening (the microphone is muted, the conversation goes on) and
///   End Conversation. VoiceOver gets the same as custom actions.
/// - **Haptics** on start, stop, pause, resume and a failed start
///   (`sensoryFeedback`, which follows the system haptics setting).
/// - **Look**: a glyph per state with a ring that follows the microphone
///   while listening and Grok's voice while it speaks (`RecordButtonFace`),
///   on the bottom bar's prominent Liquid Glass, tinted per state.
struct RecordButton: View {
    let model: RecordButtonModel

    var body: some View {
        let state = model.state
        let accessibility = RecordButtonAccessibility(state: state, isAwaitingConnection: model.isAwaitingConnection)
        control(state: state)
            .buttonStyle(.borderedProminent)
            .tint(RecordButtonFace.tint(for: state))
            // Only while a start or stop is in flight: a running
            // conversation can always be ended, even while it reconnects.
            .disabled(model.isTransitioning)
            .accessibilityIdentifier(MainScreenAccessibility.recordButton)
            .accessibilityLabel(accessibility.label)
            .accessibilityValue(accessibility.value)
            .accessibilityHint(accessibility.hint)
            .accessibilityActions {
                if model.canPauseOrResume {
                    if model.status.isListeningPaused {
                        Button("Resume Listening") { Task { await model.resumeListening() } }
                    } else {
                        Button("Pause Listening") { Task { await model.pauseListening() } }
                    }
                }
            }
            .accessibilityShowsLargeContentViewer {
                Label(accessibility.label, systemImage: RecordButtonFace.systemImage(for: state))
            }
            .sensoryFeedback(trigger: model.feedback) { _, event in
                event.map { Self.haptic(for: $0.kind) }
            }
    }

    /// While a conversation runs the button is a menu whose primary action
    /// is the tap (end), so touch and hold offers pause / resume. Otherwise
    /// a plain button.
    @ViewBuilder
    private func control(state: RecordButtonState) -> some View {
        let face = RecordButtonFace(state: state, inputLevel: model.inputLevel, outputLevel: model.outputLevel)
        if model.canPauseOrResume {
            Menu {
                if model.status.isListeningPaused {
                    Button("Resume Listening", systemImage: "mic") {
                        Task { await model.resumeListening() }
                    }
                } else {
                    Button("Pause Listening", systemImage: "mic.slash") {
                        Task { await model.pauseListening() }
                    }
                }
                Button("End Conversation", systemImage: "stop.fill", role: .destructive) {
                    Task { await model.tap() }
                }
            } label: {
                face
            } primaryAction: {
                Task { await model.tap() }
            }
        } else {
            Button {
                Task { await model.tap() }
            } label: {
                face
            }
        }
    }

    static func haptic(for feedback: RecordButtonModel.Feedback) -> SensoryFeedback {
        switch feedback {
        case .started: .start
        case .stopped: .stop
        case .paused, .resumed: .impact(weight: .light)
        case .failed: .error
        }
    }
}

/// The record button's content: a glyph per state and the level ring. Pure
/// drawing with no system controls, so the snapshot tests render every
/// state exactly as the bar shows it (`RecordButtonSnapshotTests`).
///
/// With Reduce Motion on, the ring doesn't grow and shrink with the level:
/// it stays put and only its opacity follows the level, and the spinner is
/// replaced by a static ellipsis.
struct RecordButtonFace: View {
    /// The face's side in points. The bar's prominent style adds its own
    /// padding around it.
    static let size: CGFloat = 26

    let state: RecordButtonState
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    /// Overrides the system's Reduce Motion setting (snapshot tests; the
    /// environment value can't be set).
    var reducesMotion: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion

    private var reduceMotion: Bool { reducesMotion ?? systemReducesMotion }

    var body: some View {
        ZStack {
            if let level = ringLevel {
                LevelRing(level: CGFloat(level), style: ringStyle, reduceMotion: reduceMotion)
            }
            if state.isBusy {
                if reduceMotion {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                } else {
                    Spinner()
                        .frame(width: 16, height: 16)
                }
            } else {
                Image(systemName: Self.systemImage(for: state))
                    .font(.system(size: glyphSize, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }

    /// The level the ring shows, or `nil` for no ring.
    private var ringLevel: Float? {
        switch state {
        case .listening: inputLevel
        case .agentSpeaking: outputLevel
        default: nil
        }
    }

    private var ringStyle: LevelRing.Style {
        state == .agentSpeaking ? .agent : .microphone
    }

    private var glyphSize: CGFloat {
        switch state {
        case .listening: 11
        case .agentSpeaking: 12
        default: 17
        }
    }

    /// The SF Symbol for `state` (the large content viewer uses it too).
    static func systemImage(for state: RecordButtonState) -> String {
        switch state {
        case .idle: "mic.fill"
        case .connecting, .reconnecting, .stopping: "ellipsis"
        case .listening: "stop.fill"
        case .agentSpeaking: "speaker.wave.2.fill"
        case .paused: "mic.slash.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    /// The bar button's tint for `state`: the accent color to start, red
    /// while a conversation is live (reconnecting included, so it doesn't
    /// look like a fresh start), gray while paused, orange for errors.
    static func tint(for state: RecordButtonState) -> Color {
        switch state {
        case .idle, .connecting: .accentColor
        case .listening, .agentSpeaking, .reconnecting, .stopping: .red
        case .paused: .gray
        case .error: .orange
        }
    }
}

/// A ring around the glyph whose size and opacity follow a `0...1` level.
private struct LevelRing: View {
    enum Style {
        /// The user's microphone: one ring.
        case microphone
        /// Grok's voice: a ring and a fainter halo, so it reads differently
        /// from the microphone at a glance.
        case agent
    }

    let level: CGFloat
    let style: Style
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if style == .agent {
                Circle()
                    .strokeBorder(lineWidth: 1)
                    .opacity(0.25 + 0.35 * level)
            }
            Circle()
                .strokeBorder(lineWidth: style == .agent ? 2.5 : 2)
                .scaleEffect(reduceMotion ? 0.86 : 0.62 + 0.38 * level)
                .opacity(0.4 + 0.6 * level)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: level)
    }
}

/// An arc that turns while a start or stop is in flight. Drawn rather than
/// a `ProgressView` so it renders in snapshots; its first frame is the
/// unrotated arc.
private struct Spinner: View {
    @State private var isTurning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
    }
}

/// What VoiceOver (and the large content viewer) says about the record
/// button in each state: the label names what a tap does, the value says
/// where the conversation is, the hint adds what isn't obvious.
struct RecordButtonAccessibility: Equatable {
    let label: String
    let value: String
    let hint: String

    init(state: RecordButtonState, isAwaitingConnection: Bool) {
        switch state {
        case .idle:
            label = String(localized: "Start Conversation")
            value = String(localized: "Not listening")
            hint = String(localized: "Starts a conversation with Grok.")
        case .connecting:
            label = String(localized: "Start Conversation")
            value = String(localized: "Connecting")
            hint = ""
        case .reconnecting:
            label = String(localized: "End Conversation")
            value = String(localized: "Reconnecting the microphone")
            hint = String(localized: "Ends the conversation.")
        case .listening:
            label = String(localized: "End Conversation")
            value =
                isAwaitingConnection
                ? String(localized: "Listening, connecting to Grok") : String(localized: "Listening")
            hint = String(localized: "Ends the conversation. Use the actions to pause listening.")
        case .agentSpeaking:
            label = String(localized: "End Conversation")
            value = String(localized: "Grok is speaking")
            hint = String(localized: "Ends the conversation. Use the actions to pause listening.")
        case .paused:
            label = String(localized: "End Conversation")
            value = String(localized: "Paused, microphone muted")
            hint = String(localized: "Ends the conversation. Use the actions to resume listening.")
        case .stopping:
            label = String(localized: "End Conversation")
            value = String(localized: "Ending")
            hint = ""
        case .error(let failure):
            switch failure {
            case .couldNotStart:
                label = String(localized: "Start Conversation")
                value = String(localized: "Couldn't start")
                hint = String(localized: "Tries again.")
            case .connection(let requiresUserAction):
                label = String(localized: "End Conversation")
                value =
                    requiresUserAction
                    ? String(localized: "Can't reach Grok, check your xAI API key")
                    : String(localized: "Lost the connection to Grok")
                hint = String(localized: "Ends the conversation.")
            case .audioInterrupted:
                label = String(localized: "End Conversation")
                value = String(localized: "Microphone in use by another app")
                hint = String(localized: "Ends the conversation.")
            case .audioUnavailable:
                label = String(localized: "End Conversation")
                value = String(localized: "Microphone unavailable")
                hint = String(localized: "Ends the conversation.")
            }
        }
    }
}

/// "You're muted": shown above the record button when the user talks while
/// listening is paused (`AVAudioInputNode`'s muted speech activity), with a
/// button to resume. VoiceOver announces it when it appears.
struct MutedSpeechHint: View {
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("You're muted", systemImage: "mic.slash.fill")
                .font(.subheadline.weight(.semibold))
            Button("Resume", action: resume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(MainScreenAccessibility.mutedHintResume)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MainScreenAccessibility.mutedHint)
    }
}

#Preview("Faces") {
    let states: [RecordButtonState] = [
        .idle, .connecting, .listening, .agentSpeaking, .paused, .reconnecting, .stopping,
        .error(.connection(requiresUserAction: false)),
    ]
    VStack(spacing: 16) {
        ForEach(states, id: \.self) { state in
            HStack {
                RecordButtonFace(state: state, inputLevel: 0.7, outputLevel: 0.6)
                    .padding(10)
                    .background(RecordButtonFace.tint(for: state), in: .capsule)
                Text(state.name)
            }
        }
    }
}

#Preview("Muted hint") {
    MutedSpeechHint {}
        .padding()
}
