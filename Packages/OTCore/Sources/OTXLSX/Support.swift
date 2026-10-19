import Foundation

/// Spreadsheet column references: zero-based index ↔ `A`, `Z`, `AA`, `ZZ`, `AAA`.
public enum ColumnReference {
    /// Letters for a zero-based column index (0 → `A`, 26 → `AA`).
    public static func letters(forIndex index: Int) -> String {
        var n = max(0, index) + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out.insert(Character(UnicodeScalar(UInt8(65 + rem))), at: out.startIndex)
            n = (n - 1) / 26
        }
        return out
    }

    /// Zero-based column index for a cell reference such as `B7` or `AA12`; nil when it has no letters
    /// or the letters run past what an `Int` can hold.
    public static func index(ofReference ref: String) -> Int? {
        var n = 0
        var sawLetter = false
        for ch in ref {
            guard let ascii = ch.asciiValue else { return nil }
            let digit: Int
            if ascii >= 65 && ascii <= 90 {           // A–Z
                digit = Int(ascii - 64)
            } else if ascii >= 97 && ascii <= 122 {   // a–z
                digit = Int(ascii - 96)
            } else {
                break
            }
            let (scaled, overflow1) = n.multipliedReportingOverflow(by: 26)
            let (next, overflow2) = scaled.addingReportingOverflow(digit)
            if overflow1 || overflow2 { return nil }
            n = next
            sawLetter = true
        }
        return sawLetter ? n - 1 : nil
    }

    /// One-based row number from a cell reference such as `B7`; nil when it has no digits.
    public static func row(ofReference ref: String) -> Int? {
        let digits = ref.drop { !$0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n > 0 else { return nil }
        return n
    }
}

/// Excel 1900-date-system serial numbers computed from wall-clock components, never from raw UTC arithmetic.
public enum ExcelDate {
    /// Days from 0000-03-01 (proleptic Gregorian) for a civil date; pure integer arithmetic.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Inverse of `daysFromCivil`.
    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Serial-day number of the epoch 1899-12-30 in `daysFromCivil` terms.
    private static let epochDays = daysFromCivil(year: 1899, month: 12, day: 30)

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Excel serial for the wall-clock time of `date` in `timeZone`; `dateOnly` drops the time part.
    public static func serial(from date: Date, timeZone: TimeZone, dateOnly: Bool = false) -> Double {
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = c.year ?? 1970, m = c.month ?? 1, d = c.day ?? 1
        var days = daysFromCivil(year: y, month: m, day: d) - epochDays
        // Excel's 1900 leap-year bug: serials before 1900-03-01 are one lower than the real day count.
        if days < 61 { days -= 1 }
        if dateOnly { return Double(days) }
        let seconds = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return Double(days) + Double(seconds) / 86400.0
    }

    /// Wall-clock components for an Excel serial; the time part is rounded to whole seconds.
    static func components(fromSerial serial: Double) -> DateComponents? {
        guard serial.isFinite, abs(serial) < 10_000_000 else { return nil }
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86400.0).rounded())
        if seconds >= 86400 {
            days += 1
            seconds -= 86400
        }
        if days < 61 { days += 1 }   // undo the 1900 leap-year bug offset
        let civil = civilFromDays(days + epochDays)
        var c = DateComponents()
        c.year = civil.year
        c.month = civil.month
        c.day = civil.day
        c.hour = seconds / 3600
        c.minute = (seconds % 3600) / 60
        c.second = seconds % 60
        return c
    }

    /// The instant whose wall clock in `timeZone` matches `serial`; nil for absurd values.
    public static func date(fromSerial serial: Double, timeZone: TimeZone) -> Date? {
        guard let c = components(fromSerial: serial) else { return nil }
        return calendar(timeZone).date(from: c)
    }

    /// True when the serial carries no time-of-day part (to the nearest second).
    public static func isWholeDay(_ serial: Double) -> Bool {
        guard serial.isFinite else { return false }
        let frac = serial - serial.rounded(.down)
        let seconds = (frac * 86400.0).rounded()
        return seconds == 0 || seconds == 86400
    }
}

/// XML text escaping for OOXML parts.
enum XMLText {
    /// Escapes `& < > " '`, writes CR as a character reference, and drops characters XML 1.0 forbids.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\r": out += "&#13;"
            case "\t", "\n": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                if v < 0x20 || (v >= 0xD800 && v <= 0xDFFF) || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
