import Foundation
import OTModels
import OTLedger
import OTXLSX
import OTCSV

/// Builds the Excel workbook described in docs/SPEC.md section 6.1.
///
/// Sheets 3–12 carry IDs so the workbook imports back losslessly; fact sheets are limited
/// to the records that touch `from...through`, while Locations, Schedule and Settings are
/// always complete.
public enum ExportBuilder {
    /// The twelve sheet names, in workbook order.
    public static let sheetNames = ["Summary", "Days", "Presence", "Manual", "TimeOff", "Holidays",
                                    "Locations", "Schedule", "Overrides", "Adjustments", "Events", "Settings"]

    /// Header row of the Summary sheet (key/value lines; leave rows fill all five columns).
    public static let summaryHeader = ["Item", "Value", "Hours", "Accrued (h)", "Used (h)"]
    /// Header row of the Days sheet (SPEC §6.1 item 2).
    public static let daysHeader = ["Date", "Weekday", "Kind", "Sched Start", "Sched End", "Expected (h)", "First In", "Last Out",
                                    "Presence", "Extra After", "Extra Before", "Early Counted", "Gaps Deducted", "Gaps Work",
                                    "Late Arrival", "Early Exit", "Manual Extra", "Manual Regular", "Time Off", "Flex Spent",
                                    "Adjustments", "Delta (h:mm)", "Delta (hours)", "Running Balance (hours)", "Flags"]
    /// Header row of the Presence sheet.
    public static let presenceHeader = ["ID", "Location", "Entered", "Exited", "Duration", "Source", "Gap After", "Note"]
    /// Header row of the Manual sheet.
    public static let manualHeader = ["ID", "Category", "Counts As", "Started", "Stopped", "Active Duration", "Segments", "Note"]
    /// Header row of the TimeOff sheet.
    public static let timeOffHeader = ["ID", "Date", "Type", "Hours", "Minutes", "Note"]
    /// Header row of the Holidays sheet.
    public static let holidaysHeader = ["ID", "Date", "Name"]
    /// Header row of the Locations sheet.
    public static let locationsHeader = ["ID", "Name", "Latitude", "Longitude", "Radius (m)", "Active"]
    /// Header row of the Schedule sheet (one row per version and weekday).
    public static let scheduleHeader = ["Effective From", "Weekday", "Workday", "Start", "End", "Break (min)", "Version ID"]
    /// Header row of the Overrides sheet.
    public static let overridesHeader = ["ID", "Date", "Kind", "Start", "End", "Break", "Count Early", "Excused", "Note"]
    /// Header row of the Adjustments sheet.
    public static let adjustmentsHeader = ["ID", "Date", "Seconds", "Hours", "Reason"]
    /// Header row of the Events sheet.
    public static let eventsHeader = ["ID", "Location", "Kind", "Time", "Source"]
    /// Header row of the Settings sheet.
    public static let settingsHeader = ["Key", "Value"]

    /// Settings-sheet keys, one per `Settings` field, in sheet order.
    public static let settingsKeys = ["graceMinutes", "weekStartsOn", "timerNudgeMinutes", "bankStartingSeconds", "bankStartingAsOf",
                                      "staleOpenSessionHours", "flapMergeMinutes", "manualCategories", "defaultManualCategory",
                                      "exportEmail", "monthlyExportEnabled", "iCloudBackupEnabled", "timeZoneIdentifier",
                                      "onboardingCompleted"]
    /// Settings-sheet key prefixes for the JSON rows that carry leave configs and time-off types.
    public static let leaveKeyPrefix = "leave."
    /// Settings-sheet key prefix for the JSON rows that carry time-off types (`timeOffType.<typeID>`).
    public static let timeOffTypeKeyPrefix = "timeOffType."

    /// The workbook for `dayResults` (already computed for `from...through`).
    ///
    /// The Days sheet's running balance starts at `openingBalanceSeconds` (or `settings.bankStartingSeconds`) plus the running sum of
    /// the deltas in `dayResults`: pass results starting at `settings.bankStartingAsOf` to get the
    /// true bank balance in that column.
    public static func workbook(store: Store, dayResults: [DayResult], from: DayKey, through: DayKey, now: Date,
                                summary: LedgerSummary = LedgerSummary(), leaveBalances: [LeaveBalance] = [],
                                openingBalanceSeconds: Int? = nil) -> Workbook {
        let cal = store.calendar
        let range = RangeFilter(from: from, through: through, calendar: cal, now: now)
        return Workbook(sheets: [
            summarySheet(store: store, from: from, through: through, now: now, summary: summary, leaveBalances: leaveBalances),
            daysSheet(store: store, dayResults: dayResults, now: now, openingBalanceSeconds: openingBalanceSeconds),
            presenceSheet(store: store, range: range),
            manualSheet(store: store, range: range, now: now),
            timeOffSheet(store: store, range: range),
            holidaysSheet(store: store, range: range),
            locationsSheet(store: store),
            scheduleSheet(store: store),
            overridesSheet(store: store, range: range),
            adjustmentsSheet(store: store, range: range),
            eventsSheet(store: store, range: range),
            settingsSheet(store: store),
        ])
    }

    /// `.xlsx` bytes for the range.
    public static func xlsx(store: Store, dayResults: [DayResult], from: DayKey, through: DayKey, now: Date,
                            summary: LedgerSummary = LedgerSummary(), leaveBalances: [LeaveBalance] = [],
                            openingBalanceSeconds: Int? = nil) throws -> Data {
        try XLSXWriter.write(workbook(store: store, dayResults: dayResults, from: from, through: through, now: now,
                                      summary: summary, leaveBalances: leaveBalances,
                                   openingBalanceSeconds: openingBalanceSeconds),
                             timeZone: store.settings.timeZone)
    }

    /// Full-fidelity JSON backup of the store.
    public static func json(store: Store) throws -> Data { try StoreCodec.encode(store) }

    /// The CSV import template header, as column names.
    public static let csvTemplateHeader = ["record", "date", "start", "end", "location", "category", "type", "hours", "minutes", "name", "note", "id"]

    /// The example rows of the CSV import template (SPEC §6.2).
    public static let csvTemplateRows: [[String]] = [
        ["presence", "2026-10-14", "07:02", "17:42", "Plant A", "", "", "", "", "", "", ""],
        ["manual", "2026-10-14", "19:00", "20:15", "", "After hours", "", "", "", "", "emails", ""],
        ["timeoff", "2026-10-20", "", "", "", "", "PTO", "8", "0", "", "", ""],
        ["holiday", "2026-11-26", "", "", "", "", "", "", "", "Thanksgiving", "", ""],
        ["adjustment", "2026-10-01", "", "", "", "", "", "1", "30", "", "carry-over from old sheet", ""],
    ]

    /// The CSV import template (header + example rows) from docs/IMPORT_TEMPLATE.md.
    public static func csvTemplate() -> String {
        CSV.serialize([csvTemplateHeader] + csvTemplateRows)
    }

    // MARK: - Sheets

    /// Which facts belong in a range export.
    struct RangeFilter {
        let from: DayKey
        let through: DayKey
        let start: Date
        let end: Date
        let now: Date

        init(from: DayKey, through: DayKey, calendar: Calendar, now: Date) {
            self.from = from
            self.through = through
            self.start = from.start(in: calendar)
            self.end = through.end(in: calendar)
            self.now = now
        }

        func contains(_ day: DayKey) -> Bool { day >= from && day <= through }
        func contains(_ instant: Date) -> Bool { instant >= start && instant < end }
        /// A span `[s, e]` (open spans run to `now`) that touches the range.
        func overlaps(_ s: Date, _ e: Date?) -> Bool {
            let close = e ?? max(now, s)
            return s < end && close >= start
        }
    }

    static func summarySheet(store: Store, from: DayKey, through: DayKey, now: Date, summary: LedgerSummary, leaveBalances: [LeaveBalance]) -> Worksheet {
        func line(_ item: String, _ seconds: Int) -> [Cell] {
            [.string(item), .string(ExchangeFormat.clock(seconds, signed: true)), .number(ExchangeFormat.hours(seconds)), .empty, .empty]
        }
        var rows: [[Cell]] = [summaryHeader.map { .string($0) }]
        rows.append([.string("Generated"), .date(now), .empty, .empty, .empty])
        rows.append([.string("Range"), .string("\(from.isoString) – \(through.isoString)"), .empty, .empty, .empty])
        rows.append(line("Balance", summary.balanceSeconds))
        rows.append(line("This month gross extra", summary.monthGrossExtraSeconds))
        rows.append(line("Month delta", summary.monthDeltaSeconds))
        rows.append(line("Week delta", summary.weekDeltaSeconds))
        rows.append(line("YTD delta", summary.ytdDeltaSeconds))
        for lb in leaveBalances {
            let name = store.timeOffType(id: lb.typeID)?.name ?? lb.typeID.uuidString
            rows.append([.string("Leave: \(name)"), .string(ExchangeFormat.clock(lb.remainingSeconds, signed: true)),
                         .number(ExchangeFormat.hours(lb.remainingSeconds)), .number(ExchangeFormat.hours(lb.accruedSeconds)),
                         .number(ExchangeFormat.hours(lb.usedSeconds))])
        }
        return Worksheet(name: "Summary", rows: rows)
    }

    /// `openingBalanceSeconds` is the bank balance at the end of the day before the first row
    /// (callers exporting a range pass `Ledger.balance(asOf: from - 1 day)`); nil means the rows
    /// start at `settings.bankStartingSeconds`. Days before `Ledger.trackingStart` show their
    /// delta but never move the running balance, exactly like `Ledger.balance`.
    static func daysSheet(store: Store, dayResults: [DayResult], now: Date, openingBalanceSeconds: Int?) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [daysHeader.map { .string($0) }]
        let trackingStart = Ledger.trackingStart(store: store, now: now)
        var running = openingBalanceSeconds ?? store.settings.bankStartingSeconds
        for r in dayResults {
            if r.day >= trackingStart {
                let (sum, overflow) = running.addingReportingOverflow(r.deltaSeconds)
                running = overflow ? (r.deltaSeconds > 0 ? Int.max : Int.min) : sum
            }
            let earlyCounted = r.extraBeforeCounted ? r.extraBeforeSeconds : 0
            func d(_ s: Int) -> Cell { .string(ExchangeFormat.clock(s)) }
            rows.append([
                ExchangeFormat.dayCell(r.day, calendar: cal),
                .string(r.day.weekday(in: cal).name),
                .string(r.kind.rawValue),
                r.scheduledWindow.map { .string(ExchangeFormat.wallClock($0.start, calendar: cal)) } ?? .empty,
                r.scheduledWindow.map { .string(ExchangeFormat.wallClock($0.end, calendar: cal)) } ?? .empty,
                .number(ExchangeFormat.hours(r.expectedSeconds)),
                ExchangeFormat.dateCell(r.firstIn),
                ExchangeFormat.dateCell(r.lastOut),
                d(r.presenceSeconds), d(r.extraAfterSeconds), d(r.extraBeforeSeconds), d(earlyCounted),
                d(r.gapsDeductedSeconds), d(r.gapsWorkSeconds), d(r.lateArrivalSeconds), d(r.earlyExitSeconds),
                d(r.manualExtraSeconds), d(r.manualRegularSeconds), d(r.timeOffSeconds), d(r.flexSpentSeconds),
                .string(ExchangeFormat.clock(r.adjustmentSeconds, signed: true)),
                .string(ExchangeFormat.clock(r.deltaSeconds, signed: true)),
                .number(ExchangeFormat.hours(r.deltaSeconds)),
                .number(ExchangeFormat.hours(running)),
                .string(r.flags.map { $0.rawValue }.joined(separator: ", ")),
            ])
        }
        return Worksheet(name: "Days", rows: rows)
    }

    static func presenceSheet(store: Store, range: RangeFilter) -> Worksheet {
        var rows: [[Cell]] = [presenceHeader.map { .string($0) }]
        let sessions = store.presence.filter { range.overlaps($0.enteredAt, $0.exitedAt) }
            .sorted { ($0.enteredAt, $0.id.uuidString) < ($1.enteredAt, $1.id.uuidString) }
        for s in sessions {
            let gap: String
            switch s.followingGapIsWork {
            case .some(true): gap = "work"
            case .some(false): gap = "personal"
            case .none: gap = ""
            }
            rows.append([
                .string(s.id.uuidString),
                .string(store.location(id: s.locationID)?.name ?? s.locationID.uuidString),
                .date(s.enteredAt),
                ExchangeFormat.dateCell(s.exitedAt),
                s.exitedAt.map { .string(ExchangeFormat.clock(Interval(start: s.enteredAt, end: $0).seconds)) } ?? .empty,
                .string(s.source.rawValue),
                .string(gap),
                .string(s.note),
            ])
        }
        return Worksheet(name: "Presence", rows: rows)
    }

    static func manualSheet(store: Store, range: RangeFilter, now: Date) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [manualHeader.map { .string($0) }]
        let sessions = store.manual.filter { m in m.segments.contains { range.overlaps($0.start, $0.end) } }
            .sorted { ($0.startedAt ?? $0.createdAt, $0.id.uuidString) < ($1.startedAt ?? $1.createdAt, $1.id.uuidString) }
        for m in sessions {
            rows.append([
                .string(m.id.uuidString),
                .string(m.category),
                .string(m.countsAs.rawValue),
                ExchangeFormat.dateCell(m.startedAt),
                ExchangeFormat.dateCell(m.endedAt),
                .string(ExchangeFormat.clock(m.activeSeconds(now: now))),
                .string(segmentsText(m.segments, calendar: cal)),
                .string(m.note),
            ])
        }
        return Worksheet(name: "Manual", rows: rows)
    }

    /// `07:00–08:30; 09:00–10:15` (an open segment ends with a dash; seconds shown only when non-zero).
    public static func segmentsText(_ segments: [ManualSegment], calendar: Calendar) -> String {
        segments.map { seg in
            let a = ExchangeFormat.wallClock(seg.start, calendar: calendar)
            let b = seg.end.map { ExchangeFormat.wallClock($0, calendar: calendar) } ?? ""
            return "\(a)–\(b)"
        }.joined(separator: "; ")
    }

    static func timeOffSheet(store: Store, range: RangeFilter) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [timeOffHeader.map { .string($0) }]
        let entries = store.timeOff.filter { range.contains($0.day) }.sorted { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }
        for t in entries {
            let hours = t.seconds / 3600
            let rest = t.seconds % 3600
            let minutes: Cell = rest % 60 == 0 ? .integer(rest / 60) : .number(Double(rest) / 60.0)
            rows.append([
                .string(t.id.uuidString),
                ExchangeFormat.dayCell(t.day, calendar: cal),
                .string(store.timeOffType(id: t.typeID)?.name ?? t.typeID.uuidString),
                .integer(hours),
                minutes,
                .string(t.note),
            ])
        }
        return Worksheet(name: "TimeOff", rows: rows)
    }

    static func holidaysSheet(store: Store, range: RangeFilter) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [holidaysHeader.map { .string($0) }]
        for h in store.holidays.filter({ range.contains($0.day) }).sorted(by: { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }) {
            rows.append([.string(h.id.uuidString), ExchangeFormat.dayCell(h.day, calendar: cal), .string(h.name)])
        }
        return Worksheet(name: "Holidays", rows: rows)
    }

    static func locationsSheet(store: Store) -> Worksheet {
        var rows: [[Cell]] = [locationsHeader.map { .string($0) }]
        for l in store.locations {
            rows.append([.string(l.id.uuidString), .string(l.name), .number(l.latitude), .number(l.longitude),
                         .number(l.radiusMeters), .bool(l.isActive)])
        }
        return Worksheet(name: "Locations", rows: rows)
    }

    static func scheduleSheet(store: Store) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [scheduleHeader.map { .string($0) }]
        for v in store.schedules.sorted(by: { ($0.effectiveFrom, $0.id.uuidString) < ($1.effectiveFrom, $1.id.uuidString) }) {
            for wd in Weekday.allCases {
                let s = v[wd]
                rows.append([
                    ExchangeFormat.dayCell(v.effectiveFrom, calendar: cal),
                    .string(wd.name),
                    .bool(s.isWorkday),
                    .string(s.start.hhmm),
                    .string(s.end.hhmm),
                    .integer(s.unpaidBreakMinutes),
                    .string(v.id.uuidString),
                ])
            }
        }
        return Worksheet(name: "Schedule", rows: rows)
    }

    /// Override kinds as written to the Overrides sheet.
    enum OverrideKindText {
        static let none = "none", dayOff = "dayOff", schedule = "schedule", scheduleOff = "scheduleOff"
    }

    static func overridesSheet(store: Store, range: RangeFilter) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [overridesHeader.map { .string($0) }]
        for o in store.overrides.filter({ range.contains($0.day) }).sorted(by: { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }) {
            var kind = OverrideKindText.none
            var start: Cell = .empty, end: Cell = .empty, brk: Cell = .empty
            switch o.kind {
            case .none: kind = OverrideKindText.none
            case .dayOff: kind = OverrideKindText.dayOff
            case .schedule(let s):
                kind = s.isWorkday ? OverrideKindText.schedule : OverrideKindText.scheduleOff
                start = .string(s.start.hhmm); end = .string(s.end.hhmm); brk = .integer(s.unpaidBreakMinutes)
            }
            rows.append([.string(o.id.uuidString), ExchangeFormat.dayCell(o.day, calendar: cal), .string(kind),
                         start, end, brk, .bool(o.countEarlyArrival), .bool(o.excused), .string(o.note)])
        }
        return Worksheet(name: "Overrides", rows: rows)
    }

    static func adjustmentsSheet(store: Store, range: RangeFilter) -> Worksheet {
        let cal = store.calendar
        var rows: [[Cell]] = [adjustmentsHeader.map { .string($0) }]
        for a in store.adjustments.filter({ range.contains($0.day) }).sorted(by: { ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString) }) {
            rows.append([.string(a.id.uuidString), ExchangeFormat.dayCell(a.day, calendar: cal), .integer(a.seconds),
                         .number(ExchangeFormat.hours(a.seconds)), .string(a.reason)])
        }
        return Worksheet(name: "Adjustments", rows: rows)
    }

    static func eventsSheet(store: Store, range: RangeFilter) -> Worksheet {
        var rows: [[Cell]] = [eventsHeader.map { .string($0) }]
        for e in store.locationEvents.filter({ range.contains($0.at) }).sorted(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) {
            rows.append([.string(e.id.uuidString), .string(store.location(id: e.locationID)?.name ?? e.locationID.uuidString),
                         .string(e.kind.rawValue), .date(e.at), .string(e.source.rawValue)])
        }
        return Worksheet(name: "Events", rows: rows)
    }

    static func settingsSheet(store: Store) -> Worksheet {
        let s = store.settings
        let cal = store.calendar
        var rows: [[Cell]] = [settingsHeader.map { .string($0) }]
        func add(_ key: String, _ value: Cell) { rows.append([.string(key), value]) }
        add("graceMinutes", .integer(s.graceMinutes))
        add("weekStartsOn", .string(s.weekStartsOn.name))
        add("timerNudgeMinutes", .integer(s.timerNudgeMinutes))
        add("bankStartingSeconds", .integer(s.bankStartingSeconds))
        add("bankStartingAsOf", ExchangeFormat.dayCell(s.bankStartingAsOf, calendar: cal))
        add("staleOpenSessionHours", .integer(s.staleOpenSessionHours))
        add("flapMergeMinutes", .integer(s.flapMergeMinutes))
        add("manualCategories", .string(ExchangeFormat.json(s.manualCategories)))
        add("defaultManualCategory", .string(s.defaultManualCategory))
        add("exportEmail", s.exportEmail.map { .string($0) } ?? .empty)
        add("monthlyExportEnabled", .bool(s.monthlyExportEnabled))
        add("iCloudBackupEnabled", .bool(s.iCloudBackupEnabled))
        add("timeZoneIdentifier", .string(s.timeZoneIdentifier))
        add("onboardingCompleted", .bool(s.onboardingCompleted))
        add("schemaVersion", .integer(store.schemaVersion))
        for b in store.leaveBalances {
            add(leaveKeyPrefix + b.typeID.uuidString, .string(ExchangeFormat.json(b)))
        }
        for t in store.timeOffTypes {
            add(timeOffTypeKeyPrefix + t.id.uuidString, .string(ExchangeFormat.json(t)))
        }
        return Worksheet(name: "Settings", rows: rows)
    }
}
