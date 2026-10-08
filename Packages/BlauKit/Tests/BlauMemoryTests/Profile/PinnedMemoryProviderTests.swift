import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: what is pinned to each session")
struct PinnedMemoryProviderTests {
    typealias Support = ExtractionTestSupport

    @Test func pinsTheProfileAndTheTopFacts() async throws {
        let fixture = try ProfileFixture()
        try fixture.addProfileDocument(title: "About me", body: "I'm Joe.")
        try fixture.addBlock("Work: The user runs Acme.", at: Support.t0)
        try fixture.addFacts([("Acme", "raised", "a seed round")])
        try fixture.addFacts([(nil, "works at", "Acme")], origin: .user, validFrom: Support.t0.addingTimeInterval(-60))

        let pinned = await PinnedMemoryProvider(store: fixture.store).pinnedMemory()

        #expect(pinned.profile == "In the user's own words:\nAbout me:\nI'm Joe.\n\nWork: The user runs Acme.")
        #expect(pinned.facts.map(\.text) == ["User works at Acme", "Acme raised a seed round"])
        #expect(pinned.facts.first?.since == Support.t0.addingTimeInterval(-60))
    }

    @Test func emptyMemoryPinsNothing() async throws {
        let fixture = try ProfileFixture()
        #expect(await PinnedMemoryProvider(store: fixture.store).pinnedMemory() == .empty)
    }

    @Test func limitsTheFacts() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts((1...50).map { (nil, "likes", "thing \($0)") })
        let pinned = await PinnedMemoryProvider(store: fixture.store, factLimit: 40).pinnedMemory()
        #expect(pinned.facts.count == 40)
    }

    @Test func cachesUntilInvalidatedOrStale() async throws {
        let fixture = try ProfileFixture()
        try fixture.addBlock("Work: Stripe.", at: Support.t0)
        let clock = ManualClock(now: Support.t0)
        let provider = PinnedMemoryProvider(store: fixture.store, maximumAge: .seconds(300), clock: clock)
        #expect(await provider.pinnedMemory().profile == "Work: Stripe.")

        _ = try await fixture.store.writeProfileBlock(
            key: ProfileBlock.userKey, text: "Work: Acme.", expectedText: "Work: Stripe.", at: Support.t0)
        #expect(await provider.pinnedMemory().profile == "Work: Stripe.")

        await provider.invalidate()
        #expect(await provider.pinnedMemory().profile == "Work: Acme.")

        _ = try await fixture.store.writeProfileBlock(
            key: ProfileBlock.userKey, text: "Work: Acme Robotics.", expectedText: "Work: Acme.", at: Support.t0)
        clock.advance(by: .seconds(301))
        #expect(await provider.pinnedMemory().profile == "Work: Acme Robotics.")
    }

    @Test func anUnreadableStoreGivesTheLastGoodAnswer() async throws {
        let fixture = try ProfileFixture()
        try fixture.addBlock("Work: Acme.", at: Support.t0)
        let open = OpenFlag()
        let store = DeferredProfileMemoryStore { open.isOpen ? fixture.container : nil }
        let provider = PinnedMemoryProvider(store: store, maximumAge: .zero)
        #expect(await provider.pinnedMemory().profile == "Work: Acme.")
        open.isOpen = false
        #expect(await provider.pinnedMemory().profile == "Work: Acme.")
        #expect(await PinnedMemoryProvider(store: store).pinnedMemory() == .empty)
    }
}

/// Whether a fake container is open.
private final class OpenFlag: Sendable {
    private let state = Mutex(true)

    var isOpen: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
