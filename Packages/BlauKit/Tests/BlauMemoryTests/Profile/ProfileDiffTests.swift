import Foundation
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: the diff the user sees")
struct ProfileDiffTests {
    @Test func identicalTextHasNoChanges() {
        let diff = ProfileDiff(before: "Work: Acme.", after: "Work: Acme.")
        #expect(diff.isEmpty)
        #expect(diff.segments == [.init(.unchanged, "Work: Acme.")])
    }

    @Test func wordChangesBecomeRuns() {
        let diff = ProfileDiff(before: "Work: The user works at Stripe.", after: "Work: The user works at Acme now.")
        #expect(
            diff.segments == [
                .init(.unchanged, "Work: The user works at "), .init(.removed, "Stripe."), .init(.added, "Acme now."),
            ])
        #expect(diff.addedWordCount == 2)
        #expect(diff.removedWordCount == 1)
        #expect(!diff.isEmpty)
    }

    @Test func reconstructsBothVersions() {
        let before = "Work: Acme.\n\nPeople: Dana is a cofounder.\nGoals: raise a seed round."
        let after = "Work: Acme Robotics.\n\nPeople: Dana and Sam.\nGoals: raise a seed round by December."
        let diff = ProfileDiff(before: before, after: after)
        #expect(diff.after == after)
        #expect(diff.before == before)
    }

    @Test func fromNothingEverythingIsAdded() {
        let diff = ProfileDiff(before: "", after: "Work: Acme.\nPeople: Dana.")
        #expect(diff.segments == [.init(.added, "Work: Acme.\nPeople: Dana.")])
        let cleared = ProfileDiff(before: "Work: Acme.", after: "")
        #expect(cleared.segments == [.init(.removed, "Work: Acme.")])
    }

    @Test func reflowedWhitespaceIsNotAChange() {
        let diff = ProfileDiff(before: "Work: Acme.\nPeople: Dana.", after: "Work: Acme. People: Dana.")
        #expect(diff.isEmpty)
        #expect(diff.after == "Work: Acme. People: Dana.")
    }

    @Test func tokensKeepTheirWhitespace() {
        #expect(ProfileDiff.tokens("  a b\n\nc ") == ["  ", "a ", "b\n\n", "c "])
        #expect(ProfileDiff.tokens("").isEmpty)
    }
}
