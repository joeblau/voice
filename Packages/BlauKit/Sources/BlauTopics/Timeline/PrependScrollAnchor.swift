import Foundation

/// Keeps the rows on screen in place while a page of older history lands
/// above them (#57).
///
/// A scroll view that grows above the visible area has to move its content
/// offset down by the growth, or the rows on screen jump down by the
/// page's height. SwiftUI's lazy stacks don't (FB24968838: measured on
/// iOS 27, and on iOS 26 too for a page this size), and once they lay out
/// the rows they estimated they shift the content again. So the timeline
/// doesn't trust the scroll view: before it asks for a page it pins one
/// row on screen (the **anchor**) at its position in the window, and until
/// the page has settled it moves the content offset by however far that
/// row strays.
///
/// The view only loads pages while the scroll view is idle, so any
/// movement of the anchor while it is held comes from layout, never from
/// the user's finger, and the correction is exact. The value type holds
/// the decisions; the view applies them to the `UIScrollView`.
public struct PrependScrollAnchor<ID: Hashable & Sendable>: Equatable, Sendable {
    /// What the view does after the anchor row reports its position.
    public enum Action: Equatable, Sendable {
        /// The anchor's position is pinned: ask for the page now.
        case loadPage
        /// The anchor strayed by `by` points (down is positive): move the
        /// content offset by as much to put it back.
        case shift(by: Double)
    }

    /// What the view does when the scroll view comes to rest, or the top of
    /// the loaded history comes near.
    public enum PageRequest: Equatable, Sendable {
        /// Don't load now: no page is wanted, or no row on screen can be
        /// held (only a pinned header, such as a long expanded topic's,
        /// with its transcript below). A page that landed then would push
        /// the rows on screen down by its height with nothing to put them
        /// back, so the view waits for the next rest, when a heading or a
        /// compressed bullet may be on screen.
        case wait
        /// Load without holding a row. Only while the first window settles
        /// its cutoff at launch: the screen is at the latest line, where the
        /// bottom size-change anchor keeps the rows on screen.
        case loadUnheld
        /// Hold this row in place (``begin(anchor:)``), then load once it
        /// reported its position.
        case hold(ID)
    }

    /// Movement smaller than this is rounding, not a jump.
    public static var tolerance: Double { 0.5 }

    /// The row held in place, while a page is asked for or landing.
    public private(set) var anchorID: ID?
    /// Where the anchor row belongs in the window, once it reported.
    public private(set) var pinnedY: Double?

    public init() {}

    /// Whether a page is being held in place.
    public var isActive: Bool { anchorID != nil }

    /// The row to hold: the first of the rows on screen, top to bottom,
    /// that stays where the content puts it. (A pinned section header, the
    /// current topic's or an expanded one's, sticks to the top of the
    /// window instead, so its position says nothing about the content.)
    public static func choose(from visible: [ID], where canAnchor: (ID) -> Bool) -> ID? {
        visible.first(where: canAnchor)
    }

    /// Whether to ask for a page, and how to hold the rows on screen while
    /// it lands.
    ///
    /// - Parameters:
    ///   - settlingFirstWindow: The first window just filled and needs its
    ///     cutoff.
    ///   - wantsPage: There is older history, its top is near, and the user
    ///     has scrolled.
    ///   - visible: The rows on screen, top to bottom.
    ///   - canAnchor: Whether a row moves with the content (see
    ///     ``choose(from:where:)``).
    public static func request(
        settlingFirstWindow: Bool, wantsPage: Bool, visible: [ID], where canAnchor: (ID) -> Bool
    ) -> PageRequest {
        if settlingFirstWindow { return .loadUnheld }
        guard wantsPage, let anchor = choose(from: visible, where: canAnchor) else { return .wait }
        return .hold(anchor)
    }

    /// Starts holding `anchor`: the view asks it for its position, then
    /// for the page.
    public mutating func begin(anchor: ID) {
        anchorID = anchor
        pinnedY = nil
    }

    /// The anchor row's top in the window, each time it changes.
    ///
    /// - Returns: ``Action/loadPage`` for the first report, then
    ///   ``Action/shift(by:)`` whenever the row strayed from it.
    public mutating func anchorMoved(to y: Double) -> Action? {
        guard anchorID != nil else { return nil }
        guard let pinnedY else {
            pinnedY = y
            return .loadPage
        }
        let strayed = y - pinnedY
        return abs(strayed) > Self.tolerance ? .shift(by: strayed) : nil
    }

    /// Stops holding: the page settled, or the user started scrolling.
    public mutating func end() {
        anchorID = nil
        pinnedY = nil
    }
}

extension TopicTimeline.ItemID {
    /// Whether the row moves with the content, so it can be held in place
    /// while a page lands (``PrependScrollAnchor``).
    ///
    /// Day and conversation headings and compressed bullets do. An expanded
    /// bullet is a pinned section header: it sticks to the top of the
    /// window while its transcript scrolls under it, so its position says
    /// nothing about the content. "Earlier topics" stays at the top, above
    /// the page that lands. The transcript's lines aren't timeline rows, so
    /// the scroll view never reports them.
    ///
    /// - Parameter isExpanded: Whether a topic is expanded, the current
    ///   topic included.
    public func movesWithContent(isExpanded: (UUID) -> Bool) -> Bool {
        switch self {
        case .earlier: false
        case .day, .conversation: true
        case .topic(let topic): !isExpanded(topic)
        }
    }
}
