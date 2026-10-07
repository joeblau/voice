import Foundation

/// A time range a search query talks about: "last week", "yesterday",
/// "in March", "3 days ago", "between March 1 and March 10".
public struct TemporalExpression: Hashable, Sendable {
    /// What found it.
    public enum Source: String, Hashable, Sendable {
        /// `TemporalQueryParser`'s relative-date grammar.
        case grammar
        /// `NSDataDetector` (absolute and numeric dates, date ranges).
        case dataDetector
    }

    /// How the expression names its time.
    public enum Anchor: String, Hashable, Sendable {
        /// Relative to now: "yesterday", "last week", "3 days ago",
        /// "recently", "on Monday". Almost always when something was said,
        /// and nothing in the stored text can match it lexically.
        case relative
        /// A named month, date or year: "in March", "March 14", "2025".
        /// Often what a memory is about rather than when it was said ("our
        /// MRR in August"), and the dates spelled out in chunk keys already
        /// give BM25 something to match.
        case calendar
    }

    /// The days the expression covers, in the parser's time zone, from the
    /// start of the first day to the start of the day after the last.
    public var range: Range<Date>
    /// The words that said it, as written in the query.
    public var phrase: String
    public var anchor: Anchor
    public var source: Source

    public init(range: Range<Date>, phrase: String, anchor: Anchor, source: Source) {
        self.range = range
        self.phrase = phrase
        self.anchor = anchor
        self.source = source
    }
}

/// Finds the time range a memory search is about, on device, relative to
/// `now` ("what did I say about fundraising last week").
///
/// The issue sketched `NSDataDetector` for this. On the iOS 26 / macOS 26
/// SDKs it doesn't cover what memory queries say most: it finds nothing in
/// "last week", "last month", "in March", "3 days ago" or "this year"; it
/// resolves relative dates against the wall clock (it has no reference-date
/// API, so results can't be reproduced in tests); and it resolves toward
/// the future ("March 14" in October is next March, "Monday" is next
/// Monday), while a memory query is about the past. So relative dates go
/// through a small English grammar here, resolved against `now` and biased
/// to the past, and `NSDataDetector` handles what the grammar doesn't know:
/// numeric dates ("3/14", "2026-03-14") and other absolute forms. Only its
/// matches that write out a calendar date (a month name or a numeric date)
/// count, so clock times ("5pm") and future offsets ("in 2 weeks") don't,
/// and its result is re-anchored: only the calendar day is kept (and the
/// year when the query wrote one), resolved against `now` like the grammar.
///
/// Grammar (case and diacritics ignored, first expression in the query
/// wins):
///
/// | Says | Range |
/// | --- | --- |
/// | today, tonight, this morning / afternoon / evening | today |
/// | yesterday (morning...), the day before yesterday | that day |
/// | last night | yesterday until 6 am today |
/// | this week / month / year | the calendar period so far |
/// | last / previous week / month / year | the previous calendar period |
/// | past week / month / year, last / past N days / weeks / months / years | rolling, until today |
/// | N days ago | that day, ±1 day (yesterday for N = 1) |
/// | N weeks ago | the 7 days around that day |
/// | N months / years ago | that calendar month / year |
/// | (last / on / this) Monday... | the most recent Monday before today (this week's for "this") |
/// | last / this weekend | the most recent weekend |
/// | (in / last) March, March 14, 14 March, March 2025, the 14th of March | that month or day; the most recent one unless a year is given |
/// | in / during 2025 | that year |
/// | recently, lately, the other day | the last 14 / 7 days |
/// | since / after X, before X, between X and Y, from X to Y | open or combined ranges |
///
/// `N` is digits, a number word up to twenty, "a", "a couple of", "a few"
/// or "several". Weeks start on `firstWeekday`.
public struct TemporalQueryParser: Sendable {
    /// Gregorian, in the time zone dates are resolved in.
    public let calendar: Calendar
    /// Whether to fall back on `NSDataDetector` when the grammar finds
    /// nothing and the query contains a digit.
    public var usesDataDetector: Bool

    /// - Parameters:
    ///   - timeZone: Where "today" starts and ends (the device's).
    ///   - firstWeekday: The first day of a week, 1 = Sunday (the locale's
    ///     by default).
    public init(
        timeZone: TimeZone = .autoupdatingCurrent, firstWeekday: Int? = nil, usesDataDetector: Bool = true
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday ?? Calendar.autoupdatingCurrent.firstWeekday
        self.calendar = calendar
        self.usesDataDetector = usesDataDetector
    }

    /// The first time expression in `query`, resolved relative to `now`, or
    /// `nil` if it has none.
    public func parse(_ query: String, now: Date) -> TemporalExpression? {
        let tokens = Self.tokens(in: query)
        let context = Context(calendar: calendar, now: now)
        var index = 0
        while index < tokens.count {
            if let found = expression(in: tokens, at: index, context: context) {
                let phrase = String(query[tokens[found.first].range.lowerBound..<tokens[found.last].range.upperBound])
                return TemporalExpression(range: found.range, phrase: phrase, anchor: found.anchor, source: .grammar)
            }
            index += 1
        }
        guard usesDataDetector, query.contains(where: \.isNumber) else { return nil }
        return detectedDate(in: query, context: context)
    }

    // MARK: - Grammar

    /// A matched expression: its range and the tokens it spans.
    struct Match {
        var range: Range<Date>
        var first: Int
        var last: Int
        var anchor: TemporalExpression.Anchor
    }

    struct Context {
        let calendar: Calendar
        let now: Date
        let today: Date

        init(calendar: Calendar, now: Date) {
            self.calendar = calendar
            self.now = now
            self.today = calendar.startOfDay(for: now)
        }

        var tomorrow: Date { day(1) }

        /// The start of the day `offset` days from today.
        func day(_ offset: Int, from date: Date? = nil) -> Date {
            calendar.date(byAdding: .day, value: offset, to: date ?? today) ?? today
        }

        func days(_ start: Int, through end: Int) -> Range<Date> {
            day(start)..<day(end + 1)
        }

        func adding(_ component: Calendar.Component, _ value: Int, to date: Date) -> Date {
            calendar.date(byAdding: component, value: value, to: date) ?? date
        }

        /// The calendar period containing `date`.
        func period(_ component: Calendar.Component, containing date: Date) -> Range<Date> {
            guard let interval = calendar.dateInterval(of: component, for: date) else {
                return calendar.startOfDay(for: date)..<day(1, from: calendar.startOfDay(for: date))
            }
            return interval.start..<interval.end
        }

        /// The calendar period so far: from its start to the end of today.
        func periodSoFar(_ component: Calendar.Component) -> Range<Date> {
            period(component, containing: today).lowerBound..<tomorrow
        }

        /// The previous calendar period.
        func previousPeriod(_ component: Calendar.Component) -> Range<Date> {
            period(component, containing: adding(component, -1, to: today))
        }

        /// The last `count` units, until the end of today.
        func rolling(_ component: Calendar.Component, _ count: Int) -> Range<Date> {
            adding(component, -count, to: today)..<tomorrow
        }

        /// The most recent `weekday` (1 = Sunday) before today.
        func mostRecent(weekday: Int) -> Range<Date> {
            let current = calendar.component(.weekday, from: today)
            var back = (current - weekday + 7) % 7
            if back == 0 { back = 7 }
            return days(-back, through: -back)
        }

        /// `weekday` in the current week.
        func inThisWeek(weekday: Int) -> Range<Date> {
            let week = period(.weekOfYear, containing: today)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            let start = day(offset, from: week.lowerBound)
            return start..<day(1, from: start)
        }

        /// The most recent weekend that started before today (the current
        /// one when today is part of it and `includingCurrent`).
        func weekend(includingCurrent: Bool) -> Range<Date> {
            if includingCurrent, let current = calendar.dateIntervalOfWeekend(containing: today) {
                return current.start..<current.end
            }
            var probe = today
            if let current = calendar.dateIntervalOfWeekend(containing: today) { probe = current.start }
            if let previous = calendar.nextWeekend(startingAfter: probe, direction: .backward) {
                return previous.start..<previous.end
            }
            return days(-7, through: -6)
        }

        /// Month `month` (1-12) of `year`, or of the most recent year in
        /// which it has started.
        func month(_ month: Int, year: Int?, strictlyBeforeCurrent: Bool = false) -> Range<Date>? {
            var components = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: 1)
            guard var start = calendar.date(from: components) else { return nil }
            if year == nil {
                let current = period(.month, containing: today).lowerBound
                if start > today || (strictlyBeforeCurrent && start >= current) {
                    components.year = (components.year ?? 0) - 1
                    start = calendar.date(from: components) ?? start
                }
            }
            return period(.month, containing: start)
        }

        /// Day `day` of month `month` in `year`, or the most recent one on
        /// or before today.
        func date(month: Int, day: Int, year: Int?) -> Range<Date>? {
            let currentYear = calendar.component(.year, from: today)
            // Without a year: this year's, or the latest earlier one (eight
            // years back reaches the previous February 29).
            let years = year.map { [$0] } ?? Array(stride(from: currentYear, through: currentYear - 8, by: -1))
            for candidate in years {
                let components = DateComponents(year: candidate, month: month, day: day)
                guard components.isValidDate(in: calendar), let start = calendar.date(from: components) else {
                    continue
                }
                if year == nil, start > today { continue }
                return start..<self.day(1, from: start)
            }
            return nil
        }

        func year(_ year: Int) -> Range<Date>? {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
            return period(.year, containing: start)
        }
    }

    /// An expression starting at `index`, with `since`/`after`/`before`
    /// and `between … and …`/`from … to …` around it.
    func expression(in tokens: [Token], at index: Int, context: Context) -> Match? {
        let word = tokens[index].text
        switch word {
        case "since", "after", "before":
            guard index + 1 < tokens.count, let inner = simple(in: tokens, at: index + 1, context: context) else {
                return nil
            }
            let range: Range<Date>
            switch word {
            case "since": range = inner.range.lowerBound..<max(context.tomorrow, inner.range.upperBound)
            case "after": range = inner.range.upperBound..<max(context.tomorrow, inner.range.upperBound)
            default: range = Date.distantPast..<inner.range.lowerBound
            }
            guard !range.isEmpty else { return nil }
            return Match(range: range, first: index, last: inner.last, anchor: inner.anchor)
        case "between", "from":
            guard index + 1 < tokens.count, let start = simple(in: tokens, at: index + 1, context: context) else {
                return nil
            }
            let joiners: Set<String> = word == "between" ? ["and"] : ["to", "until", "till", "through", "thru"]
            if start.last + 2 < tokens.count, joiners.contains(tokens[start.last + 1].text),
                let end = simple(in: tokens, at: start.last + 2, context: context)
            {
                let lower = min(start.range.lowerBound, end.range.lowerBound)
                let upper = max(start.range.upperBound, end.range.upperBound)
                let anchor: TemporalExpression.Anchor =
                    start.anchor == .relative && end.anchor == .relative ? .relative : .calendar
                return Match(range: lower..<upper, first: index, last: end.last, anchor: anchor)
            }
            // "from last week": just the expression.
            return start
        default:
            return simple(in: tokens, at: index, context: context)
        }
    }

    /// One expression without range operators, starting at `index`.
    func simple(in tokens: [Token], at index: Int, context: Context) -> Match? {
        func text(_ offset: Int) -> String? {
            index + offset < tokens.count ? tokens[index + offset].text : nil
        }
        func match(_ range: Range<Date>?, through offset: Int, calendar: Bool = false) -> Match? {
            range.map { Match(range: $0, first: index, last: index + offset, anchor: calendar ? .calendar : .relative) }
        }
        let word = tokens[index].text
        let previous = index > 0 ? tokens[index - 1].text : nil

        switch word {
        case "today", "tonight":
            return match(context.days(0, through: 0), through: 0)
        case "yesterday":
            let part = text(1).map(Self.dayParts.contains) == true ? 1 : 0
            return match(context.days(-1, through: -1), through: part)
        case "day" where text(1) == "before" && text(2) == "yesterday":
            return match(context.days(-2, through: -2), through: 2)
        case "recently", "lately":
            return match(context.day(-14)..<context.tomorrow, through: 0)
        case "other" where previous == "the" && text(1) == "day":
            return match(context.day(-7)..<context.today, through: 1)
        case "this", "current":
            guard let next = text(1) else { return nil }
            if Self.dayParts.contains(next) { return match(context.days(0, through: 0), through: 1) }
            if let unit = Self.calendarUnit(next) { return match(context.periodSoFar(unit), through: 1) }
            if next == "weekend" { return match(context.weekend(includingCurrent: true), through: 1) }
            if let weekday = Self.weekdays[next] { return match(context.inThisWeek(weekday: weekday), through: 1) }
            if let month = Self.month(next, inContext: true) {
                return match(
                    context.month(month, year: context.calendar.component(.year, from: context.today)), through: 1,
                    calendar: true)
            }
            return nil
        case "last", "previous", "past":
            guard let next = text(1) else { return nil }
            if word == "last", next == "night" {
                return match(context.day(-1)..<context.adding(.hour, 6, to: context.today), through: 1)
            }
            if let unit = Self.calendarUnit(next) {
                return match(word == "past" ? context.rolling(unit, 1) : context.previousPeriod(unit), through: 1)
            }
            if next == "weekend" { return match(context.weekend(includingCurrent: false), through: 1) }
            if let weekday = Self.weekdays[next] { return match(context.mostRecent(weekday: weekday), through: 1) }
            if let month = Self.month(next, inContext: true) {
                return match(context.month(month, year: nil, strictlyBeforeCurrent: true), through: 1, calendar: true)
            }
            if let (count, after) = Self.number(in: tokens, at: index + 1), count > 0, after < tokens.count,
                let unit = Self.calendarUnit(tokens[after].text)
            {
                return match(context.rolling(unit, count), through: after - index)
            }
            return nil
        default:
            break
        }

        // "3 days ago", "a couple of weeks ago"
        if let (count, after) = Self.number(in: tokens, at: index), after + 1 < tokens.count,
            let unit = Self.calendarUnit(tokens[after].text), tokens[after + 1].text == "ago"
        {
            let last = after + 1 - index
            let target = context.adding(unit, -count, to: context.today)
            switch unit {
            case .day:
                return match(
                    count <= 1
                        ? context.days(-1, through: -1) : context.day(-1, from: target)..<context.day(2, from: target),
                    through: last)
            case .weekOfYear:
                return match(context.day(-3, from: target)..<context.day(4, from: target), through: last)
            default:
                return match(context.period(unit, containing: target), through: last)
            }
        }

        // Weekdays: "on Monday", "Monday" (the most recent one before today).
        if let weekday = Self.weekdays[word] {
            return match(context.mostRecent(weekday: weekday), through: 0)
        }

        // "14 March", "the 14th of March (2025)"
        if let day = tokens[index].number, (1...31).contains(day), tokens[index].text.count <= 4 {
            var next = index + 1
            if next < tokens.count, tokens[next].text == "of" { next += 1 }
            if next < tokens.count, let month = Self.month(tokens[next].text, inContext: true) {
                let year = Self.year(at: next + 1, in: tokens)
                return match(
                    context.date(month: month, day: day, year: year), through: next - index + (year == nil ? 0 : 1),
                    calendar: true)
            }
        }

        // "March", "March 14(th)", "March 2025", "March 14, 2025"
        let contextual = previous.map(Self.monthContextWords.contains) == true
        if let month = Self.month(word, inContext: contextual || Self.number(at: index + 1, in: tokens) != nil) {
            if let day = Self.dayNumber(at: index + 1, in: tokens) {
                let year = Self.year(at: index + 2, in: tokens)
                return match(
                    context.date(month: month, day: day, year: year), through: year == nil ? 1 : 2, calendar: true)
            }
            if let year = Self.year(at: index + 1, in: tokens) {
                return match(context.month(month, year: year), through: 1, calendar: true)
            }
            return match(context.month(month, year: nil), through: 0, calendar: true)
        }

        // "in 2025", "during 2024"
        if let previous, ["in", "during", "of", "since"].contains(previous), let year = Self.year(at: index, in: tokens)
        {
            return match(context.year(year), through: 0, calendar: true)
        }
        return nil
    }

    // MARK: - Words

    static let dayParts: Set<String> = ["morning", "afternoon", "evening", "night"]

    static func calendarUnit(_ word: String) -> Calendar.Component? {
        switch word {
        case "day", "days": .day
        case "week", "weeks": .weekOfYear
        case "month", "months": .month
        case "year", "years": .year
        default: nil
        }
    }

    /// 1 = Sunday, as `Calendar` numbers them.
    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    static let monthNames: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
    ]

    /// Abbreviations and "may": also ordinary words or names ("may", "Jan"),
    /// so they only count next to a number or after a word like "in".
    static let ambiguousMonthNames: [String: Int] = [
        "may": 5, "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12,
    ]

    static let monthContextWords: Set<String> = [
        "in", "on", "since", "last", "this", "during", "early", "mid", "late", "of", "from", "between", "and", "to",
        "until", "through", "before", "after", "end",
    ]

    static func month(_ word: String, inContext: Bool) -> Int? {
        if let month = monthNames[word] { return month }
        return inContext ? ambiguousMonthNames[word] : nil
    }

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "couple": 2, "few": 3, "several": 3,
    ]

    /// A count at `index` ("3", "three", "a", "a couple of", "a few") and
    /// the index after it.
    static func number(in tokens: [Token], at index: Int) -> (Int, Int)? {
        guard index < tokens.count else { return nil }
        var index = index
        var value: Int?
        if ["a", "an"].contains(tokens[index].text) {
            value = 1
            if index + 1 < tokens.count, let word = numberWords[tokens[index + 1].text], word != 1 {
                value = word
                index += 1
            }
        } else if let digits = tokens[index].number, tokens[index].text.allSatisfy(\.isNumber), digits < 1_000 {
            value = digits
        } else {
            value = numberWords[tokens[index].text]
        }
        guard let value else { return nil }
        index += 1
        if index < tokens.count, tokens[index].text == "of" { index += 1 }
        return (value, index)
    }

    static func number(at index: Int, in tokens: [Token]) -> Int? {
        index < tokens.count ? tokens[index].number : nil
    }

    /// A day of the month at `index` ("14", "14th").
    static func dayNumber(at index: Int, in tokens: [Token]) -> Int? {
        guard index < tokens.count, let value = tokens[index].number, (1...31).contains(value),
            tokens[index].text.count <= 4
        else { return nil }
        return value
    }

    /// A year at `index` (four digits, 1900-2199).
    static func year(at index: Int, in tokens: [Token]) -> Int? {
        guard index < tokens.count, tokens[index].text.count == 4, tokens[index].text.allSatisfy(\.isNumber),
            let value = tokens[index].number, (1900...2199).contains(value)
        else { return nil }
        return value
    }

    // MARK: - Tokens

    /// A run of letters or digits: lowercased and diacritic-folded, with
    /// its range in the query and its value if it is a number ("14",
    /// "14th").
    struct Token {
        var text: String
        var range: Range<String.Index>
        var number: Int?
    }

    static func tokens(in query: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = query.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            let text = query[begin..<end]
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .lowercased()
            tokens.append(Token(text: text, range: begin..<end, number: numericValue(text)))
            start = nil
        }
        while index < query.endIndex {
            let character = query[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = query.index(after: index)
        }
        close(at: query.endIndex)
        return tokens
    }

    /// "14" → 14, "14th" / "1st" / "2nd" / "3rd" → the number.
    static func numericValue(_ text: String) -> Int? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let suffix = text.dropFirst(digits.count)
        guard suffix.isEmpty || ["st", "nd", "rd", "th"].contains(suffix) else { return nil }
        return Int(digits)
    }

    // MARK: - NSDataDetector

    /// The first date `NSDataDetector` finds, re-anchored to `now`: only its
    /// calendar day (and duration) is kept, the year too when the matched
    /// text writes one, otherwise the most recent such day on or before
    /// today.
    ///
    /// Only matches that spell out that calendar day are used (see
    /// `spellsOutDate`). The detector also matches clock times ("5pm",
    /// "10:30") and future offsets ("in 2 weeks"), which it resolves against
    /// the wall clock; keeping just their month and day would name an
    /// unrelated day, usually a year in the past.
    func detectedDate(in query: String, context: Context) -> TemporalExpression? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let whole = NSRange(query.startIndex..., in: query)
        // The detector reads and reports dates in the device's time zone.
        var detectorCalendar = Calendar(identifier: .gregorian)
        detectorCalendar.timeZone = .autoupdatingCurrent
        for result in detector.matches(in: query, options: [], range: whole) {
            guard let date = result.date, let range = Range(result.range, in: query) else { continue }
            let phrase = String(query[range])
            let parts = detectorCalendar.dateComponents([.year, .month, .day], from: date)
            guard let month = parts.month, let day = parts.day,
                Self.spellsOutDate(phrase, month: month, day: day)
            else { continue }
            let tokens = Self.tokens(in: phrase)
            let writesYear =
                tokens.contains { Self.year(at: 0, in: [$0]) != nil }
                || phrase.range(of: #"\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2}\b"#, options: .regularExpression) != nil
            guard let start = context.date(month: month, day: day, year: writesYear ? parts.year : nil) else {
                continue
            }
            let extraDays = max(0, Int((result.duration / 86_400).rounded()))
            let end = context.day(extraDays, from: start.upperBound)
            return TemporalExpression(
                range: start.lowerBound..<end, phrase: phrase, anchor: .calendar, source: .dataDetector)
        }
        return nil
    }

    /// Whether a phrase the detector read as `month`/`day` writes that day
    /// out: it names the month ("Mar 3 at 5pm"), or it has a numeric date
    /// (numbers joined by `/`, `.` or `-`: "3/14", "2026-03-14",
    /// "14.03.2026") whose numbers include both the month and the day. Clock
    /// times ("5pm", "10:30", "5.30pm": the detector reads today), future
    /// offsets ("in 2 weeks") and bare ordinals ("the 3rd") don't.
    static func spellsOutDate(_ phrase: String, month: Int, day: Int) -> Bool {
        if tokens(in: phrase).contains(where: { Self.month($0.text, inContext: true) == month }) { return true }
        return phrase.matches(of: /\d{1,4}(?:[\/.\-]\d{1,4}){1,2}/).contains { match in
            let numbers = match.output.split { !$0.isNumber }.compactMap { Int($0) }
            return numbers.contains(month) && numbers.contains(day)
        }
    }
}
