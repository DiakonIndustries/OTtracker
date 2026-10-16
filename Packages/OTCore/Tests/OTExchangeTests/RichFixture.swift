import Foundation
import OTModels
import OTLedger
import OTXLSX
@testable import OTExchange

/// A store that exercises every record kind the exchange formats carry, built for the real
/// `Ledger` (America/New_York, DST days, midnight crossings, open/paused/running sessions,
/// gap decisions of every kind, odd seconds, custom time-off types, non-default settings).
enum RichFixture {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static var settings: Settings {
        var s = Settings(timeZone: timeZone)
        s.graceMinutes = 7
        s.weekStartsOn = .monday
        s.timerNudgeMinutes = 180
        s.bankStartingSeconds = 3600
        s.bankStartingAsOf = DayKey(year: 2026, month: 1, day: 1)
        s.staleOpenSessionHours = 20
        s.flapMergeMinutes = 5
        s.manualCategories = ["Home work", "After hours", "Travel", "Other", "Call"]
        s.defaultManualCategory = "After hours"
        s.exportEmail = "me@example.com"
        s.monthlyExportEnabled = false
        s.iCloudBackupEnabled = true
        s.onboardingCompleted = true
        return s
    }

    static var calendar: Calendar { settings.calendar }

    /// New York wall clock → instant (whole seconds).
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        return calendar.date(from: c)!
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> DayKey { DayKey(year: y, month: m, day: d) }

    static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000002%02d", n))! }

    /// Sunday evening; the open presence and the running timer are "today".
    static let now = date(2026, 11, 15, 21, 0)
    static let rangeFrom = day(2026, 1, 1)
    static let rangeThrough = day(2026, 12, 31)

    static let plantA = uuid(1), plantB = uuid(2)
    static let compTypeID = uuid(3), juryTypeID = uuid(4)
    static let scheduleV1 = uuid(10), scheduleV2 = uuid(11)

    static let compType = TimeOffType(id: compTypeID, name: "Comp", kind: .other, tracksBalance: true, deductsFromBank: false)
    static let juryType = TimeOffType(id: juryTypeID, name: "Jury Duty", kind: .other, tracksBalance: false, deductsFromBank: false)

    static let specialNote = "dentist, then \"lunch\" & <more>\nsecond line 🙂"

    static func store() -> Store {
        var s = Store(settings: settings)
        let std = WeekdaySchedule(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30))
        let summer = WeekdaySchedule(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 16), unpaidBreakMinutes: 30)
        s.schedules = [
            ScheduleVersion(id: scheduleV1, effectiveFrom: day(2026, 1, 4), days: [.off, std, std, std, std, std, .off]),
            ScheduleVersion(id: scheduleV2, effectiveFrom: day(2026, 7, 5), days: [.off, summer, summer, summer, summer, .off, .off], note: "summer"),
        ]
        s.locations = [
            WorkLocation(id: plantA, name: "Plant A", latitude: 40.7128, longitude: -74.006, radiusMeters: 300, isActive: true, createdAt: date(2026, 1, 2, 9, 0)),
            WorkLocation(id: plantB, name: "Plant B & Annex", latitude: 40.8, longitude: -73.9, radiusMeters: 250.5, isActive: false, createdAt: date(2026, 1, 3, 9, 0)),
        ]
        s.presence = [
            // Weekend presence on the spring-forward day: all of it counts.
            PresenceSession(id: uuid(20), locationID: plantA, enteredAt: date(2026, 3, 8, 6, 55), exitedAt: date(2026, 3, 8, 16, 10), source: .geofence),
            // Grace at both ends, odd seconds.
            PresenceSession(id: uuid(21), locationID: plantA, enteredAt: date(2026, 3, 9, 7, 0, 30), exitedAt: date(2026, 3, 9, 15, 35, 15), source: .geofence),
            // Decided gaps: personal, then a work trip to the other site.
            PresenceSession(id: uuid(22), locationID: plantA, enteredAt: date(2026, 3, 10, 7, 0), exitedAt: date(2026, 3, 10, 11, 30), source: .geofence, followingGapIsWork: false, note: specialNote),
            PresenceSession(id: uuid(23), locationID: plantB, enteredAt: date(2026, 3, 10, 13, 0), exitedAt: date(2026, 3, 10, 16, 0), source: .manual, followingGapIsWork: true),
            // Early arrival on an override day that counts it.
            PresenceSession(id: uuid(24), locationID: plantA, enteredAt: date(2026, 3, 17, 7, 30), exitedAt: date(2026, 3, 17, 16, 45), source: .geofence),
            // Undecided gap at the same site.
            PresenceSession(id: uuid(25), locationID: plantA, enteredAt: date(2026, 3, 19, 7, 0), exitedAt: date(2026, 3, 19, 12, 0), source: .geofence),
            PresenceSession(id: uuid(26), locationID: plantA, enteredAt: date(2026, 3, 19, 12, 40), exitedAt: date(2026, 3, 19, 15, 30), source: .geofence),
            // Night shift across midnight and the fall-back hour (6 h on the clock).
            PresenceSession(id: uuid(27), locationID: plantA, enteredAt: date(2026, 10, 31, 22, 0), exitedAt: date(2026, 11, 1, 3, 0), source: .geofence),
            PresenceSession(id: uuid(28), locationID: plantA, enteredAt: date(2026, 11, 1, 22, 0), exitedAt: date(2026, 11, 2, 1, 30), source: .geofence),
            // Imported source.
            PresenceSession(id: uuid(30), locationID: plantB, enteredAt: date(2026, 11, 12, 6, 0), exitedAt: date(2026, 11, 12, 16, 30), source: .imported),
            // Open session today.
            PresenceSession(id: uuid(29), locationID: plantA, enteredAt: date(2026, 11, 15, 7, 2), exitedAt: nil, source: .manual, note: "still here"),
        ]
        s.manual = [
            ManualSession.block(category: "After hours", note: "emails", start: date(2026, 3, 9, 19, 0), end: date(2026, 3, 9, 20, 15), id: uuid(40), createdAt: date(2026, 3, 9, 19, 0)),
            // Multi-segment, regular, odd seconds, createdAt before the first segment.
            ManualSession(id: uuid(41), category: "Home work", note: "remote", countsAs: .regular,
                          segments: [ManualSegment(start: date(2026, 3, 11, 9, 0), end: date(2026, 3, 11, 10, 30, 20)),
                                     ManualSegment(start: date(2026, 3, 11, 11, 0, 5), end: date(2026, 3, 11, 12, 15)),
                                     ManualSegment(start: date(2026, 3, 11, 13, 0), end: date(2026, 3, 11, 14, 0))],
                          isStopped: true, createdAt: date(2026, 3, 11, 8, 59)),
            // Paused.
            ManualSession(id: uuid(42), category: "Travel", segments: [ManualSegment(start: date(2026, 11, 14, 18, 0), end: date(2026, 11, 14, 18, 45))],
                          isStopped: false, createdAt: date(2026, 11, 14, 18, 0)),
            // Running.
            ManualSession(id: uuid(43), category: "Call", segments: [ManualSegment(start: date(2026, 11, 15, 20, 0), end: nil)],
                          isStopped: false, createdAt: date(2026, 11, 15, 20, 0)),
            // Midnight-crossing block.
            ManualSession.block(category: "Other", start: date(2026, 11, 1, 23, 0), end: date(2026, 11, 2, 0, 30), id: uuid(44), createdAt: date(2026, 11, 1, 23, 0)),
            // Regular block over the spring-forward gap (one real hour).
            ManualSession.block(category: "Home work", note: "early", countsAs: .regular, start: date(2026, 3, 8, 1, 30), end: date(2026, 3, 8, 3, 30), id: uuid(45), createdAt: date(2026, 3, 8, 1, 30)),
            // Two segments on two calendar days.
            ManualSession(id: uuid(46), category: "Travel", note: "red-eye",
                          segments: [ManualSegment(start: date(2026, 11, 13, 22, 0), end: date(2026, 11, 13, 23, 30)),
                                     ManualSegment(start: date(2026, 11, 14, 0, 15), end: date(2026, 11, 14, 1, 0))],
                          isStopped: true, createdAt: date(2026, 11, 13, 22, 0)),
        ]
        s.timeOffTypes = TimeOffType.builtIn + [compType, juryType]
        s.timeOff = [
            TimeOffEntry(id: uuid(50), day: day(2026, 3, 12), typeID: TimeOffType.ptoID, seconds: 8 * 3600),
            TimeOffEntry(id: uuid(51), day: day(2026, 3, 13), typeID: TimeOffType.flexID, seconds: 4 * 3600),
            TimeOffEntry(id: uuid(52), day: day(2026, 11, 3), typeID: compTypeID, seconds: 90 * 60, note: "half"),
            TimeOffEntry(id: uuid(53), day: day(2026, 11, 4), typeID: TimeOffType.ptoID, seconds: 2 * 3600 + 15 * 60 + 30),
            TimeOffEntry(id: uuid(54), day: day(2026, 3, 20), typeID: TimeOffType.personalID, seconds: 4 * 3600, note: "appt"),
            TimeOffEntry(id: uuid(55), day: day(2026, 11, 5), typeID: TimeOffType.ptoID, seconds: 3607),
            TimeOffEntry(id: uuid(56), day: day(2026, 11, 6), typeID: juryTypeID, seconds: 8 * 3600),
        ]
        s.holidays = [
            Holiday(id: uuid(60), day: day(2026, 1, 1), name: "New Year's Day"),
            Holiday(id: uuid(61), day: day(2026, 11, 26), name: "Thanksgiving"),
            Holiday(id: uuid(62), day: day(2026, 12, 25), name: "Christmas"),
        ]
        s.overrides = [
            DayOverride(id: uuid(70), day: day(2026, 3, 16), kind: .dayOff, note: "moving"),
            DayOverride(id: uuid(71), day: day(2026, 3, 17), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 16, minute: 30), unpaidBreakMinutes: 30)), countEarlyArrival: true),
            DayOverride(id: uuid(72), day: day(2026, 3, 18), kind: .none, excused: true, note: "snow"),
            DayOverride(id: uuid(73), day: day(2026, 3, 23), kind: .schedule(WeekdaySchedule(isWorkday: false)), note: "comp day"),
            DayOverride(id: uuid(74), day: day(2026, 3, 24), kind: .none, countEarlyArrival: true),
        ]
        s.adjustments = [
            Adjustment(id: uuid(80), day: day(2026, 1, 1), seconds: 5400, reason: "carry-over"),
            Adjustment(id: uuid(81), day: day(2026, 3, 20), seconds: -2700, reason: "correction"),
            Adjustment(id: uuid(82), day: day(2026, 11, 10), seconds: 61, reason: "odd seconds"),
        ]
        s.locationEvents = [
            LocationEvent(id: uuid(90), locationID: plantA, kind: .enter, at: date(2026, 3, 8, 6, 55), source: .geofence),
            LocationEvent(id: uuid(91), locationID: plantA, kind: .exit, at: date(2026, 3, 8, 16, 10), source: .geofence),
            LocationEvent(id: uuid(92), locationID: plantB, kind: .enter, at: date(2026, 3, 10, 13, 0), source: .manual),
            LocationEvent(id: uuid(93), locationID: plantB, kind: .exit, at: date(2026, 3, 10, 16, 0), source: .imported),
        ]
        s.leaveBalances = [
            LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 40 * 3600, asOf: day(2026, 1, 1),
                               accrual: AccrualRule(seconds: 8 * 3600, period: .monthly, anchor: day(2026, 1, 1))),
            LeaveBalanceConfig(typeID: TimeOffType.personalID, startingSeconds: 16 * 3600, asOf: day(2026, 1, 1),
                               accrual: AccrualRule(seconds: 3600, period: .biweekly, anchor: day(2026, 1, 5))),
            LeaveBalanceConfig(typeID: compTypeID, startingSeconds: 0, asOf: day(2026, 1, 1)),
        ]
        s.dismissedInboxKeys = ["gap:\(uuid(25).uuidString)", "noshow:2026-03-18"]
        return s
    }

    /// Per-kind record counts of `store()`.
    static let counts: [String: Int] = ["presence": 11, "manual": 7, "timeOff": 7, "holidays": 3, "adjustments": 3, "locations": 2,
                                         "overrides": 5, "schedules": 2, "events": 4, "timeOffTypes": 5, "leaveBalances": 3]

    // MARK: Ledger-driven export

    static func dayResults(store: Store) -> [DayResult] {
        Ledger.dayResults(store: store, from: rangeFrom, through: rangeThrough, now: now)
    }

    /// Real `.xlsx` bytes for the whole range, with the real ledger's results, summary and leave balances.
    static func xlsx(store: Store = store()) throws -> Data {
        try ExportBuilder.xlsx(store: store, dayResults: dayResults(store: store), from: rangeFrom, through: rangeThrough, now: now,
                               summary: Ledger.summary(store: store, now: now),
                               leaveBalances: Ledger.leaveBalances(store: store, asOf: DayKey(now, calendar: store.calendar)))
    }
}
