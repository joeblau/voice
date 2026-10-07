import BlauCore
import Testing

@Suite("TopicPalette")
struct TopicPaletteTests {
    @Test func hasEightColors() {
        // The asset catalog has TopicDot0 ... TopicDot7; the app tests check
        // that each one exists.
        #expect(TopicPalette.count == 8)
    }

    /// Pinned: a topic's color must not change between app versions, so these
    /// values may only change together with a deliberate palette migration.
    @Test(arguments: [(0, 0), (1, 1), (7, 7), (8, 0), (42, 2), (0xAB12, 2), (65_535, 7)])
    func slotIsPinned(seed: Int, slot: Int) {
        #expect(TopicPalette.slot(forColorSeed: seed) == slot)
    }

    @Test(arguments: [-1, -8, -9, -65_535, Int.min, Int.max, 1 << 40])
    func anySeedMapsIntoThePalette(seed: Int) {
        #expect((0..<TopicPalette.count).contains(TopicPalette.slot(forColorSeed: seed)))
    }

    @Test func negativeSeedsKeepCycling() {
        #expect(TopicPalette.slot(forColorSeed: -1) == 7)
        #expect(TopicPalette.slot(forColorSeed: -8) == 0)
        #expect(TopicPalette.slot(forColorSeed: -9) == 7)
    }

    @Test func consecutiveSeedsUseEveryColor() {
        let slots = (100..<(100 + TopicPalette.count)).map(TopicPalette.slot(forColorSeed:))
        #expect(Set(slots).count == TopicPalette.count)
    }

    /// Seeds derived from random ids are uniform over `0..<65_536`; every
    /// color must cover exactly the same share of them.
    @Test func idDerivedSeedsAreSpreadEvenly() {
        var counts = [Int](repeating: 0, count: TopicPalette.count)
        for seed in 0..<65_536 {
            counts[TopicPalette.slot(forColorSeed: seed)] += 1
        }
        #expect(counts.allSatisfy { $0 == 65_536 / TopicPalette.count })
    }
}
