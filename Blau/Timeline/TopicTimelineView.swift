import BlauPersistence
import BlauRealtime
import BlauTopics
import SwiftData
import SwiftUI

/// The accessibility identifiers UI tests use for the topic timeline.
enum TopicTimelineAccessibility {
    /// The timeline's rows, inside the main screen's scroll view
    /// (`MainScreenAccessibility.content`).
    static let timeline = "blau.timeline"
    /// The current topic's bullet.
    static let currentTopic = "blau.timeline.topic.current"
    /// Any other topic's bullet, compressed or expanded.
    static let topic = "blau.timeline.topic"
    /// An expanded older topic's summary.
    static let summary = "blau.timeline.topic.summary"
    /// A day group's heading.
    static let day = "blau.timeline.day"
    /// A conversation's heading.
    static let conversation = "blau.timeline.conversation"
    /// The "Now" pill that returns to the current topic.
    static let now = "blau.timeline.now"
}

/// The signature screen (#56): every topic a bullet on one vertical rail,
/// the current topic at the bottom with its live transcript, and the
/// history above it.
///
/// - It opens on the current topic, anchored at the latest line. Its bullet
///   is a pinned section header, so it stays in view above its transcript
///   however long that gets.
/// - Older topics are compressed to one fixed-height row (dot, title, time,
///   duration) until tapped; tapping expands one inline and tapping again
///   compresses it (`TopicExpansion`, view state only). An expanded topic
///   shows its detail (#58, `TopicDetailHeader`): summary, span, Continue,
///   Share and the edit menu, then its transcript.
/// - Swiping down scrolls up into the history: bullets grouped by day and
///   conversation, newest at the bottom. Swiping back, the Now pill or the
///   current bullet return to the latest line with a spring.
/// - Titles change in place: provisional titles are italic and cross-fade
///   into the refined ones. Compressed rows don't change height, and while
///   the user reads history the scroll view anchors to the top, so a label
///   changing anywhere never moves what they're reading.
///
/// A lazy stack in a bottom-anchored scroll view, never an inverted one
/// (that breaks VoiceOver and context menus). The ordering and grouping
/// rules are BlauKit's `TopicTimeline`, tested on the Mac.
struct TopicTimelineView: View {
    /// The running conversation, or else the most recent one.
    let focusConversationID: UUID
    /// The current topic's dot pulses while recording.
    var isRecording = false
    /// Opens the xAI key onboarding step. Its button follows the current
    /// topic's rows while no usable key is stored.
    var onConnectAccount: (() -> Void)?

    @Query private var storedTopics: [Topic]
    @Query private var focusConversation: [Conversation]
    /// Dates a running conversation the store hasn't saved yet.
    @State private var openedAt = Date()

    init(focusConversationID: UUID, isRecording: Bool = false, onConnectAccount: (() -> Void)? = nil) {
        self.focusConversationID = focusConversationID
        self.isRecording = isRecording
        self.onConnectAccount = onConnectAccount
        _storedTopics = Query(TopicTimeline.recentTopics())
        _focusConversation = Query(TopicTimeline.conversation(focusConversationID))
    }

    var body: some View {
        let focus =
            focusConversation.first.map(TimelineConversation.init)
            ?? TimelineConversation(id: focusConversationID, startedAt: openedAt)
        TopicTimelineScrollView(
            timeline: TopicTimeline(topics: storedTopics.compactMap(TimelineTopic.init), focus: focus),
            isRecording: isRecording,
            onConnectAccount: onConnectAccount
        )
        // A new conversation's stand-in bullet is dated when it became the
        // focus, not when the screen first opened.
        .onChange(of: focusConversationID) { openedAt = Date() }
    }
}

/// The scroll view, its position and which bullets are expanded. Separate
/// from `TopicTimelineView` so scrolling doesn't rebuild the timeline from
/// the store.
private struct TopicTimelineScrollView: View {
    let timeline: TopicTimeline
    let isRecording: Bool
    let onConnectAccount: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.continueTopic) private var continueTopic
    @State private var expansion = TopicExpansion()
    /// Rename, merge and split from any bullet, detail or line (#54, #58).
    @State private var editor = TopicEditor()
    /// Tap-to-expand latency (#58): the `timeline.expand` signpost.
    @State private var expansionTimer = TopicExpansionTimer()
    /// Whether the latest line is in view. Only the scroll geometry writes
    /// it: `onScrollGeometryChange` reports changes, so a value set by hand
    /// that the geometry still agrees with would never be corrected.
    @State private var isAtBottom = true
    /// Taps on a bullet at the latest line whose expansion is still laying
    /// out. While any is pending, size changes anchor to the top so the
    /// tapped bullet stays put.
    @State private var topAnchorHolds = 0
    @State private var position = ScrollPosition(idType: TopicTimeline.ItemID.self)
    @Namespace private var rotor

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(timeline.items) { item in
                    row(for: item)
                }
                if let onConnectAccount, environment.xai.account.needsKeyEntry {
                    Button("Connect Your xAI Account", action: onConnectAccount)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(XAIKeyIdentifiers.openOnboarding)
                        .padding(.top)
                }
            }
            .padding(.vertical, 12)
            .scrollTargetLayout()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Topics")
            .accessibilityIdentifier(TopicTimelineAccessibility.timeline)
        }
        // On the scroll view itself, not on this view: an identifier set
        // outside the overlay would also replace the Now pill's.
        .accessibilityIdentifier(MainScreenAccessibility.content)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // At the latest line, growth keeps it in view; reading history, the
        // position holds while the transcript below grows and labels change.
        .defaultScrollAnchor(isAtBottom && topAnchorHolds == 0 ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // `visibleRect` spans the whole frame, under the bars too (the
            // container size leaves the insets out), so the last line of
            // content shows at its bottom less the bottom inset.
            let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
            return visibleBottom >= geometry.contentSize.height - ChatTranscriptLayout.bottomThreshold
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                NowButton(action: returnToNow)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: isAtBottom)
        .accessibilityRotor("Topics") {
            ForEach(timeline.topics) { topic in
                AccessibilityRotorEntry(Text(verbatim: topic.title), id: topic.id, in: rotor)
            }
        }
        .onChange(of: timeline.currentTopicID) { previous, current in
            expansion.currentChanged(from: previous, to: current, keepPreviousOpen: !isAtBottom)
        }
        .onChange(of: timeline.topics.map(\.id)) { _, ids in
            expansion.retain(only: Set(ids))
            expansionTimer.retain(only: Set(ids))
        }
        .topicEditorAlerts(editor)
        .overlay(alignment: .topLeading) {
            if environment.kind == .uiTest {
                ExpandLatencyProbe(timer: expansionTimer)
            }
        }
    }

    @ViewBuilder
    private func row(for item: TopicTimeline.Item) -> some View {
        switch item {
        case .day(let day, let rail):
            TimelineDayHeader(day: day, rail: rail)
        case .conversation(let conversation, let rail):
            TimelineConversationHeader(conversation: conversation, rail: rail)
        case .topic(let topic, let placement):
            let isExpanded = expansion.isExpanded(topic.id, current: timeline.currentTopicID)
            Section {
                if isExpanded {
                    if !placement.isCurrent {
                        TopicDetailHeader(
                            topic: topic, placement: placement, editor: editor,
                            onContinue: continueAction(for: topic)
                        ) {
                            expansionTimer.appeared(topic.id)
                        }
                    }
                    TopicTranscriptRows(
                        topic: topic,
                        membership: TopicMembership(topics: timeline.topics(in: topic.conversationID)),
                        rail: placement.railBelow,
                        isCurrent: placement.isCurrent,
                        editor: editor)
                }
            } header: {
                TopicBullet(
                    topic: topic, placement: placement, isExpanded: isExpanded,
                    isRecording: isRecording && placement.isCurrent, editor: editor,
                    onContinue: continueAction(for: topic)
                ) {
                    tap(topic, placement: placement)
                }
                .accessibilityRotorEntry(id: topic.id, in: rotor)
            }
        }
    }

    /// The current bullet returns to the latest line; any other expands or
    /// compresses.
    private func tap(_ topic: TimelineTopic, placement: TopicTimeline.Placement) {
        guard !placement.isCurrent else {
            returnToNow()
            return
        }
        // The measurement starts at the tap, before the state changes, so it
        // covers the whole update: the transaction, the new rows' fetch and
        // layout (#58).
        if expansion.isExpanded(topic.id, current: timeline.currentTopicID) {
            expansionTimer.cancelled(topic.id)
        } else {
            expansionTimer.began(topic.id)
        }
        guard isAtBottom else {
            toggleExpansion(of: topic.id)
            return
        }
        // Anchor to the top first, so the tapped bullet stays where it is and
        // its transcript opens below it, even at the latest line. The anchor
        // must be in place before the content grows: in the same update the
        // bottom anchor would still push the bullet up. It holds until the
        // animation and the lazy rows' measuring are done, then the geometry
        // decides again: collapsing at the latest line stays there (and keeps
        // following new lines), expanding scrolls it out of view.
        topAnchorHolds += 1
        Task { @MainActor in
            toggleExpansion(of: topic.id)
            try? await Task.sleep(for: Self.topAnchorHold)
            topAnchorHolds -= 1
        }
    }

    /// How long a tap at the latest line keeps the top anchor: the
    /// expansion's animation and a little more.
    private static let topAnchorHold = Duration.milliseconds(400)

    private func toggleExpansion(of id: UUID) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            _ = expansion.toggle(id, current: timeline.currentTopicID)
        }
    }

    /// Continue This Topic (#58), where a conversation can be started and
    /// the topic isn't the one being recorded.
    private func continueAction(for topic: TimelineTopic) -> (() -> Void)? {
        guard let continueTopic else { return nil }
        if topic.isOpen, topic.conversationID == environment.chat.conversationID?.rawValue { return nil }
        return {
            Task { @MainActor in
                await continueTopic(topic)
                returnToNow()
            }
        }
    }

    /// Back to the current topic's latest line, with a spring.
    private func returnToNow() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)) {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// UI tests only: the latest tap-to-expand latency, in milliseconds, as an
/// element's value (`TopicDetailAccessibility.expandLatency`), so a test can
/// check the 100 ms target (#58) on what the app itself measured.
private struct ExpandLatencyProbe: View {
    let timer: TopicExpansionTimer

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Expand latency")
            .accessibilityValue(timer.last.map { String(format: "%.1f", $0.latency / .milliseconds(1)) } ?? "")
            .accessibilityIdentifier(TopicDetailAccessibility.expandLatency)
            .allowsHitTesting(false)
    }
}

/// Returns to the current topic. Floats above the bottom bar while the user
/// is scrolled away from the latest line.
private struct NowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Now", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(TopicTimelineAccessibility.now)
        .accessibilityHint("Returns to the current topic")
    }
}

// MARK: - Previews

#Preview("Timeline") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        TopicTimelinePreview()
    }
    .appEnvironment(environment)
    .task { await TopicTimelineFixture.seed(topicCount: 12, into: environment.persistence) }
}

#Preview("Timeline, recording") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        TopicTimelinePreview(isRecording: true)
    }
    .appEnvironment(environment)
    .task { await TopicTimelineFixture.seed(topicCount: 12, into: environment.persistence) }
}

#Preview("Timeline, largest text") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        TopicTimelinePreview()
    }
    .appEnvironment(environment)
    .task { await TopicTimelineFixture.seed(topicCount: 12, into: environment.persistence) }
    .dynamicTypeSize(.accessibility5)
}

/// The latest conversation in the preview store.
private struct TopicTimelinePreview: View {
    var isRecording = false
    @Query(ChatTranscript.latestConversation) private var conversations: [Conversation]

    var body: some View {
        if let conversation = conversations.first {
            TopicTimelineView(focusConversationID: conversation.id, isRecording: isRecording)
        }
    }
}
