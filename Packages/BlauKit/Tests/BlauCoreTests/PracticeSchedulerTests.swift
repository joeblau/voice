import Foundation
import Testing

@testable import BlauCore

@Suite("Practice scheduler")
struct PracticeSchedulerTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let day: TimeInterval = 86_400
    static let collection = UUID()

    static func item(
        _ ordinal: Int, count: Int = 0, score: Double? = nil, daysAgo: Double? = nil
    ) -> PracticeItem {
        PracticeItem(
            id: UUID(), collectionID: collection, ordinal: ordinal, prompt: "Question \(ordinal)",
            practiceCount: count, score: score,
            lastPracticedAt: daysAgo.map { now.addingTimeInterval(-$0 * day) })
    }

    @Test func neverPracticedPromptsComeFirstInCollectionOrder() {
        let items = [
            Self.item(0, count: 1, score: 0.1, daysAgo: 30),
            Self.item(1),
            Self.item(2, count: 3, score: 0.9, daysAgo: 1),
            Self.item(3),
        ]
        let order = PracticeScheduler.standard.order(items, at: Self.now).map(\.ordinal)
        #expect(order == [1, 3, 0, 2])
    }

    @Test func worsePromptsPracticedAtTheSameTimeComeFirst() {
        let items = [
            Self.item(0, count: 1, score: 0.9, daysAgo: 2),
            Self.item(1, count: 1, score: 0.2, daysAgo: 2),
            Self.item(2, count: 1, score: 0.5, daysAgo: 2),
        ]
        #expect(PracticeScheduler.standard.order(items, at: Self.now).map(\.ordinal) == [1, 2, 0])
    }

    @Test func lessRecentPromptsWithTheSameScoreComeFirst() {
        let items = [
            Self.item(0, count: 2, score: 0.6, daysAgo: 1),
            Self.item(1, count: 2, score: 0.6, daysAgo: 9),
            Self.item(2, count: 2, score: 0.6, daysAgo: 4),
        ]
        #expect(PracticeScheduler.standard.order(items, at: Self.now).map(\.ordinal) == [1, 2, 0])
    }

    @Test func aWeakOldAnswerOutranksAStrongRecentOne() {
        let strongRecent = Self.item(0, count: 1, score: 1, daysAgo: 1)
        let weakOld = Self.item(1, count: 1, score: 0.3, daysAgo: 3)
        #expect(PracticeScheduler.standard.next(in: [strongRecent, weakOld], at: Self.now)?.ordinal == 1)
    }

    @Test func intervalsGrowWithPracticeAndScore() throws {
        let scheduler = PracticeScheduler.standard
        #expect(scheduler.interval(of: Self.item(0)) == nil)
        let once = try #require(scheduler.interval(of: Self.item(0, count: 1, score: 0.5, daysAgo: 0)))
        #expect(once == Self.day)
        let thrice = try #require(scheduler.interval(of: Self.item(0, count: 3, score: 0.5, daysAgo: 0)))
        #expect(thrice == 4 * Self.day)
        let missed = try #require(scheduler.interval(of: Self.item(0, count: 1, score: 0, daysAgo: 0)))
        let perfect = try #require(scheduler.interval(of: Self.item(0, count: 1, score: 1, daysAgo: 0)))
        #expect(missed < once && once < perfect)
        // Doubling is capped.
        let many = try #require(scheduler.interval(of: Self.item(0, count: 40, score: 0.5, daysAgo: 0)))
        #expect(many == 64 * Self.day)
        // An unscored attempt counts as middling.
        #expect(scheduler.interval(of: Self.item(0, count: 1, daysAgo: 0)) == once)
    }

    @Test func askedPromptsAreSkippedUntilEveryOneWasAsked() {
        let items = (0..<10).map { Self.item($0) }
        var asked: Set<UUID> = []
        var order: [Int] = []
        while let next = PracticeScheduler.standard.next(in: items, at: Self.now, excluding: asked) {
            asked.insert(next.id)
            order.append(next.ordinal)
        }
        #expect(order == Array(0..<10))
        #expect(PracticeScheduler.standard.next(in: items, at: Self.now, excluding: asked) == nil)
    }

    @Test func tiesAreDeterministic() {
        let items = [Self.item(2, count: 1, score: 0.5, daysAgo: 1), Self.item(1, count: 1, score: 0.5, daysAgo: 1)]
        #expect(PracticeScheduler.standard.order(items, at: Self.now).map(\.ordinal) == [1, 2])
    }
}

@Suite("Practice collection matcher")
struct PracticeCollectionMatcherTests {
    static let yc = PracticeCollection(id: UUID(), title: "YC interview questions", itemCount: 30)
    static let sales = PracticeCollection(id: UUID(), title: "Sales objections", itemCount: 12)
    static let board = PracticeCollection(id: UUID(), title: "Board meeting prep", itemCount: 5)
    static let all = [yc, sales, board]

    @Test(arguments: [
        "YC interview questions", "yc questions", "YC", "the YC interview", "Y.C. Interview Questions", "interview",
    ])
    func findsTheCollectionTheUserMeans(_ name: String) {
        #expect(PracticeCollectionMatcher.best(name, in: Self.all)?.id == Self.yc.id)
    }

    @Test func pluralsAndCaseMatch() {
        #expect(PracticeCollectionMatcher.best("sales objection", in: Self.all)?.id == Self.sales.id)
        #expect(PracticeCollectionMatcher.best("BOARD MEETING", in: Self.all)?.id == Self.board.id)
    }

    @Test func noMatchIsNil() {
        #expect(PracticeCollectionMatcher.best("pitch deck", in: Self.all) == nil)
    }

    @Test func aVagueNameMatchesTheOnlyCollection() {
        #expect(PracticeCollectionMatcher.best("my questions", in: [Self.yc])?.id == Self.yc.id)
        #expect(PracticeCollectionMatcher.best("", in: [Self.yc])?.id == Self.yc.id)
        #expect(PracticeCollectionMatcher.best("", in: Self.all) == nil)
    }

    @Test func anExactTitleWinsOverAPartialOne() {
        let short = PracticeCollection(id: UUID(), title: "YC", itemCount: 3)
        #expect(PracticeCollectionMatcher.best("YC", in: Self.all + [short])?.id == short.id)
    }
}
