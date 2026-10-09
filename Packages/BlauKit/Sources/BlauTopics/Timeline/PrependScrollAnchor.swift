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
