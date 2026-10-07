import Foundation
import Testing

@testable import BlauMemory

@Suite("Temporal query parser")
struct TemporalQueryParserTests {
    /// Wednesday, October 7, 2026, 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_374_400)
    static let parser = TemporalQueryParser(timeZone: TimeZone(identifier: "UTC")!, firstWeekday: 2)

    static func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    static func days(_ start: String, _ end: String) -> Range<Date> {
        day(start)..<day(end)
    }

    static func parse(_ query: String) -> TemporalExpression? {
        parser.parse(query, now: now)
    }

    @Test(arguments: [
        ("what did I say about fundraising last week", "last week", "2026-09-28", "2026-10-05"),
        ("yesterday", "yesterday", "2026-10-06", "2026-10-07"),
        ("what did we talk about yesterday morning", "yesterday morning", "2026-10-06", "2026-10-07"),
        ("the day before yesterday", "day before yesterday", "2026-10-05", "2026-10-06"),
        ("what did I say earlier today", "today", "2026-10-07", "2026-10-08"),
        ("this morning's run", "this morning", "2026-10-07", "2026-10-08"),
        ("last night", "last night", "2026-10-06", "2026-10-07 06:00"),
        ("ideas from this week", "this week", "2026-10-05", "2026-10-08"),
        ("THIS MONTH", "THIS MONTH", "2026-10-01", "2026-10-08"),
        ("what happened last month", "last month", "2026-09-01", "2026-10-01"),
        ("goals for this year", "this year", "2026-01-01", "2026-10-08"),
        ("last year", "last year", "2025-01-01", "2026-01-01"),
        ("over the past week", "past week", "2026-09-30", "2026-10-08"),
        ("in the last 3 days", "last 3 days", "2026-10-04", "2026-10-08"),
        ("the past couple of weeks", "past couple of weeks", "2026-09-23", "2026-10-08"),
        ("the past few months", "past few months", "2026-07-07", "2026-10-08"),
        ("3 days ago", "3 days ago", "2026-10-03", "2026-10-06"),
        ("two days ago", "two days ago", "2026-10-04", "2026-10-07"),
        ("a day ago", "a day ago", "2026-10-06", "2026-10-07"),
        ("a week ago", "a week ago", "2026-09-27", "2026-10-04"),
        ("a couple of weeks ago", "a couple of weeks ago", "2026-09-20", "2026-09-27"),
        ("2 months ago", "2 months ago", "2026-08-01", "2026-09-01"),
        ("a year ago", "a year ago", "2025-01-01", "2026-01-01"),
        ("what did Sam say last Tuesday", "last Tuesday", "2026-10-06", "2026-10-07"),
        ("on Monday", "Monday", "2026-10-05", "2026-10-06"),
        ("Wednesday", "Wednesday", "2026-09-30", "2026-10-01"),
        ("this Friday", "this Friday", "2026-10-09", "2026-10-10"),
        ("last weekend", "last weekend", "2026-10-03", "2026-10-05"),
        ("since last week", "since last week", "2026-09-28", "2026-10-08"),
        ("what changed recently", "recently", "2026-09-23", "2026-10-08"),
        ("the other day", "other day", "2026-09-30", "2026-10-07"),
    ])
    func relativeExpressions(query: String, phrase: String, start: String, end: String) throws {
        let expression = try #require(Self.parse(query))
        #expect(expression.phrase == phrase)
        #expect(expression.range == Self.days(start, end))
        #expect(expression.anchor == .relative)
        #expect(expression.source == .grammar)
    }

    @Test(arguments: [
        ("what did we decide in March", "March", "2026-03-01", "2026-04-01"),
        ("last March", "last March", "2026-03-01", "2026-04-01"),
        ("in November", "November", "2025-11-01", "2025-12-01"),
        ("in May", "May", "2026-05-01", "2026-06-01"),
        ("on Jan 5", "Jan 5", "2026-01-05", "2026-01-06"),
        ("March 14", "March 14", "2026-03-14", "2026-03-15"),
        ("November 3rd", "November 3rd", "2025-11-03", "2025-11-04"),
        ("14 March 2025", "14 March 2025", "2025-03-14", "2025-03-15"),
        ("the 14th of March", "14th of March", "2026-03-14", "2026-03-15"),
        ("MRR August 2026", "August 2026", "2026-08-01", "2026-09-01"),
        ("what did I work on in 2025", "2025", "2025-01-01", "2026-01-01"),
        ("February 29", "February 29", "2024-02-29", "2024-03-01"),
        ("between March 1 and March 10", "between March 1 and March 10", "2026-03-01", "2026-03-11"),
        ("from Jan 5 to Feb 2", "from Jan 5 to Feb 2", "2026-01-05", "2026-02-03"),
        ("after March 14", "after March 14", "2026-03-15", "2026-10-08"),
    ])
    func calendarExpressions(query: String, phrase: String, start: String, end: String) throws {
        let expression = try #require(Self.parse(query))
        #expect(expression.phrase == phrase)
        #expect(expression.range == Self.days(start, end))
        #expect(expression.anchor == .calendar)
    }

    @Test func beforeIsOpenEnded() throws {
        let expression = try #require(Self.parse("notes from before March"))
        #expect(expression.range == Date.distantPast..<Self.day("2026-03-01"))
        #expect(expression.phrase == "before March")
    }

    /// Words that only look like dates: content numbers, "may" the verb,
    /// "Jan" the name, plurals and units without a count.
    @Test(arguments: [
        "what is my MRR", "my 2 kids", "which day of the week do I keep free of meetings",
        "after the 2023 price rise", "what does your month over month look like", "May I ask about pricing",
        "what did Jan say about hiring", "I run on Mondays", "",
    ])
    func noExpression(query: String) {
        #expect(Self.parse(query) == nil)
    }

    /// The first expression wins.
    @Test func firstExpressionWins() throws {
        let expression = try #require(Self.parse("yesterday I mentioned what happened last month"))
        #expect(expression.phrase == "yesterday")
    }

    /// `NSDataDetector` catches numeric dates; its result is re-anchored to
    /// `now` and the past, whatever the wall clock says.
    @Test func numericDatesGoThroughTheDataDetector() throws {
        let expression = try #require(Self.parse("what happened on 3/14"))
        #expect(expression.source == .dataDetector)
        #expect(expression.anchor == .calendar)
        #expect(expression.range == Self.days("2026-03-14", "2026-03-15"))

        let withYear = try #require(Self.parse("the call on 12/24/2025"))
        #expect(withYear.range == Self.days("2025-12-24", "2025-12-25"))

        var parser = Self.parser
        parser.usesDataDetector = false
        #expect(parser.parse("what happened on 3/14", now: Self.now) == nil)
    }

    @Test func weeksFollowTheFirstWeekday() throws {
        let sundayFirst = TemporalQueryParser(timeZone: TimeZone(identifier: "UTC")!, firstWeekday: 1)
        let expression = try #require(sundayFirst.parse("last week", now: Self.now))
        #expect(expression.range == Self.days("2026-09-27", "2026-10-04"))
    }

    @Test func daysFollowTheTimeZone() throws {
        // 12:00 UTC is 21:00 in Tokyo, where days start at 15:00 UTC.
        let tokyo = TemporalQueryParser(timeZone: TimeZone(identifier: "Asia/Tokyo")!, firstWeekday: 2)
        let expression = try #require(tokyo.parse("yesterday", now: Self.now))
        #expect(expression.range.lowerBound == Self.day("2026-10-05 15:00"))
        #expect(expression.range.upperBound == Self.day("2026-10-06 15:00"))
    }
}
