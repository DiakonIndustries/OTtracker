import Foundation

/// Expected presence on one weekday.
public struct WeekdaySchedule: Hashable, Codable, Sendable {
    public var isWorkday: Bool
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var unpaidBreakMinutes: Int

    public init(isWorkday: Bool = true,
                start: TimeOfDay = TimeOfDay(hour: 7, minute: 0),
                end: TimeOfDay = TimeOfDay(hour: 15, minute: 30),
                unpaidBreakMinutes: Int = 0) {
        self.isWorkday = isWorkday
        self.start = start
        self.end = end
        self.unpaidBreakMinutes = max(0, unpaidBreakMinutes)
    }

    public static let off = WeekdaySchedule(isWorkday: false)

    /// Seconds between scheduled start and end (presence expected).
    public var windowSeconds: Int { isWorkday ? max(0, end.seconds - start.seconds) : 0 }

    /// Paid seconds: window minus unpaid break.
    public var expectedSeconds: Int { isWorkday ? max(0, windowSeconds - unpaidBreakMinutes * 60) : 0 }

    /// A workday must start before it ends; overnight schedules are not supported.
    public var isValid: Bool { !isWorkday || start < end }

    public func window(on day: DayKey, calendar: Calendar) -> Interval? {
        guard isWorkday, isValid else { return nil }
        return Interval(start: start.date(on: day, calendar: calendar), end: end.date(on: day, calendar: calendar))
    }
}

/// A full week of expectations, effective from a date until a later version takes over.
public struct ScheduleVersion: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var effectiveFrom: DayKey
    /// Exactly 7 entries, index = `weekday.rawValue - 1` (Sunday first).
    public var days: [WeekdaySchedule]
    public var note: String

    public init(id: UUID = UUID(), effectiveFrom: DayKey, days: [WeekdaySchedule], note: String = "") {
        self.id = id
        self.effectiveFrom = effectiveFrom
        var d = Array(days.prefix(7))
        while d.count < 7 { d.append(.off) }
        self.days = d
        self.note = note
    }

    public subscript(weekday: Weekday) -> WeekdaySchedule {
        get { days[weekday.rawValue - 1] }
        set { days[weekday.rawValue - 1] = newValue }
    }

    /// Monday–Friday workdays with the same hours, weekend off.
    public static func standardWeek(effectiveFrom: DayKey,
                                    start: TimeOfDay = TimeOfDay(hour: 7),
                                    end: TimeOfDay = TimeOfDay(hour: 15, minute: 30),
                                    breakMinutes: Int = 0) -> ScheduleVersion {
        let work = WeekdaySchedule(isWorkday: true, start: start, end: end, unpaidBreakMinutes: breakMinutes)
        return ScheduleVersion(effectiveFrom: effectiveFrom,
                               days: [.off, work, work, work, work, work, .off])
    }

    public var isValid: Bool { days.count == 7 && days.allSatisfy { $0.isValid } }
}

public enum DayOverrideKind: Hashable, Codable, Sendable {
    case none
    case dayOff
    case schedule(WeekdaySchedule)
}

/// Per-day exceptions and decisions. At most one per day.
public struct DayOverride: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var kind: DayOverrideKind
    /// Early arrival only counts when the user asks for it on that day.
    public var countEarlyArrival: Bool
    /// Delta forced to zero; components still shown.
    public var excused: Bool
    public var note: String

    public init(id: UUID = UUID(), day: DayKey, kind: DayOverrideKind = .none,
                countEarlyArrival: Bool = false, excused: Bool = false, note: String = "") {
        self.id = id
        self.day = day
        self.kind = kind
        self.countEarlyArrival = countEarlyArrival
        self.excused = excused
        self.note = note
    }

    /// True when the override carries no information and may be deleted.
    public var isEmpty: Bool {
        if case .none = kind { return !countEarlyArrival && !excused && note.isEmpty }
        return false
    }
}

public struct Holiday: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var name: String

    public init(id: UUID = UUID(), day: DayKey, name: String) {
        self.id = id
        self.day = day
        self.name = name
    }
}
