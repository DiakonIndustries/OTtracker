import Foundation
import XCTest
import OTModels
import OTXLSX
@testable import OTExchange

/// A fixed store in America/New_York covering DST days, midnight crossings, open/paused/running
/// sessions, odd seconds and a custom time-off type.
enum Fixtures {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static var settings: Settings {
        var s = Settings(timeZone: timeZone)
        s.graceMinutes = 7
        s.bankStartingSeconds = 3600
        s.bankStartingAsOf = DayKey(year: 2026, month: 1, day: 1)
        s.manualCategories = ["Home work", "After hours", "Travel", "Other", "Call"]
        s.defaultManualCategory = "After hours"
        s.exportEmail = "me@example.com"
        s.onboardingCompleted = true
        return s
    }

    static var calendar: Calendar { settings.calendar }

    /// New York wall clock → instant.
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        return calendar.date(from: c)!
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> DayKey { DayKey(year: y, month: m, day: d) }

    static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000001%02d", n))! }

    static let now = date(2026, 11, 15, 21, 0)

    static let plantA = uuid(1), plantB = uuid(2)
    static let compTypeID = uuid(3)
    static let scheduleV1 = uuid(10), scheduleV2 = uuid(11)

    static let compType = TimeOffType(id: compTypeID, name: "Comp", kind: .other, tracksBalance: true, deductsFromBank: false)

    static func store() -> Store {
        var s = Store(settings: settings)
        s.schedules = [
            ScheduleVersion(id: scheduleV1, effectiveFrom: day(2026, 1, 4),
                            days: [.off,
                                   WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30)),
                                   WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30)),
                                   WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30)),
                                   WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30)),
                                   WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30)),
                                   .off]),
            ScheduleVersion(id: scheduleV2, effectiveFrom: day(2026, 7, 5),
                            days: [.off,
                                   WeekdaySchedule(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 16), unpaidBreakMinutes: 30),
                                   WeekdaySchedule(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 16), unpaidBreakMinutes: 30),
                                   WeekdaySchedule(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 16), unpaidBreakMinutes: 30),
                                   WeekdaySchedule(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 16), unpaidBreakMinutes: 30),
                                   .off, .off],
                            note: "summer"),
        ]
        s.locations = [
            WorkLocation(id: plantA, name: "Plant A", latitude: 40.7128, longitude: -74.006, radiusMeters: 300, isActive: true, createdAt: date(2026, 1, 2, 9, 0)),
            WorkLocation(id: plantB, name: "Plant B", latitude: 40.8, longitude: -73.9, radiusMeters: 250, isActive: true, createdAt: date(2026, 1, 3, 9, 0)),
        ]
        s.presence = [
            PresenceSession(id: uuid(20), locationID: plantA, enteredAt: date(2026, 3, 8, 6, 55), exitedAt: date(2026, 3, 8, 16, 10), source: .geofence),
            PresenceSession(id: uuid(21), locationID: plantA, enteredAt: date(2026, 3, 9, 7, 0, 30), exitedAt: date(2026, 3, 9, 15, 35, 15), source: .geofence),
            PresenceSession(id: uuid(22), locationID: plantA, enteredAt: date(2026, 3, 10, 7, 0), exitedAt: date(2026, 3, 10, 11, 30), source: .geofence, followingGapIsWork: false, note: "dentist"),
            PresenceSession(id: uuid(23), locationID: plantB, enteredAt: date(2026, 3, 10, 13, 0), exitedAt: date(2026, 3, 10, 16, 0), source: .manual, followingGapIsWork: true),
            PresenceSession(id: uuid(24), locationID: plantA, enteredAt: date(2026, 11, 1, 22, 0), exitedAt: date(2026, 11, 2, 1, 30), source: .geofence),
            PresenceSession(id: uuid(25), locationID: plantA, enteredAt: date(2026, 11, 15, 7, 2), exitedAt: nil, source: .manual),
        ]
        s.manual = [
            ManualSession.block(category: "After hours", note: "emails", start: date(2026, 3, 9, 19, 0), end: date(2026, 3, 9, 20, 15), id: uuid(30), createdAt: date(2026, 3, 9, 19, 0)),
            ManualSession(id: uuid(31), category: "Home work", note: "remote", countsAs: .regular,
                          segments: [ManualSegment(start: date(2026, 3, 11, 9, 0), end: date(2026, 3, 11, 10, 30, 20)),
                                     ManualSegment(start: date(2026, 3, 11, 11, 0, 5), end: date(2026, 3, 11, 12, 15)),
                                     ManualSegment(start: date(2026, 3, 11, 13, 0), end: date(2026, 3, 11, 14, 0))],
                          isStopped: true, createdAt: date(2026, 3, 11, 9, 0)),
            ManualSession(id: uuid(32), category: "Travel", segments: [ManualSegment(start: date(2026, 11, 14, 18, 0), end: date(2026, 11, 14, 18, 45))],
                          isStopped: false, createdAt: date(2026, 11, 14, 18, 0)),
            ManualSession(id: uuid(33), category: "Call", segments: [ManualSegment(start: date(2026, 11, 15, 20, 0), end: nil)],
                          isStopped: false, createdAt: date(2026, 11, 15, 20, 0)),
            ManualSession.block(category: "Other", start: date(2026, 11, 1, 23, 0), end: date(2026, 11, 2, 0, 30), id: uuid(34), createdAt: date(2026, 11, 1, 23, 0)),
        ]
        s.timeOffTypes = TimeOffType.builtIn + [compType]
        s.timeOff = [
            TimeOffEntry(id: uuid(40), day: day(2026, 3, 12), typeID: TimeOffType.ptoID, seconds: 8 * 3600),
            TimeOffEntry(id: uuid(41), day: day(2026, 3, 13), typeID: TimeOffType.flexID, seconds: 4 * 3600),
            TimeOffEntry(id: uuid(42), day: day(2026, 11, 3), typeID: compTypeID, seconds: 90 * 60, note: "half"),
            TimeOffEntry(id: uuid(43), day: day(2026, 11, 4), typeID: TimeOffType.ptoID, seconds: 2 * 3600 + 15 * 60 + 30),
        ]
        s.holidays = [
            Holiday(id: uuid(50), day: day(2026, 11, 26), name: "Thanksgiving"),
            Holiday(id: uuid(51), day: day(2026, 12, 25), name: "Christmas"),
        ]
        s.overrides = [
            DayOverride(id: uuid(60), day: day(2026, 3, 16), kind: .dayOff, note: "moving"),
            DayOverride(id: uuid(61), day: day(2026, 3, 17), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 16, minute: 30), unpaidBreakMinutes: 30)), countEarlyArrival: true),
            DayOverride(id: uuid(62), day: day(2026, 3, 18), kind: .none, excused: true, note: "snow"),
        ]
        s.adjustments = [
            Adjustment(id: uuid(70), day: day(2026, 1, 1), seconds: 5400, reason: "carry-over"),
            Adjustment(id: uuid(71), day: day(2026, 3, 20), seconds: -2700, reason: "correction"),
        ]
        s.locationEvents = [
            LocationEvent(id: uuid(80), locationID: plantA, kind: .enter, at: date(2026, 3, 8, 6, 55), source: .geofence),
            LocationEvent(id: uuid(81), locationID: plantA, kind: .exit, at: date(2026, 3, 8, 16, 10), source: .geofence),
            LocationEvent(id: uuid(82), locationID: plantB, kind: .enter, at: date(2026, 3, 10, 13, 0), source: .manual),
        ]
        s.leaveBalances = [
            LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 40 * 3600, asOf: day(2026, 1, 1),
                               accrual: AccrualRule(seconds: 8 * 3600, period: .monthly, anchor: day(2026, 1, 1))),
            LeaveBalanceConfig(typeID: TimeOffType.personalID, startingSeconds: 16 * 3600, asOf: day(2026, 1, 1)),
            LeaveBalanceConfig(typeID: compTypeID, startingSeconds: 0, asOf: day(2026, 1, 1)),
        ]
        s.dismissedInboxKeys = ["gap:00000000-0000-4000-8000-000000000122"]
        return s
    }

    static let rangeFrom = day(2026, 1, 1)
    static let rangeThrough = day(2026, 12, 31)

    /// Hand-built day results for the Days sheet (the ledger is a stub in this worktree).
    static func dayResults() -> [DayResult] {
        [
            DayResult(day: day(2026, 3, 9), kind: .workday,
                      scheduledWindow: Interval(start: date(2026, 3, 9, 7, 0), end: date(2026, 3, 9, 15, 30)), expectedSeconds: 30600,
                      firstIn: date(2026, 3, 9, 7, 0, 30), lastOut: date(2026, 3, 9, 15, 35, 15),
                      presenceSeconds: 30885, presenceInsideSeconds: 30570, extraAfterSeconds: 315,
                      deltaSeconds: 315, grossExtraSeconds: 315, flags: [.graceApplied]),
            DayResult(day: day(2026, 3, 10), kind: .workday,
                      scheduledWindow: Interval(start: date(2026, 3, 10, 7, 0), end: date(2026, 3, 10, 15, 30)), expectedSeconds: 30600,
                      firstIn: date(2026, 3, 10, 7, 0), lastOut: date(2026, 3, 10, 16, 0),
                      presenceSeconds: 27000, presenceInsideSeconds: 25200, extraAfterSeconds: 1800,
                      gapsDeductedSeconds: 5400, deltaSeconds: -3600, grossExtraSeconds: 1800, flags: [.gapUndecided]),
            DayResult(day: day(2026, 3, 12), kind: .workday,
                      scheduledWindow: Interval(start: date(2026, 3, 12, 7, 0), end: date(2026, 3, 12, 15, 30)), expectedSeconds: 30600,
                      gapsDeductedSeconds: 30600, timeOffSeconds: 28800, deltaSeconds: -1800, grossExtraSeconds: 0),
            DayResult(day: day(2026, 11, 1), kind: .weekend, presenceSeconds: 7200, deltaSeconds: 7200, grossExtraSeconds: 7200),
        ]
    }

    static let summary = LedgerSummary(balanceSeconds: 5400, monthGrossExtraSeconds: 7200, monthDeltaSeconds: 6300,
                                       weekDeltaSeconds: -900, ytdDeltaSeconds: 1800, todayDeltaSeconds: 0)

    static let leaveBalances = [
        LeaveBalance(typeID: TimeOffType.ptoID, startingSeconds: 40 * 3600, accruedSeconds: 80 * 3600, usedSeconds: 10 * 3600 + 15 * 60 + 30),
        LeaveBalance(typeID: TimeOffType.personalID, startingSeconds: 16 * 3600, accruedSeconds: 0, usedSeconds: 0),
    ]

    static func workbook(store: Store = store()) -> Workbook {
        ExportBuilder.workbook(store: store, dayResults: dayResults(), from: rangeFrom, through: rangeThrough, now: now,
                               summary: summary, leaveBalances: leaveBalances)
    }

    /// A worksheet from header + rows of cells.
    static func sheet(_ name: String, _ header: [String], _ rows: [[Cell]]) -> Worksheet {
        Worksheet(name: name, rows: [header.map { Cell.string($0) }] + rows)
    }
}

extension Array where Element == Cell {
    var texts: [String] { map { $0.stringValue ?? "" } }
}

/// Equality on a `Cell` with a tolerance for doubles.
func XCTAssertCell(_ cell: Cell?, _ expected: Cell, file: StaticString = #filePath, line: UInt = #line) {
    guard let cell else { return XCTFail("missing cell, expected \(expected)", file: file, line: line) }
    switch (cell, expected) {
    case (.number(let a), .number(let b)): XCTAssertEqual(a, b, accuracy: 1e-9, file: file, line: line)
    default: XCTAssertEqual(cell, expected, file: file, line: line)
    }
}
