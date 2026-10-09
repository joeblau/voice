import BlauCore
import SwiftUI

/// The accessibility identifiers UI tests use for the issue banner.
enum IssueBannerAccessibility {
    /// The banner.
    static let banner = "blau.issue"
    /// Its title.
    static let title = "blau.issue.title"
    /// The dismiss button (not on blocking issues).
    static let dismiss = "blau.issue.dismiss"

    /// The button for `action`.
    static func action(_ action: RecoveryAction) -> String {
        "blau.issue.action.\(action.rawValue)"
    }
}

/// One issue from the error catalog (#80, docs/errors.md), above the
/// conversation: what happened, what it means, and its recovery buttons.
///
/// Offline and reconnecting are quiet (secondary tint): Blau handles them.
/// Warnings are orange, blocking issues red. Anything but a blocking issue
/// can be dismissed until it changes.
struct IssueBanner: View {
    let issue: UserFacingIssue
    /// How many more issues are waiting behind this one.
    var moreCount = 0
    let onAction: (RecoveryAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: Self.symbol(for: issue.code))
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: issue.title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier(IssueBannerAccessibility.title)
                Text(verbatim: issue.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = issue.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
                if moreCount > 0 {
                    Text("\(moreCount) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !issue.actions.isEmpty {
                    // Side by side when they fit, stacked at large text sizes.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actionButtons }
                        VStack(alignment: .leading, spacing: 8) { actionButtons }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if IssueBoard.canDismiss(issue) {
                Button {
                    onDismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(IssueBannerAccessibility.dismiss)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IssueBannerAccessibility.banner)
        .accessibilityValue(Text(verbatim: issue.code.rawValue))
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(issue.actions, id: \.self) { action in
            Button(action.title) {
                onAction(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(action == issue.primaryAction ? tint : .secondary)
            .accessibilityIdentifier(IssueBannerAccessibility.action(action))
        }
    }

    private var tint: Color {
        switch issue.severity {
        case .info: .secondary
        case .warning: .orange
        case .blocking: .red
        }
    }

    /// An SF Symbol for each kind of issue.
    static func symbol(for code: IssueCode) -> String {
        switch code {
        case .offline: "wifi.slash"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .grokUnreachable, .xaiServerError: "exclamationmark.icloud"
        case .secureConnectionFailed: "lock.slash"
        case .rateLimited: "hourglass"
        case .missingAPIKey, .invalidAPIKey, .apiKeyDisabled, .voiceNotPermitted, .keychainLocked,
            .keychainFailure:
            "key"
        case .insufficientCredits: "creditcard.trianglebadge.exclamationmark"
        case .replyFailed, .replyTimedOut, .unexpectedResponse: "exclamationmark.bubble"
        case .microphoneDenied, .microphoneUnavailable, .microphoneBusy: "mic.slash"
        case .audioInterrupted, .audioPaused: "pause.circle"
        case .audioRecovering: "waveform.badge.exclamationmark"
        case .audioFailed: "speaker.slash"
        case .modelsWaitingForNetwork, .modelsWaitingForWiFi: "arrow.down.circle.dotted"
        case .modelsStorageFull, .modelDownloadFailed, .modelDamaged, .modelLoadFailed: "waveform.slash"
        case .iCloudFull, .iCloudUnavailable, .iCloudSyncPaused: "exclamationmark.icloud"
        case .transcriptNotSaved, .storeUnavailable: "externaldrive.badge.exclamationmark"
        }
    }
}

/// The main screen's banner slot: the worst issue from the `IssueCenter`,
/// with its actions carried out here (sheets and URLs) or by the center.
struct IssueBannerSlot: View {
    /// Opens the xAI key entry.
    let onUpdateKey: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let issues = environment.issues.visible
        Group {
            if let issue = issues.first {
                IssueBanner(
                    issue: issue, moreCount: issues.count - 1,
                    onAction: { perform($0) },
                    onDismiss: { environment.issues.dismiss(issue) }
                )
                .transition(Motion.slide(from: .top, reduceMotion: reduceMotion))
            }
        }
        // VoiceOver hears about a new problem wherever its focus is (#81):
        // the banner is at the top, far from the record button. A blocking
        // problem interrupts; the rest wait their turn.
        .onChange(of: issues.first?.code) { _, code in
            guard code != nil, let issue = issues.first else { return }
            BlauAnnouncement.post(
                BlauAnnouncement.text(for: issue), urgency: issue.severity == .blocking ? .urgent : .polite)
        }
    }

    private func perform(_ action: RecoveryAction) {
        switch action {
        case .updateAPIKey:
            onUpdateKey()
        case .openXAIConsole:
            openURL(RecoveryAction.xaiConsoleURL)
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        case .retry, .discardQueued, .resumeAudio, .retryDownload, .downloadOnCellular:
            let issues = environment.issues
            let models = environment.speechModels
            Task { await issues.perform(action, models: models) }
        }
    }
}

#Preview("Issues") {
    ScrollView {
        VStack {
            ForEach(
                [
                    IssueCenter.fixtureIssue(.offline), UserFacingIssue(.rateLimited, detail: "HTTP 429"),
                    UserFacingIssue(.invalidAPIKey), UserFacingIssue(.microphoneUnavailable),
                    UserFacingIssue(.iCloudFull),
                ], id: \.code
            ) { issue in
                IssueBanner(issue: issue, onAction: { _ in }, onDismiss: {})
            }
        }
    }
}
