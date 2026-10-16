import XCTest
import OTModels
@testable import OTLedger

// MARK: - Fixture

/// Deterministic fixture: America/New_York, standard week Mon–Fri 07:00–15:30 effective 2026-01-04,
/// two locations. 2026-10-14 is a Wednesday; `now` defaults to Friday 2026-10-16 20:00.
enum Fixture {
    static let tz = TimeZone(identifier: "America/New_York")!
    static let plantA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let plantB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let otherTypeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let created = Date(timeIntervalSince1970: 1_700_000_000)

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    static func store(scheduleFrom: String = "2026-01-04") -> Store {
        var s = Store(settings: Settings(timeZone: tz))
        s.schedules = [ScheduleVersion.standardWeek(effectiveFrom: day(scheduleFrom))]
        s.locations = [
            WorkLocation(id: plantA, name: "Plant A", latitude: 40.0, longitude: -75.0, createdAt: created),
            WorkLocation(id: plantB, name: "Plant B", latitude: 40.1, longitude: -75.1, createdAt: created),
        ]
        return s
    }

    /// Window seconds of the standard day: 07:00–15:30.
    static let window = 30600
}

func day(_ iso: String) -> DayKey { DayKey(iso: iso)! }

/// `t("2026-10-14", "17:42")` → that wall-clock instant in New York.
func t(_ iso: String, _ hhmm: String) -> Date {
    TimeOfDay(hhmm: hhmm)!.date(on: day(iso), calendar: Fixture.calendar)
}

let defaultNow = t("2026-10-16", "20:00")

func presence(_ iso: String, _ from: String, _ to: String?, at location: UUID = Fixture.plantA,
              gapIsWork: Bool? = nil, source: EventSource = .geofence) -> PresenceSession {
    PresenceSession(locationID: location, enteredAt: t(iso, from), exitedAt: to.map { t(iso, $0) },
                    source: source, followingGapIsWork: gapIsWork)
}

func presence(from: Date, to: Date?, at location: UUID = Fixture.plantA, gapIsWork: Bool? = nil) -> PresenceSession {
    PresenceSession(locationID: location, enteredAt: from, exitedAt: to, followingGapIsWork: gapIsWork)
}

func manualBlock(_ iso: String, _ from: String, _ to: String, countsAs: ManualCountsAs = .extra, category: String = "Home work") -> ManualSession {
    ManualSession.block(category: category, countsAs: countsAs, start: t(iso, from), end: t(iso, to), createdAt: Fixture.created)
}

func timeOff(_ iso: String, _ typeID: UUID, seconds: Int) -> TimeOffEntry {
    TimeOffEntry(day: day(iso), typeID: typeID, seconds: seconds)
}

/// SplitMix64: a tiny deterministic generator for the property test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Schedule resolution (SPEC 4.1)

final class DayScheduleTests: XCTestCase {
    func testStandardWeekResolvesWorkdaysAndWeekends() {
        let s = Fixture.store()
        let wed = Ledger.daySchedule(store: s, day: day("2026-10-14"))
        XCTAssertEqual(wed.kind, .workday)
        XCTAssertEqual(wed.window, Interval(start: t("2026-10-14", "07:00"), end: t("2026-10-14", "15:30")))
        XCTAssertEqual(wed.weekdaySchedule?.expectedSeconds, Fixture.window)

        let sat = Ledger.daySchedule(store: s, day: day("2026-10-17"))
        XCTAssertEqual(sat.kind, .weekend)
        XCTAssertNil(sat.window)
        XCTAssertEqual(sat.weekdaySchedule?.isWorkday, false)
    }

    func testNoScheduleVersionYetMeansNoWindow() {
        var s = Fixture.store()
        s.schedules = []
        let r = Ledger.daySchedule(store: s, day: day("2026-10-14"))
        XCTAssertEqual(r.kind, .weekend)
        XCTAssertNil(r.window)
        XCTAssertNil(r.weekdaySchedule)
        // A version effective later than the day does not apply either.
        let before = Ledger.daySchedule(store: Fixture.store(scheduleFrom: "2026-10-15"), day: day("2026-10-14"))
        XCTAssertNil(before.window)
    }

    func testLatestEffectiveVersionWins() {
        var s = Fixture.store()
        s.schedules.append(ScheduleVersion.standardWeek(effectiveFrom: day("2026-10-14"), start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17)))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-13")).window?.start, t("2026-10-13", "07:00"))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-14")).window?.start, t("2026-10-14", "09:00"))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-14")).window?.end, t("2026-10-14", "17:00"))
    }

    func testPrecedenceDayOffThenScheduleThenHolidayThenVersion() {
        var s = Fixture.store()
        s.holidays = [Holiday(day: day("2026-10-14"), name: "Test day")]
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-14")).kind, .holiday)
        XCTAssertNil(Ledger.daySchedule(store: s, day: day("2026-10-14")).window)

        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))
        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .schedule(custom)))
        let scheduled = Ledger.daySchedule(store: s, day: day("2026-10-14"))
        XCTAssertEqual(scheduled.kind, .workday)
        XCTAssertEqual(scheduled.window, Interval(start: t("2026-10-14", "09:00"), end: t("2026-10-14", "17:00")))

        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .dayOff))
        let off = Ledger.daySchedule(store: s, day: day("2026-10-14"))
        XCTAssertEqual(off.kind, .dayOff)
        XCTAssertNil(off.window)
    }

    func testScheduleOverrideThatIsNotAWorkdayReadsAsWeekend() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .schedule(.off)))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-14")).kind, .weekend)
        // Invalid (start >= end) also yields no window.
        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 10)))))
        XCTAssertNil(Ledger.daySchedule(store: s, day: day("2026-10-14")).window)
    }

    func testExcusedKeepsWindowButChangesKind() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day("2026-10-14"), excused: true))
        let r = Ledger.daySchedule(store: s, day: day("2026-10-14"))
        XCTAssertEqual(r.kind, .excused)
        XCTAssertNotNil(r.window)
        // Excused on a day off: still excused, no window.
        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .dayOff, excused: true))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-14")).kind, .excused)
        XCTAssertNil(Ledger.daySchedule(store: s, day: day("2026-10-14")).window)
    }
}

// MARK: - Window days (SPEC 4.3)

final class WindowDayTests: XCTestCase {
    let d = "2026-10-14"

    func result(_ configure: (inout Store) -> Void, now: Date = defaultNow, day iso: String = "2026-10-14") -> DayResult {
        var s = Fixture.store()
        configure(&s)
        return Ledger.dayResult(store: s, day: day(iso), now: now)
    }

    func testExactScheduleDayIsZero() {
        let r = result { $0.presence = [presence(self.d, "07:00", "15:30")] }
        XCTAssertEqual(r.kind, .workday)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.grossExtraSeconds, 0)
        XCTAssertEqual(r.presenceSeconds, Fixture.window)
        XCTAssertEqual(r.presenceInsideSeconds, Fixture.window)
        XCTAssertEqual(r.expectedSeconds, Fixture.window)
        XCTAssertEqual(r.firstIn, t(d, "07:00"))
        XCTAssertEqual(r.lastOut, t(d, "15:30"))
        XCTAssertEqual(r.flags, [])
    }

    func testStayedLateAdds() {
        let r = result { $0.presence = [presence(self.d, "07:00", "16:12")] }
        XCTAssertEqual(r.deltaSeconds, 2520)
        XCTAssertEqual(r.extraAfterSeconds, 2520)
        XCTAssertEqual(r.grossExtraSeconds, 2520)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertFalse(r.flags.contains(.graceApplied))
    }

    func testLeftEarlyWithinGraceIsForgiven() {
        let r = result { $0.presence = [presence(self.d, "07:00", "15:27")] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.presenceInsideSeconds, Fixture.window - 180)
        XCTAssertTrue(r.flags.contains(.graceApplied))
    }

    func testLeftEarlyExactlyAtGraceBoundary() {
        // Last exit at E − g is still forgiven; one second more is not.
        let atGrace = result { $0.presence = [presence(self.d, "07:00", "15:25")] }
        XCTAssertEqual(atGrace.deltaSeconds, 0)
        XCTAssertTrue(atGrace.flags.contains(.graceApplied))
        let past = result { $0.presence = [presence(from: t(self.d, "07:00"), to: t(self.d, "15:25").addingTimeInterval(-1))] }
        XCTAssertEqual(past.deltaSeconds, -301)
        XCTAssertEqual(past.earlyExitSeconds, 301)
        XCTAssertFalse(past.flags.contains(.graceApplied))
    }

    func testLeftSixMinutesEarlySubtracts() {
        let r = result { $0.presence = [presence(self.d, "07:00", "15:24")] }
        XCTAssertEqual(r.deltaSeconds, -360)
        XCTAssertEqual(r.earlyExitSeconds, 360)
        XCTAssertEqual(r.gapsDeductedSeconds, 360)
        XCTAssertEqual(r.lateArrivalSeconds, 0)
    }

    func testArrivedTenMinutesLateSubtracts() {
        let r = result { $0.presence = [presence(self.d, "07:10", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, -600)
        XCTAssertEqual(r.lateArrivalSeconds, 600)
        XCTAssertEqual(r.gapsDeductedSeconds, 600)
    }

    func testArrivedLateWithinGraceIsForgiven() {
        let r = result { $0.presence = [presence(self.d, "07:05", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertTrue(r.flags.contains(.graceApplied))
        let r2 = result { $0.presence = [presence(self.d, "07:06", "15:30")] }
        XCTAssertEqual(r2.deltaSeconds, -360)
    }

    func testStayedLateWithinGraceDoesNotCount() {
        let r = result { $0.presence = [presence(self.d, "07:00", "15:35")] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.extraAfterSeconds, 0)
        XCTAssertEqual(r.presenceSeconds, Fixture.window + 300)
        XCTAssertTrue(r.flags.contains(.graceApplied))
        let r2 = result { $0.presence = [presence(self.d, "07:00", "15:36")] }
        XCTAssertEqual(r2.deltaSeconds, 360)
        XCTAssertFalse(r2.flags.contains(.graceApplied))
    }

    func testEarlyArrivalIsLoggedButNotCounted() {
        let r = result { $0.presence = [presence(self.d, "06:35", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.extraBeforeSeconds, 1500)
        XCTAssertFalse(r.extraBeforeCounted)
        XCTAssertTrue(r.flags.contains(.earlyArrivalUncounted))
        XCTAssertEqual(r.grossExtraSeconds, 0)
        XCTAssertEqual(r.presenceSeconds, Fixture.window + 1500)
    }

    func testEarlyArrivalCountedViaOverride() {
        let r = result {
            $0.presence = [presence(self.d, "06:35", "15:30")]
            $0.setOverride(DayOverride(day: day(self.d), countEarlyArrival: true))
        }
        XCTAssertEqual(r.deltaSeconds, 1500)
        XCTAssertEqual(r.extraBeforeSeconds, 1500)
        XCTAssertTrue(r.extraBeforeCounted)
        XCTAssertEqual(r.grossExtraSeconds, 1500)
        XCTAssertFalse(r.flags.contains(.earlyArrivalUncounted))
    }

    func testEarlyArrivalWithinGraceIsIgnored() {
        let r = result { $0.presence = [presence(self.d, "06:55", "15:30")] }
        XCTAssertEqual(r.extraBeforeSeconds, 0)
        XCTAssertTrue(r.flags.contains(.graceApplied))
        XCTAssertFalse(r.flags.contains(.earlyArrivalUncounted))
        let r2 = result { $0.presence = [presence(self.d, "06:54", "15:30")] }
        XCTAssertEqual(r2.extraBeforeSeconds, 360)
        XCTAssertTrue(r2.flags.contains(.earlyArrivalUncounted))
    }

    func testLunchGapSameLocationUndecidedIsDeducted() {
        let r = result { $0.presence = [presence(self.d, "07:00", "12:00"), presence(self.d, "13:10", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, -4200)
        XCTAssertEqual(r.gapsDeductedSeconds, 4200)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.presenceInsideSeconds, Fixture.window - 4200)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
    }

    func testLunchGapDecidedWorkIsAddedBack() {
        let r = result { $0.presence = [presence(self.d, "07:00", "12:00", gapIsWork: true), presence(self.d, "13:10", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.gapsWorkSeconds, 4200)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertFalse(r.flags.contains(.gapUndecided))
    }

    func testLunchGapDecidedPersonalIsDeductedWithoutFlag() {
        let r = result { $0.presence = [presence(self.d, "07:00", "12:00", gapIsWork: false), presence(self.d, "13:10", "15:30")] }
        XCTAssertEqual(r.deltaSeconds, -4200)
        XCTAssertFalse(r.flags.contains(.gapUndecided))
    }

    func testGapBetweenLocationsDefaultsToWork() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "12:00", at: Fixture.plantA), presence(self.d, "13:10", "15:30", at: Fixture.plantB)]
        }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.gapsWorkSeconds, 4200)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
    }

    func testGapBetweenLocationsDecidedPersonal() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "12:00", at: Fixture.plantA, gapIsWork: false), presence(self.d, "13:10", "15:30", at: Fixture.plantB)]
        }
        XCTAssertEqual(r.deltaSeconds, -4200)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertFalse(r.flags.contains(.gapUndecided))
    }

    func testGapsAPIReportsTheUndecidedSession() {
        var s = Fixture.store()
        let first = presence(d, "07:00", "12:00")
        s.presence = [first, presence(d, "13:10", "15:30", at: Fixture.plantB)]
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.sessionID, first.id)
        XCTAssertEqual(gaps.first?.fromLocationID, Fixture.plantA)
        XCTAssertEqual(gaps.first?.toLocationID, Fixture.plantB)
        XCTAssertEqual(gaps.first?.secondsInsideWindow, 4200)
        XCTAssertEqual(gaps.first?.interval, Interval(start: t(d, "12:00"), end: t(d, "13:10")))
        XCTAssertNil(gaps.first?.decision)
        XCTAssertEqual(gaps.first?.countsAsWork, true)
        XCTAssertEqual(gaps.first?.isUndecided, true)
        // A gap that lies entirely outside the window is not a gap.
        s.presence = [presence(d, "07:00", "15:30"), presence(d, "18:00", "19:00")]
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
    }

    func testGapClippedToWindowAndGraceNeverAppliesToMidDayGaps() {
        // Arrive 3 min late (forgiven), tiny first session, long gap, then work till the end.
        let r = result { $0.presence = [presence(self.d, "07:03", "07:04"), presence(self.d, "09:00", "15:30")] }
        XCTAssertTrue(r.flags.contains(.graceApplied))
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 116 * 60)
        XCTAssertEqual(r.deltaSeconds, -116 * 60)
        // A gap straddling the end of the window only counts its inside part.
        let r2 = result { $0.presence = [presence(self.d, "07:00", "15:00"), presence(self.d, "16:00", "17:00")] }
        XCTAssertEqual(r2.gapsDeductedSeconds, 1800)
        XCTAssertEqual(r2.extraAfterSeconds, 3600)
        XCTAssertEqual(r2.deltaSeconds, 1800)
        XCTAssertEqual(r2.earlyExitSeconds, 0)
    }

    func testPresenceEntirelyOutsideWindowIsAllDeficit() {
        let r = result { $0.presence = [presence(self.d, "16:00", "18:00")] }
        XCTAssertEqual(r.lateArrivalSeconds, Fixture.window)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.extraAfterSeconds, 7200)
        XCTAssertEqual(r.deltaSeconds, 7200 - Fixture.window)
        XCTAssertTrue(r.flags.contains(.noShow))
    }

    func testFullDayPTOWithNoPresenceIsZero() {
        let r = result { $0.timeOff = [timeOff(self.d, TimeOffType.ptoID, seconds: Fixture.window)] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.timeOffSeconds, Fixture.window)
        XCTAssertEqual(r.flexSpentSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, Fixture.window)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testTimeOffIsCappedAtWindow() {
        let r = result { $0.timeOff = [timeOff(self.d, TimeOffType.ptoID, seconds: 36000)] }
        XCTAssertEqual(r.timeOffSeconds, Fixture.window)
        XCTAssertEqual(r.deltaSeconds, 0)
    }

    func testPTODayWithTwoHoursPresenceCounts() {
        let r = result {
            $0.timeOff = [timeOff(self.d, TimeOffType.ptoID, seconds: Fixture.window)]
            $0.presence = [presence(self.d, "07:00", "09:00")]
        }
        XCTAssertEqual(r.deltaSeconds, 7200)
        XCTAssertEqual(r.presenceInsideSeconds, 7200)
        XCTAssertEqual(r.gapsDeductedSeconds, Fixture.window - 7200)
    }

    func testFlexDayPaysFromTheBank() {
        let r = result { $0.timeOff = [timeOff(self.d, TimeOffType.flexID, seconds: Fixture.window)] }
        XCTAssertEqual(r.deltaSeconds, -Fixture.window)
        XCTAssertEqual(r.timeOffSeconds, Fixture.window)
        XCTAssertEqual(r.flexSpentSeconds, Fixture.window)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testPartialPTOAndLeavingEarlyNetsToZero() {
        let r = result {
            $0.timeOff = [timeOff(self.d, TimeOffType.ptoID, seconds: 4 * 3600)]
            $0.presence = [presence(self.d, "07:00", "11:30")]
        }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 4 * 3600)
        XCTAssertEqual(r.timeOffSeconds, 4 * 3600)
    }

    func testNoShow() {
        let r = result { _ in }
        XCTAssertEqual(r.deltaSeconds, -Fixture.window)
        XCTAssertEqual(r.gapsDeductedSeconds, Fixture.window)
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertNil(r.firstIn)
        XCTAssertTrue(r.flags.contains(.noShow))
        XCTAssertTrue(r.isNoShow)
    }

    func testNoShowNotFlaggedWhileWindowStillOpen() {
        let r = result({ _ in }, now: t("2026-10-16", "10:00"), day: "2026-10-16")
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertTrue(r.flags.contains(.inProgress))
        // The window end itself counts as "ended".
        let atEnd = result({ _ in }, now: t("2026-10-16", "15:30"), day: "2026-10-16")
        XCTAssertTrue(atEnd.flags.contains(.noShow))
    }

    func testNoShowNotFlaggedWhenPartialPTOCoversTheWindow() {
        let short = result { $0.timeOff = [timeOff(self.d, TimeOffType.ptoID, seconds: Fixture.window - 1)] }
        XCTAssertTrue(short.flags.contains(.noShow))
        XCTAssertEqual(short.deltaSeconds, -1)
    }

    func testExcusedDayForcesZeroButKeepsComponents() {
        let r = result { $0.setOverride(DayOverride(day: day(self.d), excused: true)) }
        XCTAssertEqual(r.kind, .excused)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.grossExtraSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, Fixture.window)
        XCTAssertNotNil(r.scheduledWindow)
        XCTAssertFalse(r.flags.contains(.noShow))
        let late = result {
            $0.setOverride(DayOverride(day: day(self.d), excused: true))
            $0.presence = [presence(self.d, "07:00", "17:00")]
        }
        XCTAssertEqual(late.extraAfterSeconds, 5400)
        XCTAssertEqual(late.deltaSeconds, 0)
        XCTAssertEqual(late.grossExtraSeconds, 0)
    }

    func testRegularManualFillsTheSchedule() {
        let r = result { $0.manual = [manualBlock(self.d, "07:00", "15:30", countsAs: .regular)] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.manualRegularSeconds, Fixture.window)
        XCTAssertEqual(r.manualExtraSeconds, 0)
        XCTAssertEqual(r.presenceSeconds, Fixture.window)
        XCTAssertEqual(r.presenceInsideSeconds, Fixture.window)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testRegularManualOutsideWindowPreventsNoShow() {
        let r = result { $0.manual = [manualBlock(self.d, "18:00", "20:00", countsAs: .regular)] }
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertEqual(r.manualRegularSeconds, 7200)
        XCTAssertEqual(r.extraAfterSeconds, 7200)
        XCTAssertEqual(r.deltaSeconds, 7200 - Fixture.window)
    }

    func testExtraManualOnWorkdayAdds() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "15:30")]
            $0.manual = [manualBlock(self.d, "18:00", "20:00")]
        }
        XCTAssertEqual(r.deltaSeconds, 7200)
        XCTAssertEqual(r.manualExtraSeconds, 7200)
        XCTAssertEqual(r.grossExtraSeconds, 7200)
        XCTAssertEqual(r.presenceSeconds, Fixture.window)
    }

    func testExtraManualAloneDoesNotFillTheSchedule() {
        let r = result { $0.manual = [manualBlock(self.d, "08:00", "10:00")] }
        XCTAssertEqual(r.deltaSeconds, 7200 - Fixture.window)
        XCTAssertTrue(r.flags.contains(.noShow))
    }

    func testOverlappingExtraManualBlocksAreNotDoubleCounted() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "15:30")]
            $0.manual = [manualBlock(self.d, "18:00", "19:00", category: "Travel"), manualBlock(self.d, "18:30", "20:00", category: "After hours")]
        }
        XCTAssertEqual(r.manualExtraSeconds, 7200)
        XCTAssertEqual(r.deltaSeconds, 7200)
    }

    func testRunningManualSessionTodayCountsToNowAndSkipsPausedTime() {
        let now = t("2026-10-16", "20:00")
        let r = result({
            $0.presence = [presence("2026-10-16", "07:00", "15:30")]
            var m = ManualSession(category: "Home work", createdAt: Fixture.created)
            m.segments = [ManualSegment(start: t("2026-10-16", "19:00"), end: t("2026-10-16", "19:30")),
                          ManualSegment(start: t("2026-10-16", "19:45"), end: nil)]
            $0.manual = [m]
        }, now: now, day: "2026-10-16")
        XCTAssertEqual(r.manualExtraSeconds, 2700)
        XCTAssertEqual(r.deltaSeconds, 2700)
        XCTAssertTrue(r.flags.contains(.inProgress))
        XCTAssertFalse(r.flags.contains(.openPresence))
    }

    func testPausedManualSessionCountsOnlyClosedSegments() {
        let r = result({
            $0.presence = [presence("2026-10-16", "07:00", "15:30")]
            var m = ManualSession(category: "Home work", createdAt: Fixture.created)
            m.segments = [ManualSegment(start: t("2026-10-16", "18:00"), end: t("2026-10-16", "18:20"))]
            $0.manual = [m]
        }, now: t("2026-10-16", "20:00"), day: "2026-10-16")
        XCTAssertEqual(r.manualExtraSeconds, 1200)
    }

    func testOpenPresenceTodayRunsToNow() {
        let now = t("2026-10-16", "12:00")
        let r = result({ $0.presence = [presence("2026-10-16", "07:00", nil)] }, now: now, day: "2026-10-16")
        XCTAssertTrue(r.flags.contains(.inProgress))
        XCTAssertTrue(r.flags.contains(.openPresence))
        XCTAssertEqual(r.presenceSeconds, 5 * 3600)
        XCTAssertEqual(r.lastOut, now)
        XCTAssertEqual(r.earlyExitSeconds, 12600)
        XCTAssertEqual(r.deltaSeconds, -12600)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testAdjustmentsMoveDeltaAndOnlyPositiveOnesCountAsGross() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "15:30")]
            $0.adjustments = [Adjustment(day: day(self.d), seconds: 1800, reason: "carry-over"), Adjustment(day: day(self.d), seconds: -600)]
        }
        XCTAssertEqual(r.adjustmentSeconds, 1200)
        XCTAssertEqual(r.deltaSeconds, 1200)
        XCTAssertEqual(r.grossExtraSeconds, 1200)
        let negative = result {
            $0.presence = [presence(self.d, "07:00", "15:30")]
            $0.adjustments = [Adjustment(day: day(self.d), seconds: -900)]
        }
        XCTAssertEqual(negative.deltaSeconds, -900)
        XCTAssertEqual(negative.grossExtraSeconds, 0)
    }

    func testScheduleOverrideWithDifferentHours() {
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17), unpaidBreakMinutes: 30)
        let r = result {
            $0.setOverride(DayOverride(day: day(self.d), kind: .schedule(custom)))
            $0.presence = [presence(self.d, "09:00", "17:00")]
        }
        XCTAssertEqual(r.kind, .workday)
        XCTAssertEqual(r.scheduledWindow, Interval(start: t(d, "09:00"), end: t(d, "17:00")))
        XCTAssertEqual(r.expectedSeconds, 8 * 3600 - 1800)
        XCTAssertEqual(r.deltaSeconds, 0)
        // Working the standard hours against the overridden window is an early arrival and an early exit.
        let standard = result {
            $0.setOverride(DayOverride(day: day(self.d), kind: .schedule(custom)))
            $0.presence = [presence(self.d, "07:00", "15:30")]
        }
        XCTAssertEqual(standard.extraBeforeSeconds, 7200)
        XCTAssertEqual(standard.earlyExitSeconds, 5400)
        XCTAssertEqual(standard.deltaSeconds, -5400)
    }

    func testOverlappingSessionsAtSameLocationMerge() {
        let r = result { $0.presence = [presence(self.d, "07:00", "12:00"), presence(self.d, "11:00", "15:30")] }
        XCTAssertEqual(r.presenceSeconds, Fixture.window)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertFalse(r.flags.contains(.overlappingLocations))
        XCTAssertFalse(r.flags.contains(.gapUndecided))
    }

    func testOverlappingLocationsLaterEntryWins() {
        let r = result {
            $0.presence = [presence(self.d, "07:00", "11:00", at: Fixture.plantA), presence(self.d, "10:30", "15:30", at: Fixture.plantB)]
        }
        XCTAssertTrue(r.flags.contains(.overlappingLocations))
        XCTAssertEqual(r.presenceSeconds, Fixture.window)
        XCTAssertEqual(r.deltaSeconds, 0)
        // The earlier session is considered exited when the later one started, so a later gap
        // after the second session belongs to the second session.
        let withGap = result {
            $0.presence = [presence(self.d, "07:00", "15:30", at: Fixture.plantA), presence(self.d, "10:00", "11:00", at: Fixture.plantB, gapIsWork: true),
                           presence(self.d, "12:00", "15:30", at: Fixture.plantA)]
        }
        XCTAssertTrue(withGap.flags.contains(.overlappingLocations))
        XCTAssertEqual(withGap.gapsWorkSeconds, 3600)
        XCTAssertEqual(withGap.deltaSeconds, 0)
    }

    func testFutureDayComputesOnlyScheduleAndFlag() {
        let r = result({ $0.presence = [presence("2026-10-19", "07:00", "15:30")] }, now: defaultNow, day: "2026-10-19")
        XCTAssertEqual(r.flags, [.future])
        XCTAssertEqual(r.kind, .workday)
        XCTAssertNotNil(r.scheduledWindow)
        XCTAssertEqual(r.expectedSeconds, Fixture.window)
        XCTAssertEqual(r.presenceSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, 0)
    }

    func testUnknownTimeOffTypeStillCountsAsTimeOffButNotFlex() {
        let unknown = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let r = result { $0.timeOff = [timeOff(self.d, unknown, seconds: 3600)] }
        XCTAssertEqual(r.timeOffSeconds, 3600)
        XCTAssertEqual(r.flexSpentSeconds, 0)
    }
}

// MARK: - Days without a window (SPEC 4.4)

final class NoWindowDayTests: XCTestCase {
    func testWeekendPresenceAllCounts() {
        var s = Fixture.store()
        s.presence = [presence("2026-10-10", "09:00", "12:00")]
        let r = Ledger.dayResult(store: s, day: day("2026-10-10"), now: defaultNow)
        XCTAssertEqual(r.kind, .weekend)
        XCTAssertNil(r.scheduledWindow)
        XCTAssertEqual(r.expectedSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, 10800)
        XCTAssertEqual(r.grossExtraSeconds, 10800)
        XCTAssertEqual(r.presenceSeconds, 10800)
        XCTAssertEqual(r.extraAfterSeconds, 0)
        XCTAssertEqual(r.flags, [])
    }

    func testHoliday() {
        var s = Fixture.store()
        s.holidays = [Holiday(day: day("2026-10-14"), name: "Founders' Day")]
        let empty = Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow)
        XCTAssertEqual(empty.kind, .holiday)
        XCTAssertEqual(empty.deltaSeconds, 0)
        XCTAssertFalse(empty.flags.contains(.noShow))
        s.presence = [presence("2026-10-14", "08:00", "11:00")]
        let worked = Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow)
        XCTAssertEqual(worked.deltaSeconds, 10800)
        XCTAssertEqual(worked.grossExtraSeconds, 10800)
    }

    func testDayOffOverride() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day("2026-10-14"), kind: .dayOff))
        let r = Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow)
        XCTAssertEqual(r.kind, .dayOff)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.expectedSeconds, 0)
        s.presence = [presence("2026-10-14", "07:00", "15:30")]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow).deltaSeconds, Fixture.window)
    }

    func testTimeOffOnNoWindowDayIsInformationalOnly() {
        var s = Fixture.store()
        s.timeOff = [timeOff("2026-10-10", TimeOffType.ptoID, seconds: 8 * 3600)]
        let r = Ledger.dayResult(store: s, day: day("2026-10-10"), now: defaultNow)
        XCTAssertEqual(r.timeOffSeconds, 8 * 3600) // uncapped
        XCTAssertEqual(r.deltaSeconds, 0)
        s.timeOff = [timeOff("2026-10-10", TimeOffType.flexID, seconds: 3600)]
        let flex = Ledger.dayResult(store: s, day: day("2026-10-10"), now: defaultNow)
        XCTAssertEqual(flex.deltaSeconds, -3600)
        XCTAssertEqual(flex.flexSpentSeconds, 3600)
        XCTAssertEqual(flex.grossExtraSeconds, 0)
    }

    func testManualAndAdjustmentsOnNoWindowDay() {
        var s = Fixture.store()
        s.manual = [manualBlock("2026-10-10", "10:00", "11:00"), manualBlock("2026-10-10", "13:00", "14:00", countsAs: .regular)]
        s.adjustments = [Adjustment(day: day("2026-10-10"), seconds: -300)]
        let r = Ledger.dayResult(store: s, day: day("2026-10-10"), now: defaultNow)
        XCTAssertEqual(r.manualExtraSeconds, 3600)
        XCTAssertEqual(r.manualRegularSeconds, 3600)
        XCTAssertEqual(r.presenceSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, 3600 + 3600 - 300)
        XCTAssertEqual(r.grossExtraSeconds, 7200)
        XCTAssertFalse(r.flags.contains(.gapUndecided))
    }

    func testNoScheduleAtAllTreatsEveryDayAsNoWindow() {
        var s = Fixture.store()
        s.schedules = []
        s.presence = [presence("2026-10-14", "07:00", "15:30")]
        let r = Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow)
        XCTAssertEqual(r.kind, .weekend)
        XCTAssertEqual(r.deltaSeconds, Fixture.window)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testExcusedNoWindowDayIsZero() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day("2026-10-10"), excused: true))
        s.presence = [presence("2026-10-10", "09:00", "12:00")]
        let r = Ledger.dayResult(store: s, day: day("2026-10-10"), now: defaultNow)
        XCTAssertEqual(r.kind, .excused)
        XCTAssertEqual(r.presenceSeconds, 10800)
        XCTAssertEqual(r.deltaSeconds, 0)
    }
}

// MARK: - Midnight and DST

final class BoundaryTests: XCTestCase {
    func testSessionCrossingMidnightSplitsAcrossBothDays() {
        var s = Fixture.store()
        s.presence = [presence("2026-10-14", "07:00", "15:30"),
                      presence(from: t("2026-10-14", "22:00"), to: t("2026-10-15", "02:00")),
                      presence("2026-10-15", "07:00", "15:30")]
        let results = Ledger.dayResults(store: s, from: day("2026-10-14"), through: day("2026-10-15"), now: defaultNow)
        XCTAssertEqual(results.count, 2)
        let wed = results[0], thu = results[1]
        XCTAssertEqual(wed.presenceSeconds, Fixture.window + 7200)
        XCTAssertEqual(wed.extraAfterSeconds, 7200)
        XCTAssertEqual(wed.deltaSeconds, 7200)
        XCTAssertEqual(wed.lastOut, t("2026-10-15", "00:00"))
        XCTAssertFalse(wed.flags.contains(.gapUndecided))
        XCTAssertEqual(thu.presenceSeconds, Fixture.window + 7200)
        XCTAssertEqual(thu.firstIn, t("2026-10-15", "00:00"))
        XCTAssertEqual(thu.extraBeforeSeconds, 7200)
        XCTAssertFalse(thu.extraBeforeCounted)
        XCTAssertTrue(thu.flags.contains(.earlyArrivalUncounted))
        XCTAssertEqual(thu.deltaSeconds, 0)
    }

    func testSessionEndingExactlyAtMidnightDoesNotTouchNextDay() {
        var s = Fixture.store()
        s.presence = [presence(from: t("2026-10-10", "22:00"), to: t("2026-10-11", "00:00"))]
        let results = Ledger.dayResults(store: s, from: day("2026-10-10"), through: day("2026-10-11"), now: defaultNow)
        XCTAssertEqual(results[0].presenceSeconds, 7200)
        XCTAssertEqual(results[1].presenceSeconds, 0)
        XCTAssertNil(results[1].firstIn)
    }

    func testOpenSessionCrossingMidnightRunsToNowOnTheSecondDay() {
        let now = t("2026-10-16", "03:00")
        var s = Fixture.store()
        s.presence = [presence(from: t("2026-10-15", "20:00"), to: nil)]
        let results = Ledger.dayResults(store: s, from: day("2026-10-15"), through: day("2026-10-16"), now: now)
        XCTAssertEqual(results[0].presenceSeconds, 4 * 3600)
        XCTAssertTrue(results[0].flags.contains(.openPresence))
        XCTAssertEqual(results[1].presenceSeconds, 3 * 3600)
        XCTAssertTrue(results[1].flags.contains(.openPresence))
        XCTAssertTrue(results[1].flags.contains(.inProgress))
        XCTAssertEqual(results[1].lastOut, now)
    }

    func testSpringForwardDayDurationsAreRealElapsedSeconds() {
        // 2026-03-08 (Sunday): 02:00 → 03:00 does not exist; the day is 23 hours long.
        var s = Fixture.store()
        s.presence = [presence("2026-03-08", "00:30", "05:30")]
        let r = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(day("2026-03-08").interval(in: Fixture.calendar).seconds, 23 * 3600)
        XCTAssertEqual(r.kind, .weekend)
        XCTAssertEqual(r.presenceSeconds, 4 * 3600)
        XCTAssertEqual(r.deltaSeconds, 4 * 3600)
        // With a window on that day, the schedule and the presence agree on wall-clock times.
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule())))
        s.presence = [presence("2026-03-08", "07:00", "15:30")]
        let scheduled = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(scheduled.scheduledWindow?.seconds, Fixture.window)
        XCTAssertEqual(scheduled.deltaSeconds, 0)
        XCTAssertEqual(scheduled.flags, [])
        // A window spanning the jump is shorter in real seconds and expected follows it.
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 4)))))
        s.presence = [presence("2026-03-08", "01:00", "04:00")]
        let spanning = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(spanning.scheduledWindow?.seconds, 2 * 3600)
        XCTAssertEqual(spanning.expectedSeconds, 2 * 3600)
        XCTAssertEqual(spanning.deltaSeconds, 0)
    }

    func testFallBackDayDurationsAreRealElapsedSeconds() {
        // 2026-11-01 (Sunday): 01:00 → 02:00 happens twice; the day is 25 hours long.
        var s = Fixture.store()
        s.presence = [presence("2026-11-01", "00:30", "05:30")]
        let now = t("2026-11-05", "20:00")
        let r = Ledger.dayResult(store: s, day: day("2026-11-01"), now: now)
        XCTAssertEqual(day("2026-11-01").interval(in: Fixture.calendar).seconds, 25 * 3600)
        XCTAssertEqual(r.presenceSeconds, 6 * 3600)
        XCTAssertEqual(r.deltaSeconds, 6 * 3600)
        // Crossing midnight into the long day: 23:00 Sat → 03:00 Sun is 1 h + 4 h.
        s.presence = [presence(from: t("2026-10-31", "23:00"), to: t("2026-11-01", "03:00"))]
        let results = Ledger.dayResults(store: s, from: day("2026-10-31"), through: day("2026-11-01"), now: now)
        XCTAssertEqual(results[0].presenceSeconds, 3600)
        XCTAssertEqual(results[1].presenceSeconds, 4 * 3600)
        // Scheduled window on the long day.
        s.setOverride(DayOverride(day: day("2026-11-01"), kind: .schedule(WeekdaySchedule())))
        s.presence = [presence("2026-11-01", "07:00", "16:00")]
        let scheduled = Ledger.dayResult(store: s, day: day("2026-11-01"), now: now)
        XCTAssertEqual(scheduled.scheduledWindow?.seconds, Fixture.window)
        XCTAssertEqual(scheduled.deltaSeconds, 1800)
    }

    func testWeekdaysAreCorrectAcrossDSTInARange() {
        let s = Fixture.store()
        let results = Ledger.dayResults(store: s, from: day("2026-03-06"), through: day("2026-03-10"), now: defaultNow)
        XCTAssertEqual(results.map { $0.kind }, [.workday, .weekend, .weekend, .workday, .workday])
        XCTAssertEqual(results.map { $0.day.isoString }, ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"])
        XCTAssertEqual(results[3].scheduledWindow?.start, t("2026-03-09", "07:00"))
        let fall = Ledger.dayResults(store: s, from: day("2026-10-30"), through: day("2026-11-03"), now: t("2026-11-05", "20:00"))
        XCTAssertEqual(fall.map { $0.kind }, [.workday, .weekend, .weekend, .workday, .workday])
        XCTAssertEqual(fall[3].scheduledWindow?.start, t("2026-11-02", "07:00"))
    }

    func testEmptyRangeAndReversedRange() {
        let s = Fixture.store()
        XCTAssertEqual(Ledger.dayResults(store: s, from: day("2026-10-15"), through: day("2026-10-14"), now: defaultNow), [])
        XCTAssertEqual(Ledger.dayResults(store: s, from: day("2026-10-14"), through: day("2026-10-14"), now: defaultNow).count, 1)
    }
}

// MARK: - Summaries (SPEC 4.6)

final class SummaryTests: XCTestCase {
    /// Sat 10-10 +3h weekend; Mon 10-12 +1h late; Tue 10-13 +42m; Wed 10-14 exact; Thu 10-15 −10m; Fri 10-16 exact (today).
    func ledgerStore() -> Store {
        var s = Fixture.store()
        s.settings.bankStartingSeconds = 3600
        s.settings.bankStartingAsOf = day("2026-10-01")
        s.presence = [
            presence("2026-10-10", "09:00", "12:00"),
            presence("2026-10-12", "07:00", "16:30"),
            presence("2026-10-13", "07:00", "16:12"),
            presence("2026-10-14", "07:00", "15:30"),
            presence("2026-10-15", "07:10", "15:30"),
            presence("2026-10-16", "07:00", "15:30"),
        ]
        return s
    }

    func testBalanceSumsFromTrackingStart() {
        let s = ledgerStore()
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-10-10"))
        XCTAssertEqual(Ledger.trackingStart(store: s, now: defaultNow), day("2026-10-10"))
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-09"), now: defaultNow), 3600)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-10"), now: defaultNow), 3600 + 10800)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-15"), now: defaultNow), 3600 + 10800 + 3600 + 2520 + 0 - 600)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), 19920)
        // Future days add nothing.
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-12-31"), now: defaultNow), 19920)
    }

    func testBankStartingAsOfExcludesEarlierDays() {
        var s = ledgerStore()
        s.settings.bankStartingAsOf = day("2026-10-13")
        XCTAssertEqual(Ledger.trackingStart(store: s, now: defaultNow), day("2026-10-13"))
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-12"), now: defaultNow), 3600)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-15"), now: defaultNow), 3600 + 2520 - 600)
        // No-show days before the first fact never enter the balance.
        var late = Fixture.store()
        late.settings.bankStartingAsOf = day("2026-01-01")
        late.presence = [presence("2026-10-14", "07:00", "15:30")]
        XCTAssertEqual(Ledger.balance(store: late, asOf: day("2026-10-14"), now: defaultNow), 0)
        XCTAssertEqual(Ledger.balance(store: late, asOf: day("2026-10-15"), now: defaultNow), -Fixture.window)
    }

    func testSummaryValues() {
        let s = ledgerStore()
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertEqual(sum.balanceSeconds, 19920)
        XCTAssertEqual(sum.monthGrossExtraSeconds, 10800 + 3600 + 2520)
        XCTAssertEqual(sum.monthDeltaSeconds, 10800 + 3600 + 2520 - 600)
        XCTAssertEqual(sum.weekDeltaSeconds, 3600 + 2520 - 600) // week of Sun 10-11 … Sat 10-17
        XCTAssertEqual(sum.ytdDeltaSeconds, 16320)
        XCTAssertEqual(sum.todayDeltaSeconds, 0)
    }

    func testSummaryWeekStartSetting() {
        var s = ledgerStore()
        s.settings.weekStartsOn = .monday
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow).weekDeltaSeconds, 3600 + 2520 - 600)
        // On Sunday 10-11, a Sunday-start week contains only Sunday; a Monday-start week reaches back to Monday 10-05.
        XCTAssertEqual(Ledger.weekStart(containing: day("2026-10-11"), weekStartsOn: .sunday, calendar: Fixture.calendar), day("2026-10-11"))
        XCTAssertEqual(Ledger.weekStart(containing: day("2026-10-11"), weekStartsOn: .monday, calendar: Fixture.calendar), day("2026-10-05"))
        XCTAssertEqual(Ledger.weekStart(containing: day("2026-10-14"), weekStartsOn: .sunday, calendar: Fixture.calendar), day("2026-10-11"))
    }

    func testSummaryAcrossMonthAndYearBoundaries() {
        var s = Fixture.store(scheduleFrom: "2025-01-01")
        s.settings.bankStartingAsOf = day("2025-12-01")
        s.presence = [
            presence("2025-12-31", "07:00", "16:00"), // +30m last year
            presence("2026-01-02", "07:00", "16:00"), // +30m, Friday
            presence("2026-01-05", "07:00", "15:30"),
        ]
        let now = t("2026-01-05", "20:00")
        let sum = Ledger.summary(store: s, now: now)
        XCTAssertEqual(sum.balanceSeconds, 1800 + 1800 + 0 - Fixture.window) // 2026-01-01 Thu is a no-show
        XCTAssertEqual(sum.ytdDeltaSeconds, 1800 - Fixture.window)
        XCTAssertEqual(sum.monthDeltaSeconds, 1800 - Fixture.window)
        XCTAssertEqual(sum.monthGrossExtraSeconds, 1800)
        XCTAssertEqual(sum.weekDeltaSeconds, 0) // week starts Sunday 01-04
        XCTAssertEqual(sum.todayDeltaSeconds, 0)
    }

    func testSummaryOnEmptyStoreIsJustTheStartingBalance() {
        var s = Fixture.store()
        s.settings.bankStartingSeconds = 7200
        let sum = Ledger.summary(store: s, now: t("2026-10-16", "06:00"))
        // Today is a workday still in progress with nothing recorded: the whole window shows as deficit.
        XCTAssertEqual(sum.todayDeltaSeconds, -Fixture.window)
        XCTAssertEqual(sum.balanceSeconds, 7200 - Fixture.window)
        XCTAssertEqual(Ledger.earliestDay(store: s, now: t("2026-10-16", "06:00")), day("2026-10-16"))
    }

    func testTrackingStartInTheFutureStillReportsToday() {
        var s = ledgerStore()
        s.settings.bankStartingAsOf = day("2026-11-01")
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertEqual(sum.balanceSeconds, 3600)
        XCTAssertEqual(sum.weekDeltaSeconds, 0)
        XCTAssertEqual(sum.todayDeltaSeconds, 0)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), 3600)
    }

    func testEarliestDayConsidersEveryFactKind() {
        var s = Fixture.store()
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-10-16"))
        s.adjustments = [Adjustment(day: day("2026-09-01"), seconds: 60)]
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-09-01"))
        s.timeOff = [timeOff("2026-08-20", TimeOffType.ptoID, seconds: 3600)]
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-08-20"))
        s.manual = [manualBlock("2026-07-04", "10:00", "11:00")]
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-07-04"))
        s.presence = [presence("2026-06-01", "07:00", "15:30")]
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-06-01"))
        // Holidays and overrides are not facts.
        s.holidays = [Holiday(day: day("2026-01-01"), name: "New Year")]
        s.setOverride(DayOverride(day: day("2026-02-02"), kind: .dayOff))
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), day("2026-06-01"))
    }
}

// MARK: - Leave balances

final class LeaveBalanceTests: XCTestCase {
    func testMonthlyAccrualAndUsage() {
        var s = Fixture.store()
        s.upsert(LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 36000, asOf: day("2026-01-01"),
                                    accrual: AccrualRule(seconds: 4 * 3600, period: .monthly, anchor: day("2026-01-31"))))
        s.timeOff = [
            timeOff("2026-10-14", TimeOffType.ptoID, seconds: Fixture.window),
            timeOff("2025-12-20", TimeOffType.ptoID, seconds: 7200),      // before asOf: ignored
            timeOff("2026-10-20", TimeOffType.ptoID, seconds: 3600),      // after the asOf day asked for
            timeOff("2026-10-14", TimeOffType.personalID, seconds: 1800), // other type
        ]
        let balances = Ledger.leaveBalances(store: s, asOf: day("2026-10-16"))
        let pto = balances.first { $0.typeID == TimeOffType.ptoID }
        // Grants: Jan 31, Feb 28, Mar 31, Apr 30, May 31, Jun 30, Jul 31, Aug 31, Sep 30 → 9.
        XCTAssertEqual(pto?.startingSeconds, 36000)
        XCTAssertEqual(pto?.accruedSeconds, 9 * 4 * 3600)
        XCTAssertEqual(pto?.usedSeconds, Fixture.window)
        XCTAssertEqual(pto?.remainingSeconds, 36000 + 9 * 4 * 3600 - Fixture.window)
        let personal = balances.first { $0.typeID == TimeOffType.personalID }
        XCTAssertEqual(personal?.accruedSeconds, 0)
        XCTAssertEqual(personal?.usedSeconds, 1800)
        XCTAssertEqual(personal?.remainingSeconds, -1800)
        XCTAssertNil(balances.first { $0.typeID == TimeOffType.flexID })
        // On the Oct 31 boundary the tenth grant lands.
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day("2026-10-31")).first { $0.typeID == TimeOffType.ptoID }?.accruedSeconds, 10 * 4 * 3600)
    }

    func testWeeklyBiweeklyYearlyAccrualAndAsOfLowerBound() {
        let cal = Fixture.calendar
        let weekly = AccrualRule(seconds: 3600, period: .weekly, anchor: day("2026-10-05"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: weekly, from: day("2026-01-01"), through: day("2026-10-16"), calendar: cal), 2 * 3600)
        XCTAssertEqual(Ledger.accruedSeconds(rule: weekly, from: day("2026-10-06"), through: day("2026-10-16"), calendar: cal), 3600)
        XCTAssertEqual(Ledger.accruedSeconds(rule: weekly, from: day("2026-01-01"), through: day("2026-10-04"), calendar: cal), 0)
        XCTAssertEqual(Ledger.accruedSeconds(rule: weekly, from: day("2026-01-01"), through: day("2026-10-05"), calendar: cal), 3600)
        let biweekly = AccrualRule(seconds: 1800, period: .biweekly, anchor: day("2026-01-02"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: biweekly, from: day("2026-01-01"), through: day("2026-01-30"), calendar: cal), 3 * 1800)
        let yearly = AccrualRule(seconds: 40 * 3600, period: .yearly, anchor: day("2024-02-29"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: yearly, from: day("2024-01-01"), through: day("2026-10-16"), calendar: cal), 3 * 40 * 3600)
        XCTAssertEqual(Ledger.accruedSeconds(rule: yearly, from: day("2025-01-01"), through: day("2026-02-27"), calendar: cal), 40 * 3600)
        XCTAssertEqual(Ledger.accruedSeconds(rule: nil, from: day("2024-01-01"), through: day("2026-10-16"), calendar: cal), 0)
        XCTAssertEqual(Ledger.accruedSeconds(rule: AccrualRule(seconds: 0, period: .weekly, anchor: day("2020-01-01")), from: day("2020-01-01"), through: day("2026-10-16"), calendar: cal), 0)
    }

    func testMonthlyAccrualKeepsDayOfMonthAcrossShortMonths() {
        let rule = AccrualRule(seconds: 60, period: .monthly, anchor: day("2026-01-31"))
        // Feb 28 counts, then Mar 31 (not Mar 28).
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-01-01"), through: day("2026-03-30"), calendar: Fixture.calendar), 120)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-01-01"), through: day("2026-03-31"), calendar: Fixture.calendar), 180)
    }

    func testTypesWithoutConfigGetZeroConfigAndStoreOrderIsKept() {
        var s = Fixture.store()
        s.timeOffTypes.append(TimeOffType(id: Fixture.otherTypeID, name: "Comp", kind: .other, tracksBalance: true, deductsFromBank: false))
        s.timeOff = [timeOff("2026-10-14", Fixture.otherTypeID, seconds: 600)]
        let balances = Ledger.leaveBalances(store: s, asOf: day("2026-10-16"))
        XCTAssertEqual(balances.map { $0.typeID }, [TimeOffType.ptoID, TimeOffType.personalID, Fixture.otherTypeID])
        XCTAssertEqual(balances[2].usedSeconds, 600)
        XCTAssertEqual(balances[2].remainingSeconds, -600)
        // Default configs have asOf 2000-01-01 so older usage counts.
        s.timeOff.append(timeOff("2010-05-05", TimeOffType.ptoID, seconds: 100))
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day("2026-10-16"))[0].usedSeconds, 100)
    }
}

// MARK: - Properties and performance

final class PropertyAndPerformanceTests: XCTestCase {
    func testDeltaIdentityHoldsOnRandomDays() {
        var rng = SeededGenerator(seed: 0x5EED_2026)
        var s = Fixture.store()
        s.settings.graceMinutes = 5
        let now = t("2026-12-31", "23:00")
        let start = day("2026-10-01")
        var days: [DayKey] = []
        for i in 0..<60 {
            let d = start.adding(days: i, calendar: Fixture.calendar)
            days.append(d)
            let iso = d.isoString
            func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", min(23, minutes / 60), minutes % 60) }
            // 0–3 presence sessions with random locations and decisions.
            var cursor = Int.random(in: 300...600, using: &rng)
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                let len = Int.random(in: 10...300, using: &rng)
                let end = min(cursor + len, 23 * 60 + 59)
                guard end > cursor else { break }
                let loc = Bool.random(using: &rng) ? Fixture.plantA : Fixture.plantB
                let decision: Bool? = [nil, true, false][Int.random(in: 0..<3, using: &rng)]
                s.presence.append(presence(iso, hhmm(cursor), hhmm(end), at: loc, gapIsWork: decision))
                cursor = end + Int.random(in: 1...120, using: &rng)
                if cursor >= 23 * 60 { break }
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                s.manual.append(manualBlock(iso, "18:00", hhmm(18 * 60 + Int.random(in: 1...120, using: &rng)), countsAs: Bool.random(using: &rng) ? .extra : .regular))
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                let typeID = [TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID][Int.random(in: 0..<3, using: &rng)]
                s.timeOff.append(timeOff(iso, typeID, seconds: Int.random(in: 1...10, using: &rng) * 3600))
            }
            if Int.random(in: 0..<5, using: &rng) == 0 {
                s.adjustments.append(Adjustment(day: d, seconds: Int.random(in: -3600...3600, using: &rng)))
            }
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: s.setOverride(DayOverride(day: d, kind: .dayOff))
            case 1: s.setOverride(DayOverride(day: d, countEarlyArrival: true))
            case 2: s.setOverride(DayOverride(day: d, excused: true))
            case 3: s.holidays.append(Holiday(day: d, name: "H"))
            default: break
            }
        }
        let results = Ledger.dayResults(store: s, from: days[0], through: days[days.count - 1], now: now)
        XCTAssertEqual(results.count, 60)
        var windowDays = 0
        let g = s.settings.graceSeconds
        for r in results {
            XCTAssertFalse(r.flags.contains(.future))
            if r.kind == .excused {
                XCTAssertEqual(r.deltaSeconds, 0)
                XCTAssertEqual(r.grossExtraSeconds, 0)
                continue
            }
            if let w = r.scheduledWindow {
                windowDays += 1
                let earlyCounted = r.extraBeforeCounted ? r.extraBeforeSeconds : 0
                XCTAssertEqual(r.deltaSeconds, r.extraAfterSeconds + earlyCounted - r.gapsDeductedSeconds + r.timeOffSeconds
                               - r.flexSpentSeconds + r.manualExtraSeconds + r.adjustmentSeconds, "\(r.day)")
                XCTAssertEqual(r.grossExtraSeconds, r.extraAfterSeconds + earlyCounted + r.manualExtraSeconds + max(0, r.adjustmentSeconds), "\(r.day)")
                XCTAssertLessThanOrEqual(r.timeOffSeconds, w.seconds)
                let uncovered = w.seconds - r.presenceInsideSeconds
                XCTAssertLessThanOrEqual(r.gapsDeductedSeconds + r.gapsWorkSeconds, uncovered, "\(r.day)")
                XCTAssertGreaterThanOrEqual(r.gapsDeductedSeconds + r.gapsWorkSeconds, uncovered - 2 * g, "\(r.day)")
                XCTAssertGreaterThanOrEqual(r.presenceSeconds, r.presenceInsideSeconds + r.extraAfterSeconds + r.extraBeforeSeconds)
                if r.flags.contains(.noShow) { XCTAssertEqual(r.presenceInsideSeconds, 0) }
            } else {
                XCTAssertEqual(r.deltaSeconds, r.presenceSeconds + r.manualExtraSeconds + r.adjustmentSeconds - r.flexSpentSeconds, "\(r.day)")
                XCTAssertEqual(r.grossExtraSeconds, r.presenceSeconds + r.manualExtraSeconds + max(0, r.adjustmentSeconds), "\(r.day)")
                XCTAssertEqual(r.gapsDeductedSeconds, 0)
                XCTAssertFalse(r.flags.contains(.noShow))
            }
            // Single-day computation agrees with the range computation.
            XCTAssertEqual(Ledger.dayResult(store: s, day: r.day, now: now), r)
        }
        XCTAssertGreaterThan(windowDays, 20)
    }

    func testThreeYearRangeIsFast() {
        var s = Fixture.store(scheduleFrom: "2024-01-01")
        let first = day("2024-01-01")
        let cal = Fixture.calendar
        var d = first
        var count = 0
        while count < 1100 {
            if s.schedules[0][d.weekday(in: cal)].isWorkday {
                let iso = d.isoString
                s.presence.append(presence(iso, "06:58", "12:00", at: Fixture.plantA, gapIsWork: count % 3 == 0 ? true : nil))
                s.presence.append(presence(iso, "12:40", "15:3\(count % 10)", at: count % 5 == 0 ? Fixture.plantB : Fixture.plantA))
                if count % 7 == 0 { s.manual.append(manualBlock(iso, "19:00", "20:00")) }
                if count % 11 == 0 { s.timeOff.append(timeOff(iso, TimeOffType.ptoID, seconds: 3600)) }
            }
            d = d.adding(days: 1, calendar: cal)
            count += 1
        }
        let last = first.adding(days: 1099, calendar: cal)
        XCTAssertGreaterThan(s.presence.count, 1500)
        let now = t("2027-06-01", "12:00")
        let started = Date()
        let results = Ledger.dayResults(store: s, from: first, through: last, now: now)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(results.count, 1100)
        XCTAssertLessThan(elapsed, 2.0, "dayResults over 1100 days took \(elapsed)s")
        XCTAssertEqual(results.filter { $0.flags.contains(.noShow) }.count, 0)
        XCTAssertTrue(results.contains { $0.gapsWorkSeconds > 0 })
        XCTAssertTrue(results.contains { $0.gapsDeductedSeconds > 0 })
        let summaryStarted = Date()
        _ = Ledger.summary(store: s, now: now)
        XCTAssertLessThan(Date().timeIntervalSince(summaryStarted), 2.0)
    }
}
