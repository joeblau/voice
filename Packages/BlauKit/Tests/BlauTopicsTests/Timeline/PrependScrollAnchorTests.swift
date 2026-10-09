import BlauTopics
import Foundation
import Testing

/// Holding the rows on screen in place while a page of history lands above
/// them (#57, FB24968838).
@Suite("PrependScrollAnchor")
struct PrependScrollAnchorTests {
    private typealias Anchor = PrependScrollAnchor<String>

    @Test func theAnchorIsTheFirstRowOnScreenThatMovesWithTheContent() {
        let visible = ["now", "expanded", "day", "bullet"]
        // A pinned header sticks to the top of the window.
        let pinned: Set = ["now", "expanded"]
        #expect(Anchor.choose(from: visible) { !pinned.contains($0) } == "day")
        #expect(Anchor.choose(from: ["now"]) { !pinned.contains($0) } == nil)
    }

    @Test func aPageIsOnlyAskedForWithARowToHold() {
        let canAnchor: (String) -> Bool = { $0 != "pinned" }
        #expect(
            Anchor.request(settlingFirstWindow: false, wantsPage: true, visible: ["pinned", "day"], where: canAnchor)
                == .hold("day"))
        #expect(
            Anchor.request(settlingFirstWindow: false, wantsPage: false, visible: ["day"], where: canAnchor) == .wait,
            "the top isn't near")
        #expect(
            Anchor.request(settlingFirstWindow: false, wantsPage: true, visible: [], where: canAnchor) == .wait)
        // The first window settles at the latest line, under the bottom
        // anchor, whatever is on screen.
        #expect(
            Anchor.request(settlingFirstWindow: true, wantsPage: false, visible: ["pinned"], where: canAnchor)
                == .loadUnheld)
    }

    /// A long expanded topic fills the screen near the top of the loaded
    /// history: its bullet is pinned to the top of the window and its
    /// transcript's lines aren't timeline rows, so nothing on screen moves
    /// with the content. A page landing then would jump the rows down by
    /// its height (about 10,800 pt measured on iOS 26.5 and 27.0), so the
    /// view waits until a heading or a compressed bullet comes on screen.
    @Test func aLongExpandedTopicAloneOnScreenWaitsForTheNextRest() {
        typealias ItemID = TopicTimeline.ItemID
        let expanded = UUID()
        let compressed = UUID()
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let canAnchor: (ItemID) -> Bool = { $0.movesWithContent { $0 == expanded } }
        func request(_ visible: [ItemID]) -> PrependScrollAnchor<ItemID>.PageRequest {
            PrependScrollAnchor.request(
                settlingFirstWindow: false, wantsPage: true, visible: visible, where: canAnchor)
        }

        #expect(request([.topic(expanded)]) == .wait)
        #expect(request([.earlier, .topic(expanded)]) == .wait, "Earlier topics stays above the page")
        #expect(request([]) == .wait)
        // Scrolled on up: the headings above the topic are on screen.
        #expect(request([.earlier, .day(day), .topic(expanded)]) == .hold(.day(day)))
        #expect(request([.topic(expanded), .conversation(compressed)]) == .hold(.conversation(compressed)))
        // Compressed, the bullet moves with the content again.
        #expect(request([.topic(compressed)]) == .hold(.topic(compressed)))
    }

    @Test func theFirstReportPinsTheRowAndAsksForThePage() {
        var anchor = Anchor()
        #expect(!anchor.isActive)
        #expect(anchor.anchorMoved(to: 120) == nil, "nothing held, nothing to do")
        anchor.begin(anchor: "bullet")
        #expect(anchor.isActive)
        #expect(anchor.anchorMoved(to: 120) == .loadPage)
        #expect(anchor.pinnedY == 120)
    }

    /// The page landed without the offset moving: the row jumped down by
    /// the page's height, and the offset moves by as much. Then the lazy
    /// stack measures the rows it estimated and the row strays again, by
    /// less, either way.
    @Test func everyStrayIsPutBack() {
        var anchor = Anchor()
        anchor.begin(anchor: "bullet")
        _ = anchor.anchorMoved(to: 120)
        #expect(anchor.anchorMoved(to: 10_904) == .shift(by: 10_784))
        // Corrected.
        #expect(anchor.anchorMoved(to: 120) == nil)
        // The page's rows measured shorter than estimated.
        #expect(anchor.anchorMoved(to: -432) == .shift(by: -552))
        #expect(anchor.anchorMoved(to: 120.3) == nil, "rounding isn't a jump")
    }

    @Test func endingStopsHolding() {
        var anchor = Anchor()
        anchor.begin(anchor: "bullet")
        _ = anchor.anchorMoved(to: 120)
        anchor.end()
        #expect(!anchor.isActive)
        #expect(anchor.pinnedY == nil)
        #expect(anchor.anchorMoved(to: 900) == nil, "the user's own scrolling isn't corrected")
    }
}
