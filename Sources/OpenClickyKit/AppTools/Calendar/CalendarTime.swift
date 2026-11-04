import Foundation

/// "Now" and the calendar arithmetic the calendar tools use. Injected so tests run at a fixed moment and zone.
public struct CalendarClock: Sendable {
    public var now: @Sendable () -> Date
    /// Gregorian, in the user's time zone, with the user's first weekday.
    public var calendar: Calendar

    /// The default zone follows the Mac's setting, so a toolbox kept for a whole app session still means the user's
    /// "today" after they travel to another zone.
    public init(now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .autoupdatingCurrent,
                firstWeekday: Int = Calendar.current.firstWeekday) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    public var timeZone: TimeZone { calendar.timeZone }
}

/// A date the model wrote, and whether it named a time or only a day.
public struct CalendarDateInput: Sendable, Hashable {
    public var date: Date
    public var isDateOnly: Bool
}

/// Parses the date forms models produce: "2026-11-03", "2026-11-03T14:00", "2026-11-03 14:00:00",
/// "2026-11-03T14:00:00-08:00", "2026-11-03T22:00:00Z". Times without an offset are in the user's zone.
public enum CalendarDateParser {
    public static func parse(_ text: String, calendar: Calendar) -> CalendarDateInput? {
        let pattern = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[Tt ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?\s*([Zz]|[+-]\d{2}(?::?\d{2})?)?)?$/
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        let year = Int(match.1)!, month = Int(match.2)!, day = Int(match.3)!
        var components = DateComponents(year: year, month: month, day: day)
        var zone = calendar.timeZone
        let hasTime = match.4 != nil
        if hasTime {
            components.hour = Int(match.4!)
            components.minute = Int(match.5!)
            components.second = match.6.map { Int($0)! } ?? 0
            if let offset = match.7 {
                guard let parsed = timeZone(offset: String(offset)) else { return nil }
                zone = parsed
            }
        } else {
            components.hour = 0
            components.minute = 0
            components.second = 0
        }
        guard (1...12).contains(month), (1...31).contains(day), (components.hour ?? 0) < 24,
              (components.minute ?? 0) < 60, (components.second ?? 0) < 60 else { return nil }
        var zoned = calendar
        zoned.timeZone = zone
        guard let date = zoned.date(from: components) else { return nil }
        // Reject days that roll over (February 30th).
        let check = zoned.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return CalendarDateInput(date: date, isDateOnly: !hasTime)
    }

    static func timeZone(offset: String) -> TimeZone? {
        if offset.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = offset.hasPrefix("-") ? -1 : 1
        let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 2 || digits.count == 4, let value = Int(digits) else { return nil }
        let hours = digits.count == 2 ? value : value / 100
        let minutes = digits.count == 2 ? 0 : value % 100
        guard hours <= 14, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
    }
}

/// Named time ranges the model can use instead of computing dates.
public enum CalendarRangeName: String, Sendable, CaseIterable {
    case today
    case restOfToday = "rest_of_today"
    case tomorrow
    case thisWeek = "this_week"
    case nextWeek = "next_week"
    case next7Days = "next_7_days"
    case thisWeekend = "this_weekend"
    case thisMonth = "this_month"

    public func interval(now: Date, calendar: Calendar) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        func adding(_ component: Calendar.Component, _ value: Int, to date: Date) -> Date {
            calendar.date(byAdding: component, value: value, to: date) ?? date
        }
        let startOfTomorrow = adding(.day, 1, to: startOfToday)
        let startOfNextWeek: Date = {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            return thisWeek?.end ?? adding(.day, 7, to: startOfToday)
        }()
        switch self {
        case .today:
            return DateInterval(start: startOfToday, end: startOfTomorrow)
        case .restOfToday:
            return DateInterval(start: now, end: max(now, startOfTomorrow))
        case .tomorrow:
            return DateInterval(start: startOfTomorrow, end: adding(.day, 1, to: startOfTomorrow))
        case .thisWeek:
            return DateInterval(start: startOfToday, end: startOfNextWeek)
        case .nextWeek:
            return DateInterval(start: startOfNextWeek, end: adding(.day, 7, to: startOfNextWeek))
        case .next7Days:
            return DateInterval(start: now, end: adding(.day, 7, to: now))
        case .thisWeekend:
            if calendar.isDateInWeekend(now), let weekend = calendar.dateIntervalOfWeekend(containing: now) {
                return DateInterval(start: startOfToday, end: weekend.end)
            }
            if let weekend = calendar.nextWeekend(startingAfter: now) { return weekend }
            return DateInterval(start: startOfToday, end: adding(.day, 2, to: startOfToday))
        case .thisMonth:
            let end = calendar.dateInterval(of: .month, for: now)?.end ?? adding(.month, 1, to: startOfToday)
            return DateInterval(start: startOfToday, end: end)
        }
    }
}

/// How dates go back to the model: ISO 8601 with the user's offset, or a plain day for all-day events.
public enum CalendarTimeFormat {
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3_600, minutes = (abs(offset) % 3_600) / 60
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, sign, hours, minutes)
    }

    public static func day(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "Tuesday": models are unreliable at working out weekdays from dates, and people ask by weekday.
    public static func weekday(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }
}
