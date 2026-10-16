import Foundation
import OTModels
import OTXLSX

/// Text and cell conventions shared by the exporter and the importers.
enum ExchangeFormat {
    /// `h:mm` duration text (`-0:42` when negative, `+1:05` when `signed`).
    static func clock(_ seconds: Int, signed: Bool = false) -> String {
        DurationFormat.clock(seconds, signed: signed)
    }

    /// Exact decimal hours (no rounding; Excel formats it).
    static func hours(_ seconds: Int) -> Double { Double(seconds) / 3600.0 }

    /// Wall-clock `HH:mm` of an instant in `calendar`; `HH:mm:ss` when the seconds are not zero.
    static func wallClock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0, s = c.second ?? 0
        return s == 0 ? String(format: "%02d:%02d", h, m) : String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// `.dateOnly` cell for a calendar day (midnight in `calendar`).
    static func dayCell(_ day: DayKey, calendar: Calendar) -> Cell { .dateOnly(day.start(in: calendar)) }

    /// `.date` cell or `.empty`.
    static func dateCell(_ date: Date?) -> Cell { date.map { .date($0) } ?? .empty }

    /// Compact JSON (sorted keys) for a Codable value; `""` if it cannot be encoded.
    static func json<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes compact JSON written by `json(_:)`.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// Header text → lookup key: lowercased, parenthesised suffix removed, non-alphanumerics dropped.
    /// `"Radius (m)"` → `radius`, `"Counts As"` → `countsas`.
    static func headerKey(_ raw: String) -> String {
        var s = raw.lowercased()
        if let open = s.firstIndex(of: "(") { s = String(s[..<open]) }
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Trimmed text with whitespace and newlines removed from both ends.
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Case-insensitive name key for matching locations and types.
    static func nameKey(_ s: String) -> String { trim(s).lowercased() }

    // MARK: Parsing text

    /// `yyyy-MM-dd` (also `M/d/yyyy`), validated against `calendar` so 2026-02-30 is rejected.
    static func parseDay(_ raw: String, calendar: Calendar) -> DayKey? {
        let s = trim(raw)
        var key: DayKey? = DayKey(iso: s)
        if key == nil {
            let parts = s.split(separator: "/")
            if parts.count == 3, let m = Int(parts[0]), let d = Int(parts[1]), let y = Int(parts[2]),
               (1...12).contains(m), (1...31).contains(d), y > 1900 {
                key = DayKey(year: y, month: m, day: d)
            }
        }
        if key == nil, let date = parseInstant(s, calendar: calendar) { key = DayKey(date, calendar: calendar) }
        guard let k = key else { return nil }
        // A rolled-over date (Feb 30 → Mar 2) means the text was not a real day.
        guard DayKey(k.start(in: calendar), calendar: calendar) == k else { return nil }
        return k
    }

    /// `HH:mm`, `H:mm`, `HH:mm:ss`, `7:30 am`, `5pm` → (hour, minute, second).
    static func parseClock(_ raw: String) -> (hour: Int, minute: Int, second: Int)? {
        var s = trim(raw).lowercased()
        var pm: Bool? = nil
        if s.hasSuffix("am") { pm = false; s = String(s.dropLast(2)) }
        else if s.hasSuffix("pm") { pm = true; s = String(s.dropLast(2)) }
        s = trim(s)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), let h0 = Int(parts[0]) else { return nil }
        let m = parts.count > 1 ? Int(parts[1]) ?? -1 : 0
        let sec = parts.count > 2 ? Int(parts[2]) ?? -1 : 0
        guard (0...59).contains(m), (0...59).contains(sec) else { return nil }
        var h = h0
        if let pm {
            guard (1...12).contains(h) else { return nil }
            if pm && h < 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
        }
        guard (0...23).contains(h) else { return nil }
        return (h, m, sec)
    }

    /// The instant of a wall-clock time on `day` in `calendar`.
    static func instant(day: DayKey, hour: Int, minute: Int, second: Int, calendar: Calendar) -> Date {
        var c = day.components
        c.hour = hour; c.minute = minute; c.second = second
        return calendar.date(from: c) ?? day.start(in: calendar).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    /// ISO 8601 (`2026-10-14T07:02:00Z`, with offset or fractional seconds), `yyyy-MM-dd HH:mm[:ss]`
    /// or `yyyy-MM-dd` (midnight) in `calendar`'s time zone. Whole seconds.
    static func parseInstant(_ raw: String, calendar: Calendar) -> Date? {
        let s = trim(raw)
        guard !s.isEmpty else { return nil }
        if let d = ISO8601.fractional.date(from: s) ?? ISO8601.plain.date(from: s) { return d.wholeSeconds }
        let separators = CharacterSet(charactersIn: "T ")
        let parts = s.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let dayText = parts.first, let day = DayKey(iso: dayText) ?? parseSlashDay(dayText) else { return nil }
        guard DayKey(day.start(in: calendar), calendar: calendar) == day else { return nil }
        if parts.count == 1 { return day.start(in: calendar) }
        let timeText = parts.dropFirst().joined(separator: " ")
        guard let t = parseClock(timeText) else { return nil }
        return instant(day: day, hour: t.hour, minute: t.minute, second: t.second, calendar: calendar).wholeSeconds
    }

    private static func parseSlashDay(_ s: String) -> DayKey? {
        let parts = s.split(separator: "/")
        guard parts.count == 3, let m = Int(parts[0]), let d = Int(parts[1]), let y = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d), y > 1900 else { return nil }
        return DayKey(year: y, month: m, day: d)
    }

    /// Excel serial day number (days since 1899-12-30, fraction = time of day) → instant in `calendar`.
    static func excelSerial(_ serial: Double, calendar: Calendar) -> Date? {
        guard serial >= 1, serial < 2_958_466 else { return nil }
        let days = Int(serial.rounded(.down))
        let fraction = serial - Double(days)
        let epoch = DayKey(year: 1899, month: 12, day: 30)
        let day = epoch.adding(days: days, calendar: calendar)
        let secondsOfDay = Int((fraction * 86400).rounded())
        return instant(day: day, hour: secondsOfDay / 3600, minute: (secondsOfDay % 3600) / 60, second: secondsOfDay % 60, calendar: calendar)
    }

    /// `true`/`yes`/`y`/`1`/`x`/`on` and `false`/`no`/`n`/`0`/`off`/empty.
    static func parseBool(_ raw: String) -> Bool? {
        switch trim(raw).lowercased() {
        case "true", "yes", "y", "1", "x", "on": return true
        case "false", "no", "n", "0", "off", "": return false
        default: return nil
        }
    }

    /// Weekday by name (`Monday`, `mon`) or Calendar number (`2`).
    static func parseWeekday(_ raw: String) -> Weekday? {
        let s = trim(raw).lowercased()
        if let n = Int(s) { return Weekday(rawValue: n) }
        return Weekday.allCases.first { $0.name.lowercased() == s || $0.shortName.lowercased() == s }
    }

    /// Signed hours + minutes → seconds. A minus sign on either part makes the whole value negative
    /// (`-1`,`30` is −1h30m), decimals are allowed (`7.5` hours).
    static func seconds(hoursText: String, minutesText: String) -> Int? {
        let h = trim(hoursText), m = trim(minutesText)
        guard !h.isEmpty || !m.isEmpty else { return nil }
        let hv = h.isEmpty ? 0 : Double(h)
        let mv = m.isEmpty ? 0 : Double(m)
        guard let hours = hv, let minutes = mv else { return nil }
        let negative = h.hasPrefix("-") || m.hasPrefix("-") || hours < 0 || minutes < 0
        let magnitude = (abs(hours) * 3600 + abs(minutes) * 60).rounded()
        return Int(negative ? -magnitude : magnitude)
    }
}

// MARK: - Reading cells

extension Cell {
    /// Trimmed text of any cell (`""` for `.empty`; dates as ISO 8601).
    var exText: String {
        switch self {
        case .empty: return ""
        case .string(let s): return ExchangeFormat.trim(s)
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .integer(let i): return String(i)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .date(let d), .dateOnly(let d): return ISO8601.plain.string(from: d)
        case .formula(let f): return f
        }
    }

    var exIsEmpty: Bool {
        if case .empty = self { return true }
        if case .string(let s) = self { return ExchangeFormat.trim(s).isEmpty }
        return false
    }

    var exInt: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return d == d.rounded() ? Int(d) : Int(d.rounded())
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = ExchangeFormat.trim(s)
            if let i = Int(t) { return i }
            if let d = Double(t) { return Int(d.rounded()) }
            return nil
        default: return nil
        }
    }

    var exDouble: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(ExchangeFormat.trim(s))
        default: return nil
        }
    }

    var exBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .integer(let i): return i != 0
        case .number(let d): return d != 0
        case .string(let s): return ExchangeFormat.parseBool(s)
        case .empty: return nil
        default: return nil
        }
    }

    var exUUID: UUID? {
        let t = exText
        return t.isEmpty ? nil : UUID(uuidString: t)
    }

    /// An instant: date cells as they are, text via `parseInstant`, bare numbers as Excel serials.
    func exDate(calendar: Calendar) -> Date? {
        switch self {
        case .date(let d), .dateOnly(let d): return d.wholeSeconds
        case .string(let s): return ExchangeFormat.parseInstant(s, calendar: calendar)
        case .number(let d): return ExchangeFormat.excelSerial(d, calendar: calendar)
        case .integer(let i): return ExchangeFormat.excelSerial(Double(i), calendar: calendar)
        default: return nil
        }
    }

    /// A calendar day in `calendar`.
    func exDay(calendar: Calendar) -> DayKey? {
        switch self {
        case .date(let d), .dateOnly(let d): return DayKey(d, calendar: calendar)
        case .string(let s): return ExchangeFormat.parseDay(s, calendar: calendar)
        case .number, .integer: return exDate(calendar: calendar).map { DayKey($0, calendar: calendar) }
        default: return nil
        }
    }

    /// A wall-clock time: `HH:mm` text, a date cell's time of day, or an Excel day fraction.
    func exTimeOfDay(calendar: Calendar) -> TimeOfDay? {
        switch self {
        case .string(let s):
            guard let t = ExchangeFormat.parseClock(s) else { return nil }
            return TimeOfDay(hour: t.hour, minute: t.minute)
        case .date(let d), .dateOnly(let d):
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
        case .number(let d):
            guard d >= 0, d < 1 else {
                return exDate(calendar: calendar).map { date in
                    let c = calendar.dateComponents([.hour, .minute], from: date)
                    return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
                }
            }
            return TimeOfDay(minutesFromMidnight: Int((d * 1440).rounded()))
        default: return nil
        }
    }
}
