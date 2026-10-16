import Foundation
import OTCore

/// Date and duration formatting in the store's calendar / time zone.
enum Format {
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(template: String, calendar: Calendar) -> DateFormatter {
        let key = template + "|" + calendar.timeZone.identifier
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }

    /// 5:42 PM
    static func time(_ date: Date, _ calendar: Calendar) -> String {
        formatter(template: "jmm", calendar: calendar).string(from: date)
    }

    /// Oct 14, 5:42 PM
    static func dateTime(_ date: Date, _ calendar: Calendar) -> String {
        formatter(template: "MMMdjmm", calendar: calendar).string(from: date)
    }

    /// Tue, Oct 14
    static func dayShort(_ day: DayKey, _ calendar: Calendar) -> String {
        formatter(template: "EEEMMMd", calendar: calendar).string(from: noon(day, calendar))
    }

    /// Tuesday, October 14
    static func dayLong(_ day: DayKey, _ calendar: Calendar) -> String {
        formatter(template: "EEEEMMMMd", calendar: calendar).string(from: noon(day, calendar))
    }

    /// Oct 14, 2026
    static func dayWithYear(_ day: DayKey, _ calendar: Calendar) -> String {
        formatter(template: "MMMdyyyy", calendar: calendar).string(from: noon(day, calendar))
    }

    /// October 2026
    static func month(_ day: DayKey, _ calendar: Calendar) -> String {
        formatter(template: "MMMMyyyy", calendar: calendar).string(from: noon(day, calendar))
    }

    /// Oct 12 – Oct 18
    static func weekRange(start: DayKey, _ calendar: Calendar) -> String {
        let end = start.adding(days: 6, calendar: calendar)
        let f = formatter(template: "MMMd", calendar: calendar)
        return f.string(from: noon(start, calendar)) + " – " + f.string(from: noon(end, calendar))
    }

    static func hm(_ seconds: Int, signed: Bool = false) -> String { DurationFormat.hm(seconds, signed: signed) }

    static func clock(_ seconds: Int, signed: Bool = false) -> String { DurationFormat.clock(seconds, signed: signed) }

    static func noon(_ day: DayKey, _ calendar: Calendar) -> Date {
        day.start(in: calendar).addingTimeInterval(12 * 3600)
    }

    /// Relative wording for a day: Today, Yesterday, Tomorrow, else short.
    static func relativeDay(_ day: DayKey, today: DayKey, _ calendar: Calendar) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: -1, calendar: calendar) { return "Yesterday" }
        if day == today.adding(days: 1, calendar: calendar) { return "Tomorrow" }
        return dayShort(day, calendar)
    }

    /// First day of the week containing `day`, honouring the calendar's firstWeekday.
    static func weekStart(of day: DayKey, _ calendar: Calendar) -> DayKey {
        let wd = day.weekday(in: calendar).rawValue
        let offset = (wd - calendar.firstWeekday + 7) % 7
        return day.adding(days: -offset, calendar: calendar)
    }

    static func monthKey(_ day: DayKey) -> String { String(format: "%04d-%02d", day.year, day.month) }

    static func firstOfMonth(_ day: DayKey) -> DayKey { DayKey(year: day.year, month: day.month, day: 1) }

    static func lastOfMonth(_ day: DayKey, _ calendar: Calendar) -> DayKey {
        let next = day.month == 12 ? DayKey(year: day.year + 1, month: 1, day: 1) : DayKey(year: day.year, month: day.month + 1, day: 1)
        return next.adding(days: -1, calendar: calendar)
    }
}
