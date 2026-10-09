import BlauTopics
import SwiftUI

/// Layout constants of the topic timeline (#56).
enum TopicTimelineLayout {
    /// The rail runs down the leading gutter (the transcript's 16 pt margin),
    /// centered here, so transcript rows keep their margins and the rail
    /// runs past them.
    static let railCenter: CGFloat = 10
    static let railWidth: CGFloat = 2
    /// A compressed topic's dot.
    static let dotDiameter: CGFloat = 10
    /// The current topic's dot.
    static let currentDotDiameter: CGFloat = 12
    /// How far a pulse ring grows, as a multiple of the dot.
    static let pulseScale: CGFloat = 1.7
    /// One pulse, in seconds.
    static let pulsePeriod: TimeInterval = 1.6
    /// Where a bullet's text starts, clear of the dot.
    static let textInset: CGFloat = 28
    /// A compressed row's height at the default text size (scaled with
    /// Dynamic Type). Fixed, so laying out history is cheap and a title
    /// changing never moves the rows below it.
    static let compressedRowHeight: CGFloat = 44
}

/// One topic's bullet: its dot on the rail, its title and its time.
///
/// The current topic's bullet is larger (the `topicTitle` style) and its dot
/// pulses while recording. Any other topic's is one row of fixed height
/// with its time and duration, compressed or expanded. A provisional title
/// is italic, and a new title cross-fades in place.
struct TopicBullet: View {
    let topic: TimelineTopic
    let placement: TopicTimeline.Placement
    let isExpanded: Bool
    /// The current topic's dot pulses while recording.
    let isRecording: Bool
    /// Rename and merge from the long-press menu.
    let editor: TopicEditor
    /// Continue This Topic in the long-press menu (#58); `nil` leaves it
    /// out.
    let onContinue: (() -> Void)?
    let action: () -> Void

    @Environment(AppEnvironment.self) private var environment

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var rowHeight = TopicTimelineLayout.compressedRowHeight

    /// Long-press: Continue This Topic and Share as Markdown (#58), then
    /// Rename and Merge with Previous (#54) for a real topic.
    var body: some View {
        button.contextMenu {
            if let onContinue {
                Button("Continue This Topic", systemImage: "arrow.uturn.forward", action: onContinue)
                    .accessibilityIdentifier(TopicDetailAccessibility.continueTopic)
            }
            if let container = environment.modelContainer {
                ShareLink(
                    item: TopicMarkdownDocument(topic: topic, container: container),
                    preview: SharePreview(Text(verbatim: topic.title))
                ) {
                    Label("Share as Markdown", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(TopicDetailAccessibility.share)
            }
            if !topic.isSynthetic {
                Section {
                    TopicEditMenuItems(
                        topicID: topic.id, title: topic.title, canMerge: placement.canMerge, editor: editor)
                }
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            Group {
                if placement.isCurrent {
                    currentRow
                } else {
                    compressedRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                TimelineMarker(
                    colorSeed: topic.colorSeed, railAbove: placement.railAbove,
                    railBelow: placement.railBelow, isCurrent: placement.isCurrent, isPulsing: isRecording)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A pinned header: opaque, so the transcript scrolls under it.
        .background(Color(.systemBackground))
        .accessibilityLabel(Text(verbatim: topic.title))
        .accessibilityValue(
            TopicBulletDescription.value(
                for: topic, isCurrent: placement.isCurrent, isExpanded: isExpanded, isRecording: isRecording)
        )
        .accessibilityHint(TopicBulletDescription.hint(isCurrent: placement.isCurrent, isExpanded: isExpanded))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(
            placement.isCurrent ? TopicTimelineAccessibility.currentTopic : TopicTimelineAccessibility.topic)
    }

    /// The current topic: when it started, then its title in the large
    /// style.
    private var currentRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: TopicBulletDescription.meta(for: topic, isCurrent: true))
                .brandTextStyle(.timestamp)
                .foregroundStyle(isRecording ? Color.brand(.recording) : .brand(.secondaryText))
            TopicTitle(topic: topic, style: .topicTitle)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        .padding(.leading, TopicTimelineLayout.textInset)
        .padding(.trailing)
        .padding(.vertical, 10)
    }

    /// Any other topic: one row of title, time and duration, and a chevron
    /// that turns when it is expanded. At the accessibility text sizes the
    /// time goes under the title and the row grows instead of truncating.
    @ViewBuilder
    private var compressedRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                TopicTitle(topic: topic, style: .topicBullet)
                meta
            }
            .padding(.leading, TopicTimelineLayout.textInset)
            .padding(.trailing)
            .padding(.vertical, 8)
            .frame(minHeight: rowHeight)
        } else {
            HStack(spacing: 8) {
                TopicTitle(topic: topic, style: .topicBullet)
                    .lineLimit(1)
                Spacer(minLength: 8)
                meta
            }
            .padding(.leading, TopicTimelineLayout.textInset)
            .padding(.trailing)
            .frame(height: rowHeight)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(verbatim: TopicBulletDescription.meta(for: topic, isCurrent: false))
                .brandTextStyle(.timestamp)
                .foregroundStyle(Color.brand(.secondaryText))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .fixedSize()
    }
}

/// A topic's title: italic while provisional, cross-fading in place when
/// the labeler refines it or the user renames it.
private struct TopicTitle: View {
    let topic: TimelineTopic
    let style: BrandTextStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(verbatim: topic.title)
            .font(.brand(style))
            .italic(topic.titleIsProvisional)
            .foregroundStyle(.primary)
            .contentTransition(.interpolate)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: topic.title)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: topic.titleIsProvisional)
    }
}

/// The rail through a bullet and its dot.
private struct TimelineMarker: View {
    let colorSeed: Int
    let railAbove: Bool
    let railBelow: Bool
    let isCurrent: Bool
    let isPulsing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(railAbove ? TimelineRail.color : .clear)
            Rectangle().fill(railBelow ? TimelineRail.color : .clear)
        }
        .frame(width: TopicTimelineLayout.railWidth)
        .overlay {
            TopicDot(
                color: .topicDot(colorSeed: colorSeed),
                diameter: isCurrent ? TopicTimelineLayout.currentDotDiameter : TopicTimelineLayout.dotDiameter,
                isPulsing: isPulsing)
        }
        .frame(width: TopicTimelineLayout.railCenter * 2)
        .accessibilityHidden(true)
    }
}

/// A topic's dot in its palette color, cut out of the rail by a ring of the
/// background. While recording it sends out a pulse, or under Reduce Motion
/// wears a steady halo instead.
struct TopicDot: View {
    let color: Color
    let diameter: CGFloat
    var isPulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .background {
                if isPulsing {
                    if reduceMotion {
                        Circle()
                            .fill(color.opacity(0.3))
                            .frame(width: diameter * 1.5, height: diameter * 1.5)
                    } else {
                        // 30 frames a second is smooth for a slow ring and
                        // keeps a long recording cheap.
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            let phase = TopicDot.phase(at: context.date)
                            Circle()
                                .fill(color.opacity(0.45 * (1 - phase)))
                                .frame(width: diameter, height: diameter)
                                .scaleEffect(1 + (TopicTimelineLayout.pulseScale - 1) * phase)
                        }
                    }
                }
            }
            .padding(2)
            .background(Circle().fill(Color(.systemBackground)))
    }

    /// Where a pulse is at `date`, from 0 (leaving the dot) to 1 (gone).
    static func phase(at date: Date) -> CGFloat {
        let period = TopicTimelineLayout.pulsePeriod
        return CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }
}

// MARK: - Rail and headers

enum TimelineRail {
    static let color = Color(.systemGray4)
}

extension View {
    /// Draws the rail down the leading gutter, behind this view's full
    /// height, when `visible`.
    func timelineRail(_ visible: Bool) -> some View {
        background(alignment: .leading) {
            if visible {
                Rectangle()
                    .fill(TimelineRail.color)
                    .frame(width: TopicTimelineLayout.railWidth)
                    .padding(.leading, TopicTimelineLayout.railCenter - TopicTimelineLayout.railWidth / 2)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The first conversation of a day: "Today", "Yesterday" or the date.
struct TimelineDayHeader: View {
    let day: Date
    let rail: Bool

    var body: some View {
        Text(verbatim: TopicBulletDescription.dayTitle(day))
            .brandTextStyle(.heading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, TopicTimelineLayout.textInset)
            .padding(.trailing)
            .padding(.top, 20)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(TopicTimelineAccessibility.day)
            .timelineRail(rail)
    }
}

/// A conversation starts: its title if it has one, and when it started.
struct TimelineConversationHeader: View {
    let conversation: TimelineConversation
    let rail: Bool

    var body: some View {
        Label {
            Text(verbatim: TopicBulletDescription.conversationTitle(conversation))
        } icon: {
            Image(systemName: "waveform")
        }
        .brandTextStyle(.caption)
        .foregroundStyle(Color.brand(.secondaryText))
        // Wraps rather than truncating at large text sizes (#81).
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, TopicTimelineLayout.textInset)
        .padding(.trailing)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(TopicTimelineAccessibility.conversation)
        .timelineRail(rail)
    }
}

// MARK: - Text

/// What a bullet says, on screen and to VoiceOver: a list of topics, each
/// with its time.
enum TopicBulletDescription {
    /// The time line next to a bullet. The current topic: "Now · 9:41 AM"
    /// while it is open. Any other: "9:41 AM · 12 min".
    static func meta(for topic: TimelineTopic, isCurrent: Bool, format: TopicTimelineFormat = .init()) -> String {
        let time = format.time(topic.startedAt)
        if let duration = topic.duration {
            return "\(time) · \(format.duration(duration))"
        }
        return isCurrent ? String(localized: "Now · \(time)") : time
    }

    /// VoiceOver's value for a bullet (its label is the title): which
    /// topic, when it started, how long it lasted and whether it is open.
    static func value(
        for topic: TimelineTopic, isCurrent: Bool, isExpanded: Bool, isRecording: Bool,
        format: TopicTimelineFormat = .init(), now: Date = Date()
    ) -> String {
        let time = format.time(topic.startedAt)
        var parts: [String] = []
        if isCurrent {
            parts.append(String(localized: "Current topic"))
            if topic.duration == nil {
                parts.append(String(localized: "started \(time)"))
            } else {
                parts.append(time)
            }
        } else {
            parts.append(dayTitle(topic.startedAt, format: format, now: now))
            parts.append(time)
        }
        if let duration = topic.duration {
            parts.append(format.duration(duration, spelledOut: true))
        }
        if isCurrent {
            if isRecording {
                parts.append(String(localized: "recording"))
            }
        } else {
            parts.append(isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
        }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver's hint: what tapping the bullet does.
    static func hint(isCurrent: Bool, isExpanded: Bool) -> String {
        if isCurrent { return String(localized: "Shows the latest line") }
        return isExpanded ? String(localized: "Collapses the topic") : String(localized: "Shows the topic's transcript")
    }

    /// A day group's heading.
    static func dayTitle(_ day: Date, format: TopicTimelineFormat = .init(), now: Date = Date()) -> String {
        switch format.day(day, now: now) {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .date(let date): format.dayTitle(date, now: now)
        }
    }

    /// A conversation's heading: "Planning · 9:41 AM", or
    /// "Conversation · 9:41 AM" without a title.
    static func conversationTitle(_ conversation: TimelineConversation, format: TopicTimelineFormat = .init())
        -> String
    {
        let title = conversation.title ?? String(localized: "Conversation")
        return "\(title) · \(format.time(conversation.startedAt))"
    }
}
