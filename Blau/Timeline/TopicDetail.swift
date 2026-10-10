import BlauTopics
import SwiftUI

/// The accessibility identifiers of an expanded topic's detail (#58).
enum TopicDetailAccessibility {
    /// The detail under an expanded bullet: summary, span and actions.
    static let detail = "blau.timeline.topic.detail"
    /// When the topic ran and how long.
    static let span = "blau.timeline.topic.span"
    static let continueTopic = "blau.timeline.topic.continue"
    static let share = "blau.timeline.topic.share"
    static let more = "blau.timeline.topic.more"
    /// UI tests only: the latest tap-to-expand latency in milliseconds, as
    /// the element's value.
    static let expandLatency = "blau.timeline.expandLatency"
}

/// What an expanded older topic shows above its transcript (#58): its
/// summary, when it ran and for how long, and what can be done with it:
/// continue it in a conversation, share it as Markdown, rename it or merge
/// it with the previous topic. (Split is on each line of the transcript
/// below, "Split Topic Here".)
///
/// It opens inline under the bullet, in the timeline's lazy stack, so
/// expanding builds only this header and the transcript rows on screen.
/// Its `onAppear` ends the tap-to-expand measurement (`TopicExpansionTimer`).
struct TopicDetailHeader: View {
    let topic: TimelineTopic
    let placement: TopicTimeline.Placement
    let editor: TopicEditor
    /// Continues the topic; `nil` hides Continue.
    let onContinue: (() -> Void)?
    /// Called once the header is laid out.
    let onAppear: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = topic.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(verbatim: summary)
                    .brandTextStyle(.caption)
                    .foregroundStyle(Color.brand(.secondaryText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Summary"))
                    .accessibilityValue(Text(verbatim: summary))
                    .accessibilityIdentifier(TopicTimelineAccessibility.summary)
            }
            Text(verbatim: TopicDetailDescription.span(of: topic))
                .brandTextStyle(.timestamp)
                .foregroundStyle(Color.brand(.secondaryText))
                .accessibilityLabel(Text(verbatim: TopicDetailDescription.span(of: topic, spelledOut: true)))
                .accessibilityIdentifier(TopicDetailAccessibility.span)
            actions
        }
        .padding(.leading, TopicTimelineLayout.textInset)
        .padding(.trailing)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TopicDetailAccessibility.detail)
        .timelineRail(placement.railBelow)
        .onAppear(perform: onAppear)
    }

    /// Side by side when they fit, stacked at large text sizes (#81).
    private var actions: some View {
        TopicActionsLayout { actionButtons }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var actionButtons: some View {
        Group {
            if let onContinue {
                Button(action: onContinue) {
                    Label("Continue", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts a conversation that picks up this topic")
                .accessibilityIdentifier(TopicDetailAccessibility.continueTopic)
            }
            if let container = environment.modelContainer {
                ShareLink(
                    item: TopicMarkdownDocument(topic: topic, container: container),
                    preview: SharePreview(Text(verbatim: topic.title))
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shares the topic as Markdown")
                .accessibilityIdentifier(TopicDetailAccessibility.share)
            }
            if !topic.isSynthetic {
                Menu {
                    TopicEditMenuItems(
                        topicID: topic.id, title: topic.title, canMerge: placement.canMerge, editor: editor)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 20, minHeight: 20)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("More Actions")
                .accessibilityIdentifier(TopicDetailAccessibility.more)
            }
        }
    }
}

/// The text of a topic's detail.
enum TopicDetailDescription {
    /// When the topic ran and for how long: "6:00 PM – 6:08 PM · 8 min", or
    /// "6:00 PM – now" while it is open. `spelledOut` is VoiceOver's
    /// "From 6:00 PM to 6:08 PM, 8 minutes".
    static func span(of topic: TimelineTopic, spelledOut: Bool = false, format: TopicTimelineFormat = .init())
        -> String
    {
        let start = format.time(topic.startedAt)
        guard let endedAt = topic.endedAt, let duration = topic.duration else {
            return spelledOut
                ? String(localized: "Started \(start), still open") : "\(start) – " + String(localized: "now")
        }
        let end = format.time(endedAt)
        if spelledOut {
            return String(localized: "From \(start) to \(end), \(format.duration(duration, spelledOut: true))")
        }
        return "\(start) – \(end) · \(format.duration(duration))"
    }
}
