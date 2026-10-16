import Foundation
import OTModels
import OTXLSX

/// Column access for one sheet: header names are matched after `ExchangeFormat.headerKey`
/// normalisation, so column order, case and units in parentheses do not matter.
struct SheetReader {
    let name: String
    let columns: [String: Int]
    let dataRows: [(row: Int, cells: [Cell])]

    init(_ sheet: Worksheet) {
        name = sheet.name
        var cols: [String: Int] = [:]
        for (i, cell) in (sheet.rows.first ?? []).enumerated() {
            let key = ExchangeFormat.headerKey(cell.exText)
            if !key.isEmpty, cols[key] == nil { cols[key] = i }
        }
        columns = cols
        dataRows = sheet.rows.enumerated().dropFirst()
            .filter { !$0.element.allSatisfy { $0.exIsEmpty } }
            .map { (row: $0.offset + 1, cells: $0.element) }
    }

    func has(_ header: String) -> Bool { columns[ExchangeFormat.headerKey(header)] != nil }

    /// The cell under the first of `headers` that exists in this sheet, else `.empty`.
    func cell(_ cells: [Cell], _ headers: String...) -> Cell {
        for h in headers {
            if let i = columns[ExchangeFormat.headerKey(h)], i < cells.count { return cells[i] }
        }
        return .empty
    }
}

extension ImportParser {
    /// Reads the sheets Presence, Manual, TimeOff, Holidays, Locations, Schedule, Overrides,
    /// Adjustments, Events and Settings by header name. Missing sheets or optional columns are
    /// skipped; each bad row becomes an `InvalidRow` with the sheet row number.
    public static func parse(workbook: Workbook, store: Store) -> ImportBundle {
        var b = ImportBundle()
        // Text dates and clock times are wall-clock in the zone the file was written in (its Settings
        // sheet) when it says so, otherwise in the store's zone.
        var cal = store.calendar
        if let tz = workbookTimeZone(workbook) { cal.timeZone = tz }
        var invalid: [ImportBundle.InvalidRow] = []

        func reject(_ sheet: String, _ row: Int, _ why: String) {
            invalid.append(.init(line: row, reason: "\(sheet) row \(row): \(why)"))
        }

        // Locations first: Events rows resolve location names against them.
        var locationIDsByName: [String: UUID] = [:]
        for l in store.locations { locationIDsByName[ExchangeFormat.nameKey(l.name)] = l.id }

        if let sheet = workbook.sheet(named: "Locations") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                let nameCell = r.cell(cells, "Name", "Location")
                guard !nameCell.exIsEmpty else { reject(r.name, row, "missing name"); continue }
                let name = nameCell.exRawText
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let lat = r.cell(cells, "Latitude", "Lat")
                let lon = r.cell(cells, "Longitude", "Lon", "Lng")
                guard lat.exIsEmpty || lat.exDouble != nil else { reject(r.name, row, "bad latitude"); continue }
                guard lon.exIsEmpty || lon.exDouble != nil else { reject(r.name, row, "bad longitude"); continue }
                let radius = r.cell(cells, "Radius (m)", "Radius")
                guard radius.exIsEmpty || radius.exDouble != nil else { reject(r.name, row, "bad radius"); continue }
                let active = r.cell(cells, "Active", "Is Active")
                guard active.exIsEmpty || active.exBool != nil else { reject(r.name, row, "bad active flag"); continue }
                let id = idCell.exUUID ?? UUID()
                // createdAt is not in the sheet; it is set from the earliest related instant below.
                let loc = WorkLocation(id: id, name: name, latitude: lat.exDouble ?? 0, longitude: lon.exDouble ?? 0,
                                       radiusMeters: radius.exDouble ?? 200, isActive: active.exBool ?? true,
                                       createdAt: Date(timeIntervalSince1970: 0))
                b.locations.append(loc)
                locationIDsByName[ExchangeFormat.nameKey(name)] = id
            }
        }

        if let sheet = workbook.sheet(named: "Presence") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                let location = r.cell(cells, "Location", "Location Name").exText
                guard !location.isEmpty else { reject(r.name, row, "missing location"); continue }
                guard let entered = r.cell(cells, "Entered", "Entered At", "Start", "In").exDate(calendar: cal) else {
                    reject(r.name, row, "missing or bad Entered time"); continue
                }
                let exitedCell = r.cell(cells, "Exited", "Exited At", "End", "Out")
                var exited: Date? = nil
                if !exitedCell.exIsEmpty {
                    guard let e = exitedCell.exDate(calendar: cal) else { reject(r.name, row, "bad Exited time"); continue }
                    guard e >= entered else { reject(r.name, row, "Exited is before Entered"); continue }
                    exited = e
                }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let sourceText = r.cell(cells, "Source").exText.lowercased()
                let source = sourceText.isEmpty ? EventSource.imported : EventSource(rawValue: sourceText)
                guard let src = source else { reject(r.name, row, "unknown source '\(sourceText)'"); continue }
                let gapText = r.cell(cells, "Gap After", "Gap").exText.lowercased()
                let gap: Bool?
                switch gapText {
                case "": gap = nil
                case "work", "work trip", "true", "yes": gap = true
                case "personal", "false", "no": gap = false
                default: reject(r.name, row, "Gap After must be 'work', 'personal' or empty"); continue
                }
                b.presence.append(.init(id: idCell.exUUID, locationName: location, enteredAt: entered, exitedAt: exited,
                                        source: src, followingGapIsWork: gap, note: r.cell(cells, "Note").exRawText))
            }
        }

        if let sheet = workbook.sheet(named: "Manual") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                let categoryCell = r.cell(cells, "Category")
                guard !categoryCell.exIsEmpty else { reject(r.name, row, "missing category"); continue }
                let category = categoryCell.exRawText
                guard let started = r.cell(cells, "Started", "Started At", "Start").exDate(calendar: cal) else {
                    reject(r.name, row, "missing or bad Started time"); continue
                }
                let stoppedCell = r.cell(cells, "Stopped", "Stopped At", "End")
                var stopped: Date? = nil
                if !stoppedCell.exIsEmpty {
                    guard let s = stoppedCell.exDate(calendar: cal) else { reject(r.name, row, "bad Stopped time"); continue }
                    guard s >= started else { reject(r.name, row, "Stopped is before Started"); continue }
                    stopped = s
                }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let countsText = r.cell(cells, "Counts As", "CountsAs").exText.lowercased()
                let countsAs = countsText.isEmpty ? ManualCountsAs.extra : ManualCountsAs(rawValue: countsText)
                guard let counts = countsAs else { reject(r.name, row, "Counts As must be 'extra' or 'regular'"); continue }
                guard let segments = Self.segments(startedAt: started, stoppedAt: stopped,
                                                   text: r.cell(cells, "Segments").exText, calendar: cal) else {
                    reject(r.name, row, "bad Segments text (expected 'HH:mm–HH:mm; HH:mm–HH:mm')"); continue
                }
                b.manual.append(ManualSession(id: idCell.exUUID ?? UUID(), category: category, note: r.cell(cells, "Note").exRawText,
                                              countsAs: counts, segments: segments, isStopped: stopped != nil, createdAt: started))
            }
        }

        if let sheet = workbook.sheet(named: "TimeOff") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                guard let day = r.cell(cells, "Date", "Day").exDay(calendar: cal) else { reject(r.name, row, "missing or bad date"); continue }
                let type = r.cell(cells, "Type").exText
                guard !type.isEmpty else { reject(r.name, row, "missing type"); continue }
                let hoursCell = r.cell(cells, "Hours"), minutesCell = r.cell(cells, "Minutes")
                guard let seconds = ExchangeFormat.seconds(hoursText: hoursCell.exText, minutesText: minutesCell.exText) else {
                    reject(r.name, row, "missing or bad hours/minutes"); continue
                }
                guard seconds > 0 else { reject(r.name, row, "hours/minutes must be greater than 0"); continue }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                b.timeOff.append(.init(id: idCell.exUUID, day: day, typeName: type, seconds: seconds, note: r.cell(cells, "Note").exRawText))
            }
        }

        if let sheet = workbook.sheet(named: "Holidays") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                guard let day = r.cell(cells, "Date", "Day").exDay(calendar: cal) else { reject(r.name, row, "missing or bad date"); continue }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let nameCell = r.cell(cells, "Name", "Holiday")
                b.holidays.append(Holiday(id: idCell.exUUID ?? UUID(), day: day, name: nameCell.exIsEmpty ? "Holiday" : nameCell.exRawText))
            }
        }

        if let sheet = workbook.sheet(named: "Schedule") {
            let r = SheetReader(sheet)
            // Group rows by version (ID when present, else by Effective From), keep first-seen order.
            var order: [String] = []
            var versions: [String: ScheduleVersion] = [:]
            for (row, cells) in r.dataRows {
                guard let from = r.cell(cells, "Effective From", "From").exDay(calendar: cal) else { reject(r.name, row, "missing or bad Effective From"); continue }
                guard let wd = ExchangeFormat.parseWeekday(r.cell(cells, "Weekday", "Day").exText) else { reject(r.name, row, "bad weekday"); continue }
                let idCell = r.cell(cells, "Version ID", "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad Version ID '\(idCell.exText)'"); continue }
                let workdayCell = r.cell(cells, "Workday", "Is Workday")
                guard workdayCell.exIsEmpty || workdayCell.exBool != nil else { reject(r.name, row, "bad Workday flag"); continue }
                let startCell = r.cell(cells, "Start"), endCell = r.cell(cells, "End")
                let start = startCell.exTimeOfDay(calendar: cal), end = endCell.exTimeOfDay(calendar: cal)
                guard startCell.exIsEmpty || start != nil else { reject(r.name, row, "bad Start time"); continue }
                guard endCell.exIsEmpty || end != nil else { reject(r.name, row, "bad End time"); continue }
                let isWorkday = workdayCell.exBool ?? (start != nil && end != nil)
                if isWorkday {
                    guard let s = start, let e = end else { reject(r.name, row, "a workday needs Start and End"); continue }
                    guard s < e else { reject(r.name, row, "Start must be before End"); continue }
                }
                let brkCell = r.cell(cells, "Break (min)", "Break")
                guard brkCell.exIsEmpty || brkCell.exInt != nil else { reject(r.name, row, "bad Break"); continue }
                let base = WeekdaySchedule()
                let ws = WeekdaySchedule(isWorkday: isWorkday, start: start ?? base.start, end: end ?? base.end,
                                         unpaidBreakMinutes: brkCell.exInt ?? 0)
                let key = idCell.exUUID?.uuidString ?? "from:\(from.isoString)"
                if versions[key] == nil {
                    versions[key] = ScheduleVersion(id: idCell.exUUID ?? UUID(), effectiveFrom: from, days: Array(repeating: .off, count: 7))
                    order.append(key)
                }
                versions[key]?[wd] = ws
            }
            b.schedules = order.compactMap { versions[$0] }
        }

        if let sheet = workbook.sheet(named: "Overrides") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                guard let day = r.cell(cells, "Date", "Day").exDay(calendar: cal) else { reject(r.name, row, "missing or bad date"); continue }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let kindText = ExchangeFormat.headerKey(r.cell(cells, "Kind").exText)
                let startCell = r.cell(cells, "Start"), endCell = r.cell(cells, "End"), brkCell = r.cell(cells, "Break (min)", "Break")
                let kind: DayOverrideKind
                switch kindText {
                case "", "none": kind = .none
                case "dayoff", "off": kind = .dayOff
                case "schedule", "scheduleoff":
                    let base = WeekdaySchedule()
                    let start = startCell.exTimeOfDay(calendar: cal), end = endCell.exTimeOfDay(calendar: cal)
                    guard startCell.exIsEmpty || start != nil else { reject(r.name, row, "bad Start time"); continue }
                    guard endCell.exIsEmpty || end != nil else { reject(r.name, row, "bad End time"); continue }
                    guard brkCell.exIsEmpty || brkCell.exInt != nil else { reject(r.name, row, "bad Break"); continue }
                    let isWorkday = kindText == "schedule"
                    if isWorkday {
                        guard let s = start, let e = end else { reject(r.name, row, "a schedule override needs Start and End"); continue }
                        guard s < e else { reject(r.name, row, "Start must be before End"); continue }
                    }
                    kind = .schedule(WeekdaySchedule(isWorkday: isWorkday, start: start ?? base.start, end: end ?? base.end,
                                                     unpaidBreakMinutes: brkCell.exInt ?? 0))
                default: reject(r.name, row, "Kind must be none, dayOff or schedule"); continue
                }
                let earlyCell = r.cell(cells, "Count Early", "Count Early Arrival"), excusedCell = r.cell(cells, "Excused")
                guard earlyCell.exIsEmpty || earlyCell.exBool != nil else { reject(r.name, row, "bad Count Early flag"); continue }
                guard excusedCell.exIsEmpty || excusedCell.exBool != nil else { reject(r.name, row, "bad Excused flag"); continue }
                b.overrides.append(DayOverride(id: idCell.exUUID ?? UUID(), day: day, kind: kind,
                                               countEarlyArrival: earlyCell.exBool ?? false, excused: excusedCell.exBool ?? false,
                                               note: r.cell(cells, "Note").exRawText))
            }
        }

        if let sheet = workbook.sheet(named: "Adjustments") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                guard let day = r.cell(cells, "Date", "Day").exDay(calendar: cal) else { reject(r.name, row, "missing or bad date"); continue }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let secondsCell = r.cell(cells, "Seconds"), hoursCell = r.cell(cells, "Hours"), minutesCell = r.cell(cells, "Minutes")
                let seconds: Int?
                if !secondsCell.exIsEmpty { seconds = secondsCell.exInt }
                else { seconds = ExchangeFormat.seconds(hoursText: hoursCell.exText, minutesText: minutesCell.exText) }
                guard let secs = seconds else { reject(r.name, row, "missing or bad Seconds/Hours"); continue }
                b.adjustments.append(Adjustment(id: idCell.exUUID ?? UUID(), day: day, seconds: secs, reason: r.cell(cells, "Reason", "Note").exRawText))
            }
        }

        if let sheet = workbook.sheet(named: "Events") {
            let r = SheetReader(sheet)
            for (row, cells) in r.dataRows {
                let locText = r.cell(cells, "Location", "Location ID").exText
                guard !locText.isEmpty else { reject(r.name, row, "missing location"); continue }
                guard let locID = UUID(uuidString: locText) ?? locationIDsByName[ExchangeFormat.nameKey(locText)] else {
                    reject(r.name, row, "unknown location '\(locText)'"); continue
                }
                guard let kind = LocationEventKind(rawValue: r.cell(cells, "Kind").exText.lowercased()) else {
                    reject(r.name, row, "Kind must be enter or exit"); continue
                }
                guard let at = r.cell(cells, "Time", "At").exDate(calendar: cal) else { reject(r.name, row, "missing or bad Time"); continue }
                let idCell = r.cell(cells, "ID")
                guard idCell.exIsEmpty || idCell.exUUID != nil else { reject(r.name, row, "bad ID '\(idCell.exText)'"); continue }
                let sourceText = r.cell(cells, "Source").exText.lowercased()
                guard let source = sourceText.isEmpty ? EventSource.imported : EventSource(rawValue: sourceText) else {
                    reject(r.name, row, "unknown source '\(sourceText)'"); continue
                }
                b.events.append(LocationEvent(id: idCell.exUUID ?? UUID(), locationID: locID, kind: kind, at: at, source: source))
            }
        }

        if let sheet = workbook.sheet(named: "Settings") {
            let r = SheetReader(sheet)
            var settings = store.settings
            var sawSetting = false
            for (row, cells) in r.dataRows {
                let key = r.cell(cells, "Key", "Setting").exText
                let value = r.cell(cells, "Value")
                guard !key.isEmpty else { reject(r.name, row, "missing key"); continue }
                if key.hasPrefix(ExportBuilder.leaveKeyPrefix) {
                    guard let cfg = ExchangeFormat.decode(LeaveBalanceConfig.self, from: value.exText) else {
                        reject(r.name, row, "bad leave balance JSON"); continue
                    }
                    b.leaveBalances.append(cfg)
                    continue
                }
                if key.hasPrefix(ExportBuilder.timeOffTypeKeyPrefix) {
                    guard let t = ExchangeFormat.decode(TimeOffType.self, from: value.exText) else {
                        reject(r.name, row, "bad time-off type JSON"); continue
                    }
                    b.timeOffTypes.append(t)
                    continue
                }
                switch Self.applySetting(key: key, value: value, to: &settings, calendar: cal) {
                case .applied: sawSetting = true
                case .ignored: break
                case .bad(let why): reject(r.name, row, why)
                }
            }
            if sawSetting { b.settings = settings }
        }

        // Locations have no createdAt column: use the earliest related instant in the file.
        let earliestAnywhere = ([b.presence.map { $0.enteredAt }, b.events.map { $0.at }, b.manual.compactMap { $0.startedAt }].flatMap { $0 }).min()
        for i in b.locations.indices {
            let key = ExchangeFormat.nameKey(b.locations[i].name)
            let id = b.locations[i].id
            let related = b.presence.filter { ExchangeFormat.nameKey($0.locationName) == key }.map { $0.enteredAt }
                + b.events.filter { $0.locationID == id }.map { $0.at }
            b.locations[i].createdAt = related.min() ?? earliestAnywhere ?? Date(timeIntervalSince1970: 0)
        }

        b.invalid = invalid.sorted { $0.line < $1.line }
        return b
    }

    /// The `timeZoneIdentifier` row of the Settings sheet when the workbook has one that names a known zone.
    static func workbookTimeZone(_ workbook: Workbook) -> TimeZone? {
        guard let sheet = workbook.sheet(named: "Settings") else { return nil }
        let r = SheetReader(sheet)
        for (_, cells) in r.dataRows where r.cell(cells, "Key", "Setting").exText == "timeZoneIdentifier" {
            return TimeZone(identifier: r.cell(cells, "Value").exText)
        }
        return nil
    }

    enum SettingOutcome { case applied, ignored, bad(String) }

    /// Writes one Settings-sheet row into `settings`. Unknown keys (and `schemaVersion`) are ignored.
    static func applySetting(key: String, value: Cell, to settings: inout Settings, calendar: Calendar) -> SettingOutcome {
        func int(_ assign: (Int) -> Void) -> SettingOutcome {
            guard let v = value.exInt else { return .bad("'\(key)' must be a whole number") }
            assign(v); return .applied
        }
        func bool(_ assign: (Bool) -> Void) -> SettingOutcome {
            guard let v = value.exBool else { return .bad("'\(key)' must be TRUE or FALSE") }
            assign(v); return .applied
        }
        switch key {
        case "graceMinutes": return int { settings.graceMinutes = max(0, $0) }
        case "timerNudgeMinutes": return int { settings.timerNudgeMinutes = max(0, $0) }
        case "bankStartingSeconds": return int { settings.bankStartingSeconds = $0 }
        case "staleOpenSessionHours": return int { settings.staleOpenSessionHours = max(0, $0) }
        case "flapMergeMinutes": return int { settings.flapMergeMinutes = max(0, $0) }
        case "monthlyExportEnabled": return bool { settings.monthlyExportEnabled = $0 }
        case "iCloudBackupEnabled": return bool { settings.iCloudBackupEnabled = $0 }
        case "onboardingCompleted": return bool { settings.onboardingCompleted = $0 }
        case "weekStartsOn":
            guard let wd = ExchangeFormat.parseWeekday(value.exText) else { return .bad("'weekStartsOn' must be a weekday name") }
            settings.weekStartsOn = wd; return .applied
        case "bankStartingAsOf":
            guard let day = value.exDay(calendar: calendar) else { return .bad("'bankStartingAsOf' must be a date") }
            settings.bankStartingAsOf = day; return .applied
        case "manualCategories":
            let text = value.exText
            let list = ExchangeFormat.decode([String].self, from: text)
                ?? text.split(whereSeparator: { $0 == ";" || $0 == "," }).map { ExchangeFormat.trim(String($0)) }.filter { !$0.isEmpty }
            guard !list.isEmpty else { return .bad("'manualCategories' must list at least one category") }
            settings.manualCategories = list; return .applied
        case "defaultManualCategory":
            let text = value.exText
            guard !text.isEmpty else { return .bad("'defaultManualCategory' must not be empty") }
            settings.defaultManualCategory = text; return .applied
        case "exportEmail":
            let text = value.exText
            settings.exportEmail = text.isEmpty ? nil : text; return .applied
        case "timeZoneIdentifier":
            let text = value.exText
            guard TimeZone(identifier: text) != nil else { return .bad("'timeZoneIdentifier' is not a known time zone") }
            settings.timeZoneIdentifier = text; return .applied
        default:
            return .ignored
        }
    }

    /// Rebuilds manual segments from the Manual sheet: the first start and the last end come
    /// from the exact `Started`/`Stopped` cells; interior boundaries from the `HH:mm[:ss]` text,
    /// rolling to the next day whenever a time is earlier than the one before it.
    static func segments(startedAt: Date, stoppedAt: Date?, text: String, calendar: Calendar) -> [ManualSegment]? {
        let trimmed = ExchangeFormat.trim(text)
        guard !trimmed.isEmpty else { return [ManualSegment(start: startedAt, end: stoppedAt)] }
        let dashes = CharacterSet(charactersIn: "–—-")
        var day = DayKey(startedAt, calendar: calendar)
        var cursor = startedAt
        var out: [ManualSegment] = []
        let parts = trimmed.split(separator: ";").map { ExchangeFormat.trim(String($0)) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for (i, part) in parts.enumerated() {
            let ends = part.components(separatedBy: dashes).map { ExchangeFormat.trim($0) }
            guard ends.count == 2 || (ends.count == 1 && i == parts.count - 1) else { return nil }
            guard let st = ExchangeFormat.parseClock(ends[0]) else { return nil }
            var start: Date
            if i == 0 {
                start = startedAt
            } else {
                start = ExchangeFormat.instant(day: day, hour: st.hour, minute: st.minute, second: st.second, calendar: calendar)
                if start < cursor {
                    day = day.adding(days: 1, calendar: calendar)
                    start = ExchangeFormat.instant(day: day, hour: st.hour, minute: st.minute, second: st.second, calendar: calendar)
                }
            }
            var end: Date? = nil
            let endText = ends.count == 2 ? ends[1] : ""
            if !endText.isEmpty {
                guard let et = ExchangeFormat.parseClock(endText) else { return nil }
                var e = ExchangeFormat.instant(day: day, hour: et.hour, minute: et.minute, second: et.second, calendar: calendar)
                if e < start {
                    day = day.adding(days: 1, calendar: calendar)
                    e = ExchangeFormat.instant(day: day, hour: et.hour, minute: et.minute, second: et.second, calendar: calendar)
                }
                end = e
                cursor = e
            }
            out.append(ManualSegment(start: start, end: end))
        }
        if let stoppedAt, !out.isEmpty {
            out[out.count - 1].end = max(stoppedAt, out[out.count - 1].start)
        }
        return out
    }
}
