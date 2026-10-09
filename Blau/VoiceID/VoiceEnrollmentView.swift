import BlauVoiceID
import SwiftUI

/// Accessibility identifiers for the guided enrollment, shared with UI tests.
enum VoiceEnrollmentIdentifiers {
    static let start = "enrollment.start"
    static let cancel = "enrollment.cancel"
    static let prompt = "enrollment.prompt"
    static let progress = "enrollment.progress"
    static let meter = "enrollment.meter"
    static let doneSpeaking = "enrollment.doneSpeaking"
    static let retry = "enrollment.retry"
    static let message = "enrollment.message"
    static let finished = "enrollment.finished"
    static let close = "enrollment.close"
}

/// The guided voice enrollment (#46): four prompts of about 5 s each (three
/// for a device's top-up), each clip checked for talking time, background
/// noise and consistency with the others before the voiceprint is stored.
///
/// Settings → Voice ID presents it; onboarding (#44) can host it the same
/// way. `onFinish` runs when the user closes it, enrolled or not.
struct VoiceEnrollmentView: View {
    @Environment(AppEnvironment.self) private var environment

    let plan: EnrollmentPlan
    var onFinish: () -> Void

    @State private var enrollment: VoiceEnrollment?
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if let enrollment {
                    VoiceEnrollmentFlow(enrollment: enrollment, onFinish: close)
                } else if unavailable {
                    ContentUnavailableView(
                        "Not Ready", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text("Your data isn't open yet. Try again in a moment."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(plan.purpose == .topUp ? "Add This iPhone" : "Voice Enrollment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // No Cancel while saving: the save can't be taken back,
                    // so the sheet stays up and shows the stored voiceprint.
                    if !isFinished, enrollment?.phase != .saving {
                        Button("Cancel", role: .cancel) { Task { await cancel() } }
                            .accessibilityIdentifier(VoiceEnrollmentIdentifiers.cancel)
                    }
                }
            }
        }
        .interactiveDismissDisabled(enrollment?.phase.isActive == true)
        .task {
            guard enrollment == nil else { return }
            enrollment = environment.makeVoiceEnrollment(plan: plan)
            unavailable = enrollment == nil
        }
    }

    private var isFinished: Bool {
        if case .finished = enrollment?.phase { return true }
        return false
    }

    private func cancel() async {
        if let enrollment {
            // A tap that lands once saving has begun: stay and show the
            // result rather than close over a voiceprint that is stored.
            guard enrollment.canCancel || !enrollment.phase.isActive else { return }
            await enrollment.cancel()
        }
        onFinish()
    }

    private func close() {
        onFinish()
    }
}

/// The enrollment's screens, one per phase.
private struct VoiceEnrollmentFlow: View {
    let enrollment: VoiceEnrollment
    var onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch enrollment.phase {
                case .notStarted:
                    introduction
                case .finished(let voiceprint):
                    finished(voiceprint)
                case .failed(let error):
                    failure(error)
                case .cancelled:
                    EmptyView()
                default:
                    capture
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(.default, value: enrollment.currentPrompt)
    }

    // MARK: Screens

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "person.wave.2.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(enrollment.plan.purpose == .topUp ? "Teach this iPhone your voice" : "Teach Blau your voice")
                .font(.title.bold())
            Text(introductionText)
                .foregroundStyle(.secondary)
            Label("Find a quiet spot where only you are talking.", systemImage: "speaker.slash")
            Label("It takes less than a minute.", systemImage: "timer")
            Button("Start") { Task { await enrollment.start() } }
                .brandProminentButtonStyle()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.start)
        }
    }

    private var introductionText: String {
        switch enrollment.plan.purpose {
        case .enrollment:
            String(
                localized: """
                    You'll say \(enrollment.plan.prompts.count) short things, so Blau answers only you. \
                    Your voiceprint syncs through iCloud, so your other devices know your voice too.
                    """)
        case .topUp:
            String(
                localized: """
                    Your voiceprint already syncs here. Saying \(enrollment.plan.prompts.count) short things \
                    on this iPhone helps Blau recognize you through its microphones.
                    """)
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clip \(enrollment.clipNumber) of \(enrollment.plan.prompts.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(enrollment.acceptedCount), total: Double(enrollment.plan.prompts.count))
                    .accessibilityIdentifier(VoiceEnrollmentIdentifiers.progress)
            }

            if let prompt = enrollment.currentPrompt {
                PromptCard(copy: EnrollmentPromptCopy(prompt))
            }

            QualityMeter(enrollment: enrollment)

            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch enrollment.phase {
        case .preparing:
            ProgressView("Getting the microphone ready…")
                .frame(maxWidth: .infinity)
        case .recording:
            Label("Listening — start speaking", systemImage: "waveform")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Button("Done Speaking") { enrollment.finishClip() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.doneSpeaking)
        case .analyzing:
            ProgressView("Checking the clip…")
                .frame(maxWidth: .infinity)
        case .saving:
            ProgressView("Saving your voiceprint…")
                .frame(maxWidth: .infinity)
        case .rejected(let issues, let restarted):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(restarted ? EnrollmentMessages.restarted : issues.first.map(EnrollmentMessages.issue) ?? "")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.message)
                Button("Try Again") { Task { await enrollment.retry() } }
                    .brandProminentButtonStyle()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(VoiceEnrollmentIdentifiers.retry)
            }
        default:
            EmptyView()
        }
    }

    private func finished(_ voiceprint: Voiceprint) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(enrollment.plan.purpose == .topUp ? "This iPhone knows your voice" : "You're enrolled")
                .font(.title.bold())
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.finished)
            Text(
                "Blau now answers only your voice. Your voiceprint syncs through iCloud to your other devices, "
                    + "end-to-end encrypted."
            )
            .foregroundStyle(.secondary)
            LabeledContent("Clips", value: voiceprint.clipCount.formatted())
            if let duration = enrollment.duration {
                LabeledContent(
                    "Took",
                    value: Duration.seconds(duration.components.seconds).formatted(
                        .units(allowed: [.minutes, .seconds], width: .abbreviated)))
            }
            Button("Done", action: onFinish)
                .brandProminentButtonStyle()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.close)
        }
    }

    private func failure(_ error: VoiceEnrollmentError) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Enrollment didn't finish")
                .font(.title2.bold())
            Text(EnrollmentMessages.failure(error))
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.message)
            Button("Close", action: onFinish)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(VoiceEnrollmentIdentifiers.close)
        }
    }
}

/// The prompt being recorded.
private struct PromptCard: View {
    let copy: EnrollmentPromptCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.title)
                .font(.headline)
            Text("“\(copy.text)”")
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let hint = copy.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(VoiceEnrollmentIdentifiers.prompt)
    }
}

/// The live quality meter: input level, talking time toward the clip's
/// target, and the three checks (duration, background, consistency).
private struct QualityMeter: View {
    let enrollment: VoiceEnrollment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            levelBar
            HStack(spacing: 16) {
                check("Duration", systemImage: "timer", state: checks.duration)
                check("Background", systemImage: "waveform.badge.magnifyingglass", state: checks.signal)
                check("Your Voice", systemImage: "person.wave.2", state: checks.consistency)
            }
            .font(.footnote)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(VoiceEnrollmentIdentifiers.meter)
    }

    private var meter: EnrollmentMeter? {
        if case .recording(let meter) = enrollment.phase { return meter }
        return nil
    }

    private var checks: EnrollmentQualityChecks {
        if let meter {
            let lowLevel = enrollment.currentPrompt?.expectsLowLevel == true
            let policy = enrollment.policy
            return EnrollmentQualityChecks(
                meter: meter,
                minimumSignalToNoise: lowLevel ? policy.minimumLowLevelSignalToNoise : policy.minimumSignalToNoise)
        }
        if let result = enrollment.lastResult, result.prompt == enrollment.currentPrompt || result.isAccepted {
            return EnrollmentQualityChecks(result: result)
        }
        return EnrollmentQualityChecks(
            meter: EnrollmentMeter(speechTarget: enrollment.plan.speechPerClip), minimumSignalToNoise: 0)
    }

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: geometry.size.width * CGFloat(meter?.progress ?? 0))
                    Capsule()
                        .fill(.tint.opacity(0.35))
                        .frame(width: geometry.size.width * CGFloat(meter?.level ?? 0))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            let speech = (meter?.speech ?? .zero).timeInterval
            let target = Int(enrollment.plan.speechPerClip.timeInterval.rounded())
            Text("\(speech, format: .number.precision(.fractionLength(1))) of \(target) seconds of speech")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func check(_ title: LocalizedStringKey, systemImage: String, state: EnrollmentQualityChecks.State)
        -> some View
    {
        Label {
            Text(title)
        } icon: {
            switch state {
            case .pending: Image(systemName: systemImage).foregroundStyle(.secondary)
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .accessibilityValue(Self.accessibilityValue(state))
    }

    private static func accessibilityValue(_ state: EnrollmentQualityChecks.State) -> String {
        switch state {
        case .pending: String(localized: "Waiting")
        case .passed: String(localized: "Good")
        case .failed: String(localized: "Needs another try")
        }
    }
}

#if DEBUG
    #Preview("Enrollment") {
        VoiceEnrollmentView(plan: .enrollment, onFinish: {})
            .appEnvironment(.preview())
    }
#endif
