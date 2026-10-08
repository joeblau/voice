import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: the token budget and the user's own words")
struct ProfileComposerTests {
    let composer = ProfileComposer.standard

    private func document(_ body: String, title: String = "About me") -> UserProfileDocument {
        UserProfileDocument(id: UUID(), title: title, body: body, updatedAt: ExtractionTestSupport.t0)
    }

    // MARK: Acceptance: the profile stays within the token budget

    /// Whatever the user wrote and whatever the model returned, the pinned
    /// profile is within `ProfileBlock.tokenBudget`.
    @Test(arguments: [0, 40, 2_000, 4_000, 12_000])
    func thePinnedProfileStaysWithinTheBudget(userBytes: Int) {
        let user = userBytes == 0 ? [] : [document(String(ProfileFixture.prose(userBytes / 60 + 1).prefix(userBytes)))]
        for summary in [
            "", "Short.", ProfileFixture.prose(60), ProfileFixture.prose(400), String(repeating: "é🚀", count: 5_000),
        ] {
            let pinned = composer.pinnedProfile(documents: user, summary: summary) ?? ""
            #expect(
                ProfileComposer.tokens(pinned) <= ProfileBlock.tokenBudget,
                "user \(userBytes), summary \(summary.utf8.count)")
            #expect(pinned.utf8.count <= ProfileBlock.tokenBudget * 4)
        }
    }

    @Test func tokensMatchTheProfileBlockEstimate() {
        for text in ["", "a", "abcd", "abcde", "é", String(repeating: "x", count: 6_001)] {
            let block = ProfileBlock(text: text, updatedAt: .distantPast)
            #expect(ProfileComposer.tokens(text) == block.approximateTokenCount)
        }
    }

    @Test func aSummaryOfExactlyItsBudgetIsKeptWhole() {
        let user = composer.userSection([document("I run Acme Robotics with Dana.")])
        let budget = composer.summaryByteBudget(after: user)
        let summary = String(repeating: "a", count: budget)
        let pinned = composer.pinnedProfile(documents: [document("I run Acme Robotics with Dana.")], summary: summary)
        #expect(pinned == user + "\n\n" + summary)
        #expect(pinned.map(ProfileComposer.tokens) == ProfileBlock.tokenBudget)
    }

    // MARK: User-authored text stays verbatim

    @Test func theUsersOwnWordsArePinnedVerbatimBeforeTheSummary() {
        let body = "I'm Joe.  I build *Blau*,\na voice app — and I hate small talk!"
        let pinned = composer.pinnedProfile(
            documents: [document(body)], summary: "Work: The user is building Blau.")
        #expect(pinned == "In the user's own words:\nAbout me:\n\(body)\n\nWork: The user is building Blau.")
    }

    @Test func pagesWithoutTitlesOrBodiesAreHandled() {
        let section = composer.userSection([
            document("Body only.", title: ""), document("", title: "Empty page"), document("Second.", title: "Goals"),
        ])
        #expect(section == "In the user's own words:\nBody only.\nGoals:\nSecond.")
        #expect(composer.userSection([]).isEmpty)
        #expect(composer.pinnedProfile(documents: [], summary: "  ") == nil)
    }

    /// Too long to pin whole: a verbatim prefix, cut at a sentence end and
    /// marked, within the user's share while a summary has to fit too, and
    /// within the whole budget otherwise.
    @Test func longUserTextIsCutVerbatimAtABoundary() {
        let body = ProfileFixture.prose(200, prefix: "Me")
        let full = "In the user's own words:\nAbout me:\n" + body

        let shared = composer.userSection([document(body)], leavingRoomForSummary: true)
        #expect(shared.hasSuffix("." + ProfileComposer.ellipsis))
        #expect(full.hasPrefix(String(shared.dropLast())))
        #expect(shared.utf8.count <= Int(Double(composer.byteBudget) * composer.userAuthoredShare))

        let alone = composer.pinnedProfile(documents: [document(body)], summary: nil) ?? ""
        #expect(full.hasPrefix(String(alone.dropLast())))
        #expect(alone.utf8.count > shared.utf8.count)
        #expect(ProfileComposer.tokens(alone) <= ProfileBlock.tokenBudget)
    }

    // MARK: Fitting a model's reply

    @Test func fittingPrefersLineBreaksThenSentencesThenSpaces() {
        let lines = "Work: Acme.\nPeople: Dana is a cofounder.\nGoals: raise a seed round"
        #expect(ProfileComposer.fitted(lines, maximumBytes: 45) == "Work: Acme.\nPeople: Dana is a cofounder.")
        let sentences = "The user runs Acme. They hire engineers now. Then more"
        #expect(ProfileComposer.fitted(sentences, maximumBytes: 50) == "The user runs Acme. They hire engineers now.")
        let words = "averyveryverylongword another"
        #expect(ProfileComposer.fitted(words, maximumBytes: 26) == "averyveryverylongword")
        #expect(ProfileComposer.fitted("short", maximumBytes: 10) == "short")
        #expect(ProfileComposer.fitted("anything", maximumBytes: 0) == "")
    }

    @Test func fittingNeverSplitsACharacter() {
        let text = String(repeating: "🚀", count: 10)
        let fitted = ProfileComposer.fitted(text, maximumBytes: 10)
        #expect(fitted == "🚀🚀")
    }

    @Test func wordBudgetIsConservative() {
        #expect(ProfileComposer.wordBudget(forBytes: 6_000) == 857)
        #expect(ProfileComposer.wordBudget(forBytes: 0) == 0)
    }
}
