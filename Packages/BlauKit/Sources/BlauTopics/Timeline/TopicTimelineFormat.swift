import Foundation

/// The times, durations and day groups the timeline (#56) shows next to
/// its bullets, and that VoiceOver reads with each topic.
///
/// The locale and calendar (with its time zone) are injected so tests
/// format the same everywhere; the app uses the user's.
public struct TopicTimelineFormat: Sendable {
    /// A day group's heading.
    public enum Day: Hashable, Sendable {
        case today
        case yesterday
        /// Any other day, shown by date.
        case date(Date)
    }

    public var locale: Locale
    public var calendar: Calendar

    public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
        self.locale = locale
        self.calendar = calendar
    }

    /// When a topic started: the time of day, e.g. "9:41 AM".
    public func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// How long a topic lasted, in whole minutes (at least one), with hours
    /// past the hour: "12 min", "1 hr, 5 min" (`spelledOut`: "12 minutes",
    /// "1 hour, 5 minutes", for VoiceOver).
    public func duration(_ interval: TimeInterval, spelledOut: Bool = false) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        var style = Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes], width: spelledOut ? .wide : .abbreviated)
        style.locale = locale
        return Duration.seconds(minutes * 60).formatted(style)
    }

    /// The heading of the day group containing `date`, seen at `now`.
    public func day(_ date: Date, now: Date) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return .yesterday
        }
        return .date(calendar.startOfDay(for: date))
    }

    /// A day shown by date: weekday, month and day, with the year when it
    /// isn't `now`'s year. "Tuesday, October 6".
    public func dayTitle(_ date: Date, now: Date) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
