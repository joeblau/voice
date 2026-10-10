import BlauPersistence
import BlauRealtime
import BlauTelemetry
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
    /// The row at the top while older history is still to load (#57).
    static let earlier = "blau.timeline.earlier"
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
/// - The history loads a page at a time as the user scrolls up (#57,
///   `TopicHistoryPaging`), whole conversations at once, without moving
///   what is on screen (`PrependScrollAnchor`).
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

    @Environment(\.modelContext) private var modelContext
    /// Which part of the history is loaded. View state: every launch opens
    /// on the most recent page.
    @State private var paging = TopicHistoryPaging()

    init(focusConversationID: UUID, isRecording: Bool = false, onConnectAccount: (() -> Void)? = nil) {
        self.focusConversationID = focusConversationID
        self.isRecording = isRecording
        self.onConnectAccount = onConnectAccount
    }

    var body: some View {
        // Reads `paging` here, so a new page re-creates the window's
        // queries with the new cutoff.
        TopicTimelineWindow(
            paging: paging,
            focusConversationID: focusConversationID,
            isRecording: isRecording,
            onConnectAccount: onConnectAccount,
            loadOlder: loadOlder)
    }

    /// Grows the window by a page.
    private func loadOlder(oldestLoaded: TimelineTopic?) {
        let before = paging.cutoff
        do {
            guard try paging.loadOlder(in: modelContext, oldestLoaded: oldestLoaded) else { return }
            Signposts.ui.event("timeline.loadOlder")
            let after = paging.cutoff?.description ?? "none"
            Log.ui.notice(
                "Timeline window grew: cutoff \(before?.description ?? "none", privacy: .public) → \(after, privacy: .public)"
            )
        } catch {
            Log.ui.error("Couldn't load older topics: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The window's queries: the topics since the cutoff, whether any are
/// older, and the focus conversation. Re-created with each page.
private struct TopicTimelineWindow: View {
    let paging: TopicHistoryPaging
    let focusConversationID: UUID
    let isRecording: Bool
    let onConnectAccount: (() -> Void)?
    let loadOlder: (TimelineTopic?) -> Void

    @Query private var storedTopics: [Topic]
    @Query private var olderTopics: [Topic]
    @Query private var focusConversation: [Conversation]
    /// Dates a running conversation the store hasn't saved yet.
    @State private var openedAt = Date()

    init(
        paging: TopicHistoryPaging, focusConversationID: UUID, isRecording: Bool,
        onConnectAccount: (() -> Void)?, loadOlder: @escaping (TimelineTopic?) -> Void
    ) {
        self.paging = paging
        self.focusConversationID = focusConversationID
        self.isRecording = isRecording
        self.onConnectAccount = onConnectAccount
        self.loadOlder = loadOlder
        _storedTopics = Query(paging.windowDescriptor)
        _olderTopics = Query(paging.olderDescriptor)
        _focusConversation = Query(TopicTimeline.conversation(focusConversationID))
    }

    var body: some View {
        let focus =
            focusConversation.first.map(TimelineConversation.init)
            ?? TimelineConversation(id: focusConversationID, startedAt: openedAt)
        let bullets = storedTopics.compactMap(TimelineTopic.init)
        // Newest first: the last is the window's oldest.
        let oldest = bullets.last
        TopicTimelineScrollView(
            timeline: TopicTimeline(
                topics: bullets, focus: focus,
                hasOlderHistory: paging.hasOlder(fetchedCount: storedTopics.count, olderCount: olderTopics.count),
                cutoff: paging.cutoff),
            needsCutoff: paging.needsCutoff(fetchedCount: storedTopics.count),
            isRecording: isRecording,
            onConnectAccount: onConnectAccount,
            loadOlder: { loadOlder(oldest) }
        )
        // A new conversation's stand-in bullet is dated when it became the
        // focus, not when the screen first opened.
        .onChange(of: focusConversationID) { openedAt = Date() }
    }
}

/// What paging follows without making the view depend on it: which rows are
/// on screen and whether the scroll view is at rest change every frame of
/// a scroll, and `@State` that changes that often would rebuild the
/// timeline's rows each frame.
@MainActor
private final class PrependScrollTracker {
    /// The row held in place while a page lands.
    var anchor = PrependScrollAnchor<TopicTimeline.ItemID>()
    /// The scroll targets on screen, as last reported.
    var visible: [TopicTimeline.ItemID] = []
    /// Whether the scroll view is at rest: pages only load then, so the
    /// held row only moves because of layout.
    var isIdle = true
    /// Whether the user has scrolled since the timeline appeared. Pages only
    /// load after that: while the screen opens, its geometry passes through
    /// the top before the bottom anchor applies.
    var hasScrolled = false
    /// Visible bullets' actual positions, before a tap changes their rows.
    var bulletPositions: [UUID: CGFloat] = [:]
    /// The bullet held while its detail and lazy transcript are laid out.
    var expandingBullet: (id: UUID, y: CGFloat)?
    /// Ends a page's hold once it has settled, or gives up on it.
    var timeout: Task<Void, Never>?
    /// Finishes Now's trip to the latest line (`finishReturningToNow`).
    var returnToNow: Task<Void, Never>?
    /// When the current hold began, to cap it.
    var holdStarted: ContinuousClock.Instant?
    /// How far the current page's rows were put back, for the log.
    var corrections: (count: Int, distance: Double) = (0, 0)
    /// The scroll view's `UIScrollView`, to put the rows back in the frame
    /// they strayed.
    let scrollView = EnclosingScrollView()
}

/// The scroll view, its position and which bullets are expanded. Separate
/// from `TopicTimelineView` so scrolling doesn't rebuild the timeline from
/// the store.
private struct TopicTimelineScrollView: View {
    let timeline: TopicTimeline
    /// The first window just filled: settle its cutoff now.
    let needsCutoff: Bool
    let isRecording: Bool
    let onConnectAccount: (() -> Void)?
    /// Loads the next page of history.
    let loadOlder: () -> Void

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
    /// Whether the top of the loaded history is close enough to load the
    /// next page.
    @State private var isNearTop = false
    /// A page is being asked for or landing.
    @State private var isPrepending = false
    /// The row held in place while a page lands: it reports where it is.
    @State private var anchorID: TopicTimeline.ItemID?
    @State private var tracker = PrependScrollTracker()
    /// Taps on a bullet at the latest line whose expansion is still laying
    /// out. While any is pending, size changes anchor to the top so the
    /// tapped bullet stays put.
    @State private var topAnchorHolds = 0
    @State private var position = ScrollPosition(idType: TopicTimeline.ItemID.self)
    @Namespace private var rotor

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if timeline.hasOlderHistory {
                    EarlierHistoryRow()
                        .id(TopicTimeline.ItemID.earlier)
                }
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
            .findingEnclosingScrollView(tracker.scrollView)
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
        .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // `visibleRect` spans the whole frame, under the bars too (the
            // container size leaves the insets out), so the last line of
            // content shows at its bottom less the bottom inset.
            let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
            return visibleBottom >= geometry.contentSize.height - ChatTranscriptLayout.bottomThreshold
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            TopicHistoryPaging.isNearTop(
                offset: geometry.contentOffset.y, topInset: geometry.contentInsets.top,
                viewportHeight: geometry.visibleRect.height)
        } action: { _, nearTop in
            isNearTop = nearTop
            loadOlderIfNeeded()
        }
        .onScrollTargetVisibilityChange(idType: TopicTimeline.ItemID.self) { visible in
            tracker.visible = visible
            // At rest, the rows on screen change when a bullet expands or
            // compresses: a page that waited for a row to hold may load now.
            loadOlderIfNeeded()
        }
        .onScrollPhaseChange { _, phase in
            tracker.isIdle = phase == .idle
            tracker.hasScrolled = tracker.hasScrolled || !tracker.isIdle
            if phase == .tracking || phase == .interacting {
                // The user took over: Now stops finishing its trip.
                tracker.returnToNow?.cancel()
                tracker.expandingBullet = nil
            }
            if tracker.isIdle {
                loadOlderIfNeeded()
            } else if tracker.anchor.isActive {
                // The finger (or Now) moves the rows now; the held row's
                // position no longer says anything about the layout.
                endPrepend()
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if !isAtBottom {
                    VStack(spacing: 8) {
                        // Grok's words stay on screen while its row is out
                        // of view (#81).
                        LiveCaption(model: environment.chat, conversationID: timeline.current?.conversationID)
                        NowButton(action: returnToNow)
                    }
                    .padding(.bottom, 12)
                    .transition(Motion.slide(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            // Only the floating controls animate, not the timeline's own
            // layout when `isAtBottom` flips.
            .animation(reduceMotion ? nil : .snappy, value: isAtBottom)
        }
        // VoiceOver hears when a new topic opens or its title is refined.
        .announcesTopicChanges(current: timeline.current, renamedByUser: editor.renamedTopicIDs)
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
        // A sync that brings older topics, or a first window that just
        // filled, asks for a page.
        .onChange(of: timeline.hasOlderHistory) { loadOlderIfNeeded() }
        .onChange(of: needsCutoff, initial: true) { loadOlderIfNeeded() }
        // A page settled: the top may still be near.
        .onChange(of: isPrepending) { _, prepending in
            if !prepending { loadOlderIfNeeded() }
        }
    }

    /// At the latest line, growth keeps it in view; reading history, the
    /// position holds while the transcript below grows and labels change;
    /// while a page of history lands above, growth goes above the rows on
    /// screen (and the held row puts back whatever the scroll view doesn't).
    private var sizeChangeAnchor: UnitPoint {
        if isPrepending { return .bottom }
        return isAtBottom && topAnchorHolds == 0 ? .bottom : .top
    }

    @ViewBuilder
    private func row(for item: TopicTimeline.Item) -> some View {
        switch item {
        case .day(let day, let rail):
            TimelineDayHeader(day: day, rail: rail)
                .prependAnchor(item.id == anchorID, moved: anchorMoved)
        case .conversation(let conversation, let rail):
            TimelineConversationHeader(conversation: conversation, rail: rail)
                .prependAnchor(item.id == anchorID, moved: anchorMoved)
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
                        membership: timeline.membership(in: topic.conversationID),
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
                .prependAnchor(item.id == anchorID, moved: anchorMoved)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .global).minY
                } action: { y in
                    bulletMoved(topic.id, to: y)
                }
                .onDisappear { tracker.bulletPositions[topic.id] = nil }
            }
        }
    }

    // MARK: Paging

    /// Loads the next page when the top of the loaded history is near (or
    /// the first window needs its cutoff) and the scroll view is at rest,
    /// unless one is still landing.
    private func loadOlderIfNeeded() {
        guard !isPrepending, tracker.isIdle else { return }
        let request = PrependScrollAnchor.request(
            settlingFirstWindow: needsCutoff,
            wantsPage: timeline.hasOlderHistory && isNearTop && tracker.hasScrolled,
            visible: tracker.visible,
            where: canAnchor)
        switch request {
        case .wait:
            // Nothing to load, or nothing on screen to hold: a page landing
            // now would jump the rows down by its height. The next rest, or
            // the next change of the rows on screen, asks again.
            break
        case .loadUnheld:
            // Settling the first window, at launch: at the latest line,
            // where the bottom anchor keeps the rows on screen.
            isPrepending = true
            loadOlder()
            endPrepend(after: Self.settleHold)
        case .hold(let anchor):
            isPrepending = true
            tracker.holdStarted = .now
            tracker.corrections = (0, 0)
            // The row reports where it is first; then the page loads
            // (`anchorMoved`).
            tracker.anchor.begin(anchor: anchor)
            anchorID = anchor
            endPrepend(after: Self.maximumHold)
        }
    }

    /// Whether a row on screen can be held in place: not a pinned section
    /// header (the current topic's, or an expanded one's), which sticks to
    /// the top of the window instead of moving with the content.
    private func canAnchor(_ id: TopicTimeline.ItemID) -> Bool {
        id.movesWithContent { expansion.isExpanded($0, current: timeline.currentTopicID) }
    }

    /// The held row's top in the window changed.
    private func anchorMoved(to y: CGFloat) {
        switch tracker.anchor.anchorMoved(to: y) {
        case .loadPage:
            loadOlder()
            endPrepend(after: Self.settleHold)
        case .shift(let distance):
            guard tracker.isIdle else { return }
            // The page landed without the offset moving with it
            // (FB24968838), or the lazy stack measured rows it had
            // estimated: put the rows back, in this frame.
            if tracker.scrollView.shiftContent(by: distance) {
                tracker.corrections.count += 1
                tracker.corrections.distance += distance
                Signposts.ui.event("timeline.prependCorrected")
            } else {
                // No `UIScrollView` found behind the `ScrollView`: nothing
                // can put the rows back.
                Log.ui.error("Timeline page landed uncorrected: no scroll view, \(Int(distance), privacy: .public) pt")
            }
            // Hold until the layout has been still for a moment.
            endPrepend(after: Self.settleHold)
        case nil:
            break
        }
    }

    /// Stops holding the page `delay` from now, or sooner if the cap on a
    /// hold is reached first.
    ///
    /// The task only touches `@State` and the tracker: this view's `let`
    /// properties (the timeline, `needsCutoff`) are the ones it had when
    /// the task started. Ending the hold flips `isPrepending`, and its
    /// `onChange`, run on a current body, asks for the next page.
    private func endPrepend(after delay: Duration) {
        tracker.timeout?.cancel()
        var delay = delay
        if let started = tracker.holdStarted {
            delay = min(delay, max(.zero, started + Self.maximumHold - .now))
        }
        tracker.timeout = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            endPrepend()
        }
    }

    private func endPrepend() {
        tracker.timeout?.cancel()
        tracker.timeout = nil
        if tracker.anchor.isActive || tracker.corrections.count > 0 {
            let (count, distance) = tracker.corrections
            Log.ui.notice(
                "Timeline page held in place: \(count, privacy: .public) corrections, \(Int(distance), privacy: .public) pt"
            )
        }
        tracker.anchor.end()
        tracker.holdStarted = nil
        tracker.corrections = (0, 0)
        if anchorID != nil { anchorID = nil }
        isPrepending = false
    }

    /// How long the layout has to stay still after a page lands, or after a
    /// correction, before the hold ends.
    private static let settleHold = Duration.milliseconds(300)
    /// The longest a page is held, however its layout behaves.
    private static let maximumHold = Duration.seconds(2)

    // MARK: Taps

    /// Lazy rows may change the content above the tapped bullet as they are
    /// measured. Hold its rendered position, rather than an estimated offset.
    private func bulletMoved(_ id: UUID, to y: CGFloat) {
        tracker.bulletPositions[id] = y
        guard let held = tracker.expandingBullet, held.id == id, tracker.isIdle else { return }
        let distance = y - held.y
        if abs(distance) > 0.5 {
            _ = tracker.scrollView.shiftContent(by: distance)
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
            // Collapsing at the latest line should keep following that line.
            if isAtBottom, let current = timeline.currentTopicID {
                holdBullet(current, whileToggling: topic.id)
                return
            }
            toggleExpansion(of: topic.id)
            return
        } else {
            expansionTimer.began(topic.id)
        }
        guard isAtBottom else {
            toggleExpansion(of: topic.id)
            return
        }
        // Hold the tapped bullet while its transcript opens below it, even
        // at the latest line. The top anchor and rendered-position hold are
        // installed in the same transaction as the detail; deferring the
        // expansion to another main-actor task adds a layout/scheduling turn
        // to tap latency. Once the lazy rows settle, the geometry decides
        // again whether to follow the latest line.
        holdBullet(topic.id, whileToggling: topic.id)
    }

    private func holdBullet(_ anchor: UUID, whileToggling topic: UUID) {
        topAnchorHolds += 1
        // A previous Now target must stop following the bottom while this
        // topic changes height; its rendered bullet supplies the anchor.
        // Initial offset and user scrolling leave no requested target. A
        // fresh binding in that case only triggers another scroll update.
        if position.edge != nil || position.point != nil || position.viewID != nil {
            position = ScrollPosition(idType: TopicTimeline.ItemID.self)
        }
        if let y = tracker.bulletPositions[anchor] { tracker.expandingBullet = (anchor, y) }
        toggleExpansion(of: topic)
        Task { @MainActor in
            try? await Task.sleep(for: Self.topAnchorHold)
            topAnchorHolds -= 1
            if topAnchorHolds == 0 { tracker.expandingBullet = nil }
        }
    }

    /// How long a tap at the latest line holds its bullet while lazy rows
    /// settle.
    private static let topAnchorHold = Duration.milliseconds(400)

    private func toggleExpansion(of id: UUID) {
        // A height animation also animates SwiftUI's scroll offset, defeating
        // the same-frame hold. Insert the detail immediately; Now still
        // returns with its spring and refined titles still cross-fade.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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
        finishReturningToNow()
    }

    /// From deep in a long history (#57) the lazy stack measures the rows
    /// it estimated on the way down, so the content grows under the
    /// animation and it stops short of the end: once the animation is
    /// over, finish the trip without animation, measuring again until the
    /// latest line is in view. A touch in the meantime cancels it.
    ///
    /// On the `UIScrollView`: `position` already says "bottom edge", so
    /// asking SwiftUI again does nothing. (Reads only `@State` and the
    /// tracker, which are current even from an older body.)
    private func finishReturningToNow() {
        tracker.returnToNow?.cancel()
        tracker.returnToNow = Task { @MainActor in
            try? await Task.sleep(for: Self.returnAnimation)
            for _ in 0..<Self.returnAttempts where !isAtBottom {
                guard !Task.isCancelled, tracker.scrollView.scrollToBottom() else { return }
                // Let the layout and the scroll geometry catch up.
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// How long Now's animation runs before it checks where it landed.
    private static let returnAnimation = Duration.milliseconds(700)
    /// How many times Now scrolls again to reach the latest line.
    private static let returnAttempts = 10
}

/// The top of the loaded history while older topics are still to load: a
/// bullet-high row with a spinner on the rail. The next page usually lands
/// before it scrolls into view.
private struct EarlierHistoryRow: View {
    @ScaledMetric(relativeTo: .body) private var rowHeight = TopicTimelineLayout.compressedRowHeight

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Earlier topics")
                .brandTextStyle(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .padding(.leading, TopicTimelineLayout.textInset)
        .padding(.trailing)
        .timelineRail(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading earlier topics")
        .accessibilityIdentifier(TopicTimelineAccessibility.earlier)
    }
}

extension View {
    /// While `isAnchor`, reports this row's top in the window each time it
    /// changes: the row held in place while a page of history lands. Every
    /// other row reports nothing, so scrolling costs one frame read per row.
    fileprivate func prependAnchor(_ isAnchor: Bool, moved: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat?.self) { proxy in
            isAnchor ? proxy.frame(in: .global).minY : nil
        } action: { y in
            if let y { moved(y) }
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
            .accessibilityValue(
                timer.last.map {
                    "\(timer.measurementCount):" + String(format: "%.1f", $0.latency / .milliseconds(1))
                } ?? ""
            )
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

#Preview("Timeline, long history") {
    let environment = AppEnvironment.preview()
    PersistenceGate(persistence: environment.persistence) {
        TopicTimelinePreview()
    }
    .appEnvironment(environment)
    .task { await TopicTimelineFixture.seedLongHistory(topicCount: 2_000, into: environment.persistence) }
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
