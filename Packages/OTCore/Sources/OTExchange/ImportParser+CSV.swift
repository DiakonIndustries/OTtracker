import Foundation
import OTModels
import OTCSV

extension ImportParser {
    /// Parses the CSV import template (docs/IMPORT_TEMPLATE.md) or a holidays-only `date,name` file.
    ///
    /// Record kinds: `presence`, `manual`, `timeoff`, `holiday`, `adjustment`, plus the shorthands
    /// `pto`, `personal` and `flex` (a `timeoff` row of that type). Dates are `yyyy-MM-dd`, times
    /// `HH:mm` in `store.settings.timeZone`; an end earlier than its start ends on the next day.
    /// Problems are reported per record with its line number (header = line 1).
    public static func parse(csvText: String, store: Store) -> ImportBundle {
        var b = ImportBundle()
        let cal = store.calendar
        let rows = CSV.parse(csvText)
        guard let headerRow = rows.first else { return b }
        let header = headerRow.map { ExchangeFormat.headerKey($0) }

        func reject(_ line: Int, _ why: String) { b.invalid.append(.init(line: line, reason: why)) }

        func isBlank(_ row: [String]) -> Bool { row.allSatisfy { ExchangeFormat.trim($0).isEmpty } }

        // Holidays-only file.
        if isHolidaysHeader(header), let dateColumn = header.firstIndex(of: "date"), let nameColumn = header.firstIndex(of: "name") {
            for (i, row) in rows.enumerated().dropFirst() where !isBlank(row) {
                let line = i + 1
                let dateText = dateColumn < row.count ? ExchangeFormat.trim(row[dateColumn]) : ""
                guard let day = ExchangeFormat.parseDay(dateText, calendar: cal) else { reject(line, "line \(line): bad date '\(dateText)'"); continue }
                let name = nameColumn < row.count ? ExchangeFormat.trim(row[nameColumn]) : ""
                b.holidays.append(Holiday(day: day, name: name.isEmpty ? "Holiday" : name))
            }
            return b
        }

        guard header.contains("record") else {
            reject(1, "line 1: the header must contain a 'record' column (see docs/IMPORT_TEMPLATE.md)")
            return b
        }
        var columns: [String: Int] = [:]
        for (i, key) in header.enumerated() where !key.isEmpty && columns[key] == nil { columns[key] = i }

        for (i, row) in rows.enumerated().dropFirst() where !isBlank(row) {
            let line = i + 1
            func field(_ name: String) -> String {
                guard let idx = columns[name], idx < row.count else { return "" }
                return ExchangeFormat.trim(row[idx])
            }
            func fail(_ why: String) { reject(line, "line \(line): \(why)") }

            let record = ExchangeFormat.headerKey(field("record"))
            guard !record.isEmpty else { fail("missing record kind"); continue }

            let idText = field("id")
            var id: UUID? = nil
            if !idText.isEmpty {
                guard let u = UUID(uuidString: idText) else { fail("bad id '\(idText)'"); continue }
                id = u
            }

            let dateText = field("date")
            guard !dateText.isEmpty else { fail("missing date"); continue }
            guard let day = ExchangeFormat.parseDay(dateText, calendar: cal) else { fail("bad date '\(dateText)' (use yyyy-MM-dd)"); continue }

            /// Start/end instants on `day`; the end rolls to the next day when it is not after the start.
            func window() -> (Date, Date)? {
                let startText = field("start"), endText = field("end")
                guard !startText.isEmpty else { fail("missing start time"); return nil }
                guard !endText.isEmpty else { fail("missing end time"); return nil }
                guard let s = TimeOfDay(hhmm: startText) else { fail("bad start time '\(startText)' (use HH:mm)"); return nil }
                guard let e = TimeOfDay(hhmm: endText) else { fail("bad end time '\(endText)' (use HH:mm)"); return nil }
                guard s != e else { fail("end time must differ from start time"); return nil }
                let start = s.date(on: day, calendar: cal)
                var end = e.date(on: day, calendar: cal)
                if end < start { end = e.date(on: day.adding(days: 1, calendar: cal), calendar: cal) }
                return (start, end)
            }

            switch record {
            case "presence":
                let location = field("location")
                guard !location.isEmpty else { fail("missing location"); continue }
                guard let (start, end) = window() else { continue }
                b.presence.append(.init(id: id, locationName: location, enteredAt: start, exitedAt: end,
                                        source: .imported, followingGapIsWork: nil, note: field("note")))

            case "manual":
                guard let (start, end) = window() else { continue }
                let category = field("category").isEmpty ? store.settings.defaultManualCategory : field("category")
                let typeText = field("type").lowercased()
                guard let countsAs = typeText.isEmpty ? ManualCountsAs.extra : ManualCountsAs(rawValue: typeText) else {
                    fail("manual type must be 'extra', 'regular' or empty"); continue
                }
                b.manual.append(ManualSession.block(category: category, note: field("note"), countsAs: countsAs,
                                                    start: start, end: end, id: id ?? UUID(), createdAt: start))

            case "timeoff", "pto", "personal", "flex":
                var typeName = field("type")
                if typeName.isEmpty {
                    guard record != "timeoff" else { fail("missing type (PTO, Personal, Flex or a custom type)"); continue }
                    typeName = store.timeOffType(named: record)?.name ?? record
                }
                guard let seconds = ExchangeFormat.seconds(hoursText: field("hours"), minutesText: field("minutes")) else {
                    fail("missing hours/minutes"); continue
                }
                guard seconds > 0 else { fail("hours/minutes must be greater than 0"); continue }
                b.timeOff.append(.init(id: id, day: day, typeName: typeName, seconds: seconds, note: field("note")))

            case "holiday":
                let name = field("name")
                b.holidays.append(Holiday(id: id ?? UUID(), day: day, name: name.isEmpty ? "Holiday" : name))

            case "adjustment", "adjust":
                guard let seconds = ExchangeFormat.seconds(hoursText: field("hours"), minutesText: field("minutes")) else {
                    fail("missing hours/minutes"); continue
                }
                guard seconds != 0 else { fail("adjustment must not be zero"); continue }
                let reason = field("note").isEmpty ? field("name") : field("note")
                b.adjustments.append(Adjustment(id: id ?? UUID(), day: day, seconds: seconds, reason: reason))

            default:
                fail("unknown record kind '\(field("record"))' (presence, manual, timeoff, holiday, adjustment, pto, personal, flex)")
            }
        }
        return b
    }
}
