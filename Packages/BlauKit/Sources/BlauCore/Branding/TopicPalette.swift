/// Which of the topic timeline's dot colors a topic gets (#82).
///
/// A topic's `colorSeed` (stored on `Topic` in BlauPersistence: the first two
/// bytes of its id unless set explicitly) picks one of `count` palette slots.
/// The app maps a slot to its `TopicDot<slot>` color set in the asset catalog
/// (docs/branding.md), which holds the light and dark variant of each color.
///
/// The seed syncs through iCloud and the slot is derived from it on every
/// device, so the same topic has the same color everywhere. That makes this
/// mapping part of what the stored data means: changing `count` or
/// `slot(forColorSeed:)` recolors every existing topic. Add colors only in a
/// release that accepts that, and keep the mapping a pure function of the seed.
public enum TopicPalette {
    /// The number of dot colors. Seeds from random ids are uniform over
    /// `0..<65_536`, which `count` divides, so every color is equally likely.
    public static let count = 8

    /// The palette slot, in `0..<count`, for a topic's color seed.
    ///
    /// Any `Int` is accepted, including negative seeds a future schema or a
    /// manual edit might store: the result is the non-negative remainder, so
    /// consecutive seeds (a test fixture, a user's picks) cycle through every
    /// color.
    public static func slot(forColorSeed seed: Int) -> Int {
        let remainder = seed % count
        return remainder < 0 ? remainder + count : remainder
    }
}
