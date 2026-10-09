import BlauTopics
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
