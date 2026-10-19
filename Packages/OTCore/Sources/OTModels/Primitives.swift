import Foundation

// MARK: - Weekday

/// Matches `Calendar.component(.weekday)`: Sunday = 1 … Saturday = 7.
public enum Weekday: Int, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var name: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }

    public var shortName: String { String(name.prefix(3)) }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }

    /// All seven weekdays starting from `start` (e.g. Sunday … Saturday).
    public static func ordered(startingOn start: Weekday) -> [Weekday] {
        (0..<7).map { Weekday(rawValue: ((start.rawValue - 1 + $0) % 7) + 1)! }
    }
}

// MARK: - DayKey

/// A calendar day (year, month, day) with no time zone of its own. The owning
/// `Calendar` (from `Settings.calendar`) decides where the day starts and ends.
public struct DayKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// `yyyy-MM-dd`
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init?(iso: String) {
        let parts = iso.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { isoString }

    public var components: DateComponents { DateComponents(year: year, month: month, day: day) }

    /// Midnight at the start of this day in `calendar`'s time zone.
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Midnight at the start of the *next* day.
    public func end(in calendar: Calendar) -> Date {
        adding(days: 1, calendar: calendar).start(in: calendar)
    }

    public func interval(in calendar: Calendar) -> Interval {
        Interval(start: start(in: calendar), end: end(in: calendar))
    }

    public func adding(days: Int, calendar: Calendar) -> DayKey {
        let base = start(in: calendar)
        // Noon-anchor avoids DST edge cases where midnight shifts.
        let noon = base.addingTimeInterval(12 * 3600)
        let shifted = calendar.date(byAdding: .day, value: days, to: noon) ?? noon
        return DayKey(shifted, calendar: calendar)
    }

    public func weekday(in calendar: Calendar) -> Weekday {
        let noon = start(in: calendar).addingTimeInterval(12 * 3600)
        return Weekday(rawValue: calendar.component(.weekday, from: noon)) ?? .sunday
    }

    /// Number of days from `self` to `other` (negative if `other` is earlier).
    public func daysUntil(_ other: DayKey, calendar: Calendar) -> Int {
        let a = start(in: calendar).addingTimeInterval(12 * 3600)
        let b = other.start(in: calendar).addingTimeInterval(12 * 3600)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Inclusive list of days.
    public static func days(from: DayKey, through: DayKey, calendar: Calendar) -> [DayKey] {
        guard from <= through else { return [] }
        var out: [DayKey] = []
        var cur = from
        while cur <= through {
            out.append(cur)
            cur = cur.adding(days: 1, calendar: calendar)
        }
        return out
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func isSameMonth(as other: DayKey) -> Bool { year == other.year && month == other.month }
}

extension DayKey: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let k = DayKey(iso: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad DayKey \(s)")
        }
        self = k
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(isoString)
    }
}

// MARK: - TimeOfDay

/// Wall-clock time of day, minute resolution.
public struct TimeOfDay: Hashable, Codable, Sendable, Comparable {
    public var minutesFromMidnight: Int

    public init(minutesFromMidnight: Int) {
        self.minutesFromMidnight = min(max(minutesFromMidnight, 0), 24 * 60 - 1)
    }

    public init(hour: Int, minute: Int = 0) {
        self.init(minutesFromMidnight: hour * 60 + minute)
    }

    public var hour: Int { minutesFromMidnight / 60 }
    public var minute: Int { minutesFromMidnight % 60 }
    public var seconds: Int { minutesFromMidnight * 60 }

    /// `HH:mm`, 24-hour.
    public var hhmm: String { String(format: "%02d:%02d", hour, minute) }

    /// Accepts `7:30`, `07:30`, `17:05`, `7:30 am`, `5pm`.
    public init?(hhmm raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var pm: Bool? = nil
        if s.hasSuffix("am") { pm = false; s = String(s.dropLast(2)) }
        else if s.hasSuffix("pm") { pm = true; s = String(s.dropLast(2)) }
        s = s.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":")
        guard let h0 = Int(parts.first ?? "") else { return nil }
        let m = parts.count > 1 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(m) else { return nil }
        var h = h0
        if let pm {
            guard (1...12).contains(h) else { return nil }
            if pm && h < 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
        }
        guard (0...23).contains(h) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// The instant this wall-clock time falls on `day` in `calendar`'s time zone.
    public func date(on day: DayKey, calendar: Calendar) -> Date {
        var c = day.components
        c.hour = hour
        c.minute = minute
        c.second = 0
        return calendar.date(from: c) ?? day.start(in: calendar).addingTimeInterval(TimeInterval(seconds))
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

// MARK: - Interval

/// A closed time span `[start, end]`, `end >= start`. Integer-second arithmetic.
public struct Interval: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var seconds: Int { Int((end.timeIntervalSince(start)).rounded()) }
    public var isEmpty: Bool { seconds <= 0 }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }

    public func overlaps(_ other: Interval) -> Bool { start < other.end && other.start < end }

    /// The part of `self` inside `other`, or nil when they do not overlap.
    public func clipped(to other: Interval) -> Interval? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        guard e > s else { return nil }
        return Interval(start: s, end: e)
    }

    /// Union of overlapping or touching intervals, sorted by start.
    public static func merged(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var out: [Interval] = []
        for iv in sorted {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1] = Interval(start: last.start, end: max(last.end, iv.end))
            } else {
                out.append(iv)
            }
        }
        return out
    }

    public static func totalSeconds(_ intervals: [Interval]) -> Int {
        merged(intervals).reduce(0) { $0 + $1.seconds }
    }

    /// Seconds of `intervals` that fall inside `window`.
    public static func seconds(of intervals: [Interval], inside window: Interval) -> Int {
        merged(intervals).compactMap { $0.clipped(to: window) }.reduce(0) { $0 + $1.seconds }
    }
}

// MARK: - Duration formatting

public enum DurationFormat {
    /// `1h 12m`, `-42m`, `0m`. With `signed`, positive values get a leading `+`.
    public static func hm(_ seconds: Int, signed: Bool = false) -> String {
        let neg = seconds < 0
        let total = abs(seconds)
        let minutes = (total + 30) / 60
        let h = minutes / 60
        let m = minutes % 60
        var body: String
        if h > 0 && m > 0 { body = "\(h)h \(m)m" }
        else if h > 0 { body = "\(h)h" }
        else { body = "\(m)m" }
        if neg && minutes > 0 { return "-" + body }
        if signed && minutes > 0 { return "+" + body }
        return body
    }

    /// `h:mm`, e.g. `1:05`, `-0:42`.
    public static func clock(_ seconds: Int, signed: Bool = false) -> String {
        let neg = seconds < 0
        let minutes = (abs(seconds) + 30) / 60
        let body = String(format: "%d:%02d", minutes / 60, minutes % 60)
        if neg && minutes > 0 { return "-" + body }
        if signed && minutes > 0 { return "+" + body }
        return body
    }

    /// `h:mm:ss`, used by the running timer.
    public static func clockWithSeconds(_ seconds: Int) -> String {
        let s = abs(seconds)
        return String(format: "%@%d:%02d:%02d", seconds < 0 ? "-" : "", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Decimal hours, 2 dp.
    public static func hours(_ seconds: Int) -> Double {
        (Double(seconds) / 3600.0 * 100).rounded() / 100
    }
}
