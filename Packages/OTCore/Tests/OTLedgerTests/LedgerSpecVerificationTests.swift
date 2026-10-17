import XCTest
import OTModels
@testable import OTLedger

// Rule-by-rule verification of SPEC.md section 4 (schedule resolution, the 4.3 formulas, grace
// at exactly g / g−1 s / g+1 s on both ends, mid-day gap decisions, the worked examples, no-show
// conditions one at a time, summaries, leave accrual boundaries) plus determinism and a 300-day
// randomized identity check. Reuses the fixture and helpers of LedgerTests.swift:
// America/New_York, Mon–Fri 07:00–15:30 effective 2026-01-04, grace 5 min, 2026-10-14 is a Wednesday.

/// `at("2026-10-14", "07:00", 301)` → that wall-clock instant plus `seconds`.
private func at(_ iso: String, _ hhmm: String, _ seconds: Int = 0) -> Date {
    t(iso, hhmm).addingTimeInterval(TimeInterval(seconds))
}

private let d = "2026-10-14"
private let S = t(d, "07:00")
private let E = t(d, "15:30")
private let W = Fixture.window // 30600
private let g = 300

/// Day result for `d` (or `iso`) on the fixture store after `configure`.
private func ledger(_ configure: (inout Store) -> Void = { _ in }, day iso: String = d, now: Date = defaultNow) -> DayResult {
    var s = Fixture.store()
    configure(&s)
    return Ledger.dayResult(store: s, day: day(iso), now: now)
}

// MARK: - 4.1 Schedule resolution order

final class ScheduleResolutionOrderTests: XCTestCase {
    func testScheduleOverrideBeatsHolidayAndHolidayBeatsVersion() {
        var s = Fixture.store()
        s.holidays = [Holiday(day: day(d), name: "Founders' Day")]
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day(d)).kind, .holiday)
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))
        s.setOverride(DayOverride(day: day(d), kind: .schedule(custom)))
        let r = Ledger.daySchedule(store: s, day: day(d))
        XCTAssertEqual(r.kind, .workday)
        XCTAssertEqual(r.window, Interval(start: t(d, "09:00"), end: t(d, "17:00")))
        // A `.none` override (decision only) leaves the holiday in charge.
        s.setOverride(DayOverride(day: day(d), countEarlyArrival: true))
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day(d)).kind, .holiday)
        XCTAssertNil(Ledger.daySchedule(store: s, day: day(d)).window)
    }

    func testExcusedCombinesWithEveryResolution() {
        var s = Fixture.store()
        s.holidays = [Holiday(day: day(d), name: "H")]
        s.setOverride(DayOverride(day: day(d), excused: true))
        var r = Ledger.daySchedule(store: s, day: day(d))
        XCTAssertEqual(r.kind, .excused)
        XCTAssertNil(r.window)
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17), unpaidBreakMinutes: 45)
        s.setOverride(DayOverride(day: day(d), kind: .schedule(custom), excused: true))
        r = Ledger.daySchedule(store: s, day: day(d))
        XCTAssertEqual(r.kind, .excused)
        XCTAssertEqual(r.window, Interval(start: t(d, "09:00"), end: t(d, "17:00")))
        let result = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(result.expectedSeconds, 8 * 3600 - 45 * 60)
        XCTAssertEqual(result.deltaSeconds, 0)
    }

    func testVersionEffectiveOnTheDayItselfApplies() {
        var s = Fixture.store()
        s.schedules = [ScheduleVersion.standardWeek(effectiveFrom: day(d), start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))]
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day(d)).window?.seconds, 7200)
        XCTAssertNil(Ledger.daySchedule(store: s, day: day("2026-10-13")).window)
        XCTAssertEqual(Ledger.daySchedule(store: s, day: day("2026-10-13")).kind, .weekend)
    }

    func testExpectedSecondsFloorsAtZero() {
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10), unpaidBreakMinutes: 90)
        let r = ledger { $0.setOverride(DayOverride(day: day(d), kind: .schedule(custom))) }
        XCTAssertEqual(r.scheduledWindow?.seconds, 3600)
        XCTAssertEqual(r.expectedSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 3600) // the ledger works on the window, not on expected
    }
}

// MARK: - 4.3 Grace at exactly g, g−1 s, g+1 s on both ends

final class GraceBoundaryTests: XCTestCase {
    func testLateArrivalInOpenClosedIntervalAfterStart() {
        // (S, S + g]: forgiven at g and g − 1; not at g + 1.
        for offset in [g - 1, g] {
            let r = ledger { $0.presence = [presence(from: at(d, "07:00", offset), to: E)] }
            XCTAssertEqual(r.deltaSeconds, 0, "offset \(offset)")
            XCTAssertEqual(r.lateArrivalSeconds, 0)
            XCTAssertEqual(r.gapsDeductedSeconds, 0)
            XCTAssertEqual(r.presenceInsideSeconds, W - offset)
            XCTAssertTrue(r.flags.contains(.graceApplied))
        }
        let r = ledger { $0.presence = [presence(from: at(d, "07:00", g + 1), to: E)] }
        XCTAssertEqual(r.deltaSeconds, -(g + 1))
        XCTAssertEqual(r.lateArrivalSeconds, g + 1)
        XCTAssertEqual(r.gapsDeductedSeconds, g + 1)
        XCTAssertFalse(r.flags.contains(.graceApplied))
        // Exactly on time is not "late"; no grace fires.
        let exact = ledger { $0.presence = [presence(from: S, to: E)] }
        XCTAssertFalse(exact.flags.contains(.graceApplied))
    }

    func testEarlyExitInClosedOpenIntervalBeforeEnd() {
        // [E − g, E): forgiven at g and g − 1 early; not at g + 1.
        for offset in [g - 1, g] {
            let r = ledger { $0.presence = [presence(from: S, to: at(d, "15:30", -offset))] }
            XCTAssertEqual(r.deltaSeconds, 0, "offset \(offset)")
            XCTAssertEqual(r.earlyExitSeconds, 0)
            XCTAssertEqual(r.gapsDeductedSeconds, 0)
            XCTAssertTrue(r.flags.contains(.graceApplied))
        }
        let r = ledger { $0.presence = [presence(from: S, to: at(d, "15:30", -(g + 1)))] }
        XCTAssertEqual(r.deltaSeconds, -(g + 1))
        XCTAssertEqual(r.earlyExitSeconds, g + 1)
        XCTAssertFalse(r.flags.contains(.graceApplied))
    }

    func testOverrunInOpenClosedIntervalAfterEnd() {
        // (E, E + g]: `after` becomes 0 at g and g − 1; counts in full at g + 1.
        for offset in [g - 1, g] {
            let r = ledger { $0.presence = [presence(from: S, to: at(d, "15:30", offset))] }
            XCTAssertEqual(r.deltaSeconds, 0, "offset \(offset)")
            XCTAssertEqual(r.extraAfterSeconds, 0)
            XCTAssertEqual(r.grossExtraSeconds, 0)
            XCTAssertEqual(r.presenceSeconds, W + offset)
            XCTAssertTrue(r.flags.contains(.graceApplied))
        }
        let r = ledger { $0.presence = [presence(from: S, to: at(d, "15:30", g + 1))] }
        XCTAssertEqual(r.deltaSeconds, g + 1)
        XCTAssertEqual(r.extraAfterSeconds, g + 1)
        XCTAssertEqual(r.grossExtraSeconds, g + 1)
        XCTAssertFalse(r.flags.contains(.graceApplied))
    }

    func testUnderrunInClosedOpenIntervalBeforeStart() {
        // [S − g, S): `before` becomes 0 at g and g − 1; shows in full at g + 1 (and only counts when asked).
        for offset in [g - 1, g] {
            let r = ledger { $0.presence = [presence(from: at(d, "07:00", -offset), to: E)] }
            XCTAssertEqual(r.extraBeforeSeconds, 0, "offset \(offset)")
            XCTAssertEqual(r.deltaSeconds, 0)
            XCTAssertTrue(r.flags.contains(.graceApplied))
            XCTAssertFalse(r.flags.contains(.earlyArrivalUncounted))
        }
        let uncounted = ledger { $0.presence = [presence(from: at(d, "07:00", -(g + 1)), to: E)] }
        XCTAssertEqual(uncounted.extraBeforeSeconds, g + 1)
        XCTAssertEqual(uncounted.deltaSeconds, 0)
        XCTAssertEqual(uncounted.grossExtraSeconds, 0)
        XCTAssertTrue(uncounted.flags.contains(.earlyArrivalUncounted))
        XCTAssertFalse(uncounted.flags.contains(.graceApplied))
        let counted = ledger {
            $0.presence = [presence(from: at(d, "07:00", -(g + 1)), to: E)]
            $0.setOverride(DayOverride(day: day(d), countEarlyArrival: true))
        }
        XCTAssertEqual(counted.deltaSeconds, g + 1)
        XCTAssertEqual(counted.grossExtraSeconds, g + 1)
        XCTAssertTrue(counted.extraBeforeCounted)
        // Within grace the leading piece is gone even when early arrival is counted.
        let countedWithinGrace = ledger {
            $0.presence = [presence(from: at(d, "07:00", -g), to: E)]
            $0.setOverride(DayOverride(day: day(d), countEarlyArrival: true))
        }
        XCTAssertEqual(countedWithinGrace.deltaSeconds, 0)
        XCTAssertEqual(countedWithinGrace.extraBeforeSeconds, 0)
    }

    func testGraceComesFromSettings() {
        let ten = ledger {
            $0.settings.graceMinutes = 10
            $0.presence = [presence(from: at(d, "07:00", 600), to: at(d, "15:30", 600))]
        }
        XCTAssertEqual(ten.deltaSeconds, 0)
        XCTAssertTrue(ten.flags.contains(.graceApplied))
        let tenPlusOne = ledger {
            $0.settings.graceMinutes = 10
            $0.presence = [presence(from: at(d, "07:00", 601), to: at(d, "15:30", 601))]
        }
        XCTAssertEqual(tenPlusOne.lateArrivalSeconds, 601)
        XCTAssertEqual(tenPlusOne.extraAfterSeconds, 601)
        XCTAssertEqual(tenPlusOne.deltaSeconds, 0)
        XCTAssertFalse(tenPlusOne.flags.contains(.graceApplied))
        let zero = ledger {
            $0.settings.graceMinutes = 0
            $0.presence = [presence(from: at(d, "07:00", 1), to: at(d, "15:30", -1))]
        }
        XCTAssertEqual(zero.deltaSeconds, -2)
        XCTAssertEqual(zero.lateArrivalSeconds, 1)
        XCTAssertEqual(zero.earlyExitSeconds, 1)
        XCTAssertFalse(zero.flags.contains(.graceApplied))
    }

    func testGraceAtBothEndsAtOnce() {
        let inside = ledger { $0.presence = [presence(d, "07:05", "15:25")] }
        XCTAssertEqual(inside.deltaSeconds, 0)
        XCTAssertEqual(inside.presenceInsideSeconds, W - 600)
        XCTAssertEqual(inside.gapsDeductedSeconds, 0)
        let outside = ledger { $0.presence = [presence(d, "06:55", "15:35")] }
        XCTAssertEqual(outside.deltaSeconds, 0)
        XCTAssertEqual(outside.extraBeforeSeconds, 0)
        XCTAssertEqual(outside.extraAfterSeconds, 0)
        XCTAssertEqual(outside.presenceSeconds, W + 600)
        XCTAssertEqual(outside.presenceInsideSeconds, W)
    }

    func testGraceNeverForgivesAMidDayGapHoweverSmall() {
        let r = ledger { $0.presence = [presence(d, "07:00", "12:00"), presence(from: at(d, "12:00", 1), to: E)] }
        XCTAssertEqual(r.gapsDeductedSeconds, 1)
        XCTAssertEqual(r.deltaSeconds, -1)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        XCTAssertFalse(r.flags.contains(.graceApplied))
        // Touching intervals are one block: no gap at all.
        let touching = ledger { $0.presence = [presence(d, "07:00", "12:00"), presence(d, "12:00", "15:30")] }
        XCTAssertEqual(touching.gapsDeductedSeconds, 0)
        XCTAssertEqual(touching.presenceSeconds, W)
        XCTAssertFalse(touching.flags.contains(.gapUndecided))
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "12:00"), presence(d, "12:00", "15:30")]
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
    }

    func testGraceOnDSTDays() {
        // Fall back (25 h day) and spring forward (23 h day): grace is measured in real seconds at the window edges.
        for (iso, now) in [("2026-11-01", t("2026-11-05", "20:00")), ("2026-03-08", defaultNow)] {
            var s = Fixture.store()
            s.setOverride(DayOverride(day: day(iso), kind: .schedule(WeekdaySchedule())))
            s.presence = [presence(from: at(iso, "07:00", -g), to: at(iso, "15:30", g))]
            let r = Ledger.dayResult(store: s, day: day(iso), now: now)
            XCTAssertEqual(r.deltaSeconds, 0, iso)
            XCTAssertEqual(r.presenceSeconds, W + 2 * g, iso)
            XCTAssertTrue(r.flags.contains(.graceApplied), iso)
            s.presence = [presence(from: at(iso, "07:00", -(g + 1)), to: at(iso, "15:30", g + 1))]
            let past = Ledger.dayResult(store: s, day: day(iso), now: now)
            XCTAssertEqual(past.deltaSeconds, g + 1, iso)
            XCTAssertEqual(past.extraBeforeSeconds, g + 1, iso)
        }
    }
}

// MARK: - 4.3 Worked examples on an 8-hour window (09:00–17:00)

final class WorkedExampleTests: XCTestCase {
    static let eight = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))
    let H8 = 8 * 3600

    func eightHourDay(countEarly: Bool = false, _ configure: (inout Store) -> Void) -> DayResult {
        ledger {
            $0.setOverride(DayOverride(day: day(d), kind: .schedule(WorkedExampleTests.eight), countEarlyArrival: countEarly))
            configure(&$0)
        }
    }

    func testStayLateIsAdded() {
        let r = eightHourDay { $0.presence = [presence(d, "09:00", "18:00")] }
        XCTAssertEqual(r.extraAfterSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, 3600)
        XCTAssertEqual(r.grossExtraSeconds, 3600)
    }

    func testLeaveEarlyIsSubtracted() {
        let r = eightHourDay { $0.presence = [presence(d, "09:00", "16:00")] }
        XCTAssertEqual(r.earlyExitSeconds, 3600)
        XCTAssertEqual(r.gapsDeductedSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, -3600)
        XCTAssertEqual(r.grossExtraSeconds, 0)
    }

    func testArriveLateIsSubtracted() {
        let r = eightHourDay { $0.presence = [presence(d, "10:00", "17:00")] }
        XCTAssertEqual(r.lateArrivalSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, -3600)
    }

    func testArriveEarlyIsIgnoredUnlessCounted() {
        let r = eightHourDay { $0.presence = [presence(d, "08:00", "17:00")] }
        XCTAssertEqual(r.extraBeforeSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.grossExtraSeconds, 0)
        XCTAssertTrue(r.flags.contains(.earlyArrivalUncounted))
        let counted = eightHourDay(countEarly: true) { $0.presence = [presence(d, "08:00", "17:00")] }
        XCTAssertEqual(counted.deltaSeconds, 3600)
        XCTAssertEqual(counted.grossExtraSeconds, 3600)
    }

    func testPopOutForLunchIsSubtractedUnlessMarkedWork() {
        let r = eightHourDay { $0.presence = [presence(d, "09:00", "12:00"), presence(d, "13:00", "17:00")] }
        XCTAssertEqual(r.gapsDeductedSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, -3600)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        let work = eightHourDay { $0.presence = [presence(d, "09:00", "12:00", gapIsWork: true), presence(d, "13:00", "17:00")] }
        XCTAssertEqual(work.gapsWorkSeconds, 3600)
        XCTAssertEqual(work.deltaSeconds, 0)
        let otherSite = eightHourDay { $0.presence = [presence(d, "09:00", "12:00"), presence(d, "13:00", "17:00", at: Fixture.plantB)] }
        XCTAssertEqual(otherSite.deltaSeconds, 0)
        XCTAssertEqual(otherSite.gapsWorkSeconds, 3600)
        XCTAssertTrue(otherSite.flags.contains(.gapUndecided))
    }

    func testFullDayPTOStayedHomeIsZeroAndPTOBalanceDropsEightHours() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day(d), kind: .schedule(WorkedExampleTests.eight)))
        s.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: H8)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.gapsDeductedSeconds, H8)
        XCTAssertEqual(r.timeOffSeconds, H8)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertEqual(Ledger.balance(store: s, asOf: day(d), now: defaultNow), 0)
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day(d)).first { $0.typeID == TimeOffType.ptoID }?.usedSeconds, H8)
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day(d)).first { $0.typeID == TimeOffType.ptoID }?.remainingSeconds, -H8)
    }

    func testFullDayPTOButCameInTwoHoursCounts() {
        let r = eightHourDay {
            $0.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: self.H8)]
            $0.presence = [presence(d, "09:00", "11:00")]
        }
        XCTAssertEqual(r.presenceInsideSeconds, 7200)
        XCTAssertEqual(r.gapsDeductedSeconds, 6 * 3600)
        XCTAssertEqual(r.timeOffSeconds, H8)
        XCTAssertEqual(r.deltaSeconds, 7200)
        XCTAssertEqual(r.grossExtraSeconds, 0) // relief is not "extra time"
    }

    func testFlexDayIsPaidByTheBank() {
        let r = eightHourDay { $0.timeOff = [timeOff(d, TimeOffType.flexID, seconds: self.H8)] }
        XCTAssertEqual(r.gapsDeductedSeconds, H8)
        XCTAssertEqual(r.timeOffSeconds, H8)
        XCTAssertEqual(r.flexSpentSeconds, H8)
        XCTAssertEqual(r.deltaSeconds, -H8)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testFlexSpentIsNeverCappedWhileReliefIs() {
        // 10 h of flex on an 8 h window: +8 h relief, −10 h spend.
        let r = eightHourDay { $0.timeOff = [timeOff(d, TimeOffType.flexID, seconds: 10 * 3600)] }
        XCTAssertEqual(r.timeOffSeconds, H8)
        XCTAssertEqual(r.flexSpentSeconds, 10 * 3600)
        XCTAssertEqual(r.deltaSeconds, -10 * 3600)
        // Mixed types sum into T but only the flex part is spent.
        let mixed = eightHourDay {
            $0.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: 4 * 3600), timeOff(d, TimeOffType.flexID, seconds: 4 * 3600)]
        }
        XCTAssertEqual(mixed.timeOffSeconds, H8)
        XCTAssertEqual(mixed.flexSpentSeconds, 4 * 3600)
        XCTAssertEqual(mixed.deltaSeconds, -4 * 3600)
    }

    func testCustomFlexLikeTypeDeductsFromBank() {
        let compID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let r = eightHourDay {
            $0.timeOffTypes.append(TimeOffType(id: compID, name: "Comp", kind: .other, tracksBalance: false, deductsFromBank: true))
            $0.timeOff = [timeOff(d, compID, seconds: 3600)]
            $0.presence = [presence(d, "09:00", "16:00")]
        }
        XCTAssertEqual(r.timeOffSeconds, 3600)
        XCTAssertEqual(r.flexSpentSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, -3600) // −1 h early exit + 1 h relief − 1 h spend
    }
}

// MARK: - 4.3 Mid-day gaps

final class MidDayGapTests: XCTestCase {
    func testDecisionBelongsToTheEarlierSession() {
        let a = presence(d, "07:00", "12:00", gapIsWork: nil)
        let b = presence(d, "13:00", "15:30", gapIsWork: true) // the later session's decision is about ITS following gap
        let r = ledger { $0.presence = [a, b] }
        XCTAssertEqual(r.gapsDeductedSeconds, 3600)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, -3600)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        let decided = ledger { $0.presence = [presence(d, "07:00", "12:00", gapIsWork: true), presence(d, "13:00", "15:30", gapIsWork: false)] }
        XCTAssertEqual(decided.gapsWorkSeconds, 3600)
        XCTAssertEqual(decided.gapsDeductedSeconds, 0)
        XCTAssertEqual(decided.deltaSeconds, 0)
        XCTAssertFalse(decided.flags.contains(.gapUndecided))
    }

    func testTwoGapsWithMixedDecisions() {
        let first = presence(d, "07:00", "09:00", at: Fixture.plantA)
        let second = presence(d, "09:30", "12:00", at: Fixture.plantA, gapIsWork: true)
        let third = presence(d, "13:00", "15:30", at: Fixture.plantB)
        var s = Fixture.store()
        s.presence = [first, second, third]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.gapsDeductedSeconds, 1800) // same site, undecided → personal
        XCTAssertEqual(r.gapsWorkSeconds, 3600) // decided work
        XCTAssertEqual(r.deltaSeconds, -1800)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].sessionID, first.id)
        XCTAssertEqual(gaps[0].secondsInsideWindow, 1800)
        XCTAssertNil(gaps[0].decision)
        XCTAssertFalse(gaps[0].countsAsWork)
        XCTAssertEqual(gaps[1].sessionID, second.id)
        XCTAssertEqual(gaps[1].secondsInsideWindow, 3600)
        XCTAssertEqual(gaps[1].decision, true)
        XCTAssertTrue(gaps[1].countsAsWork)
        XCTAssertEqual(gaps[1].fromLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[1].toLocationID, Fixture.plantB)
    }

    func testRegularManualSegmentBetweenPresenceSessions() {
        // Presence 07–10 (undecided), regular manual 10:30–11:00, presence 12–15:30 at the same site.
        let a = presence(d, "07:00", "10:00")
        var s = Fixture.store()
        s.presence = [a, presence(d, "12:00", "15:30")]
        s.manual = [manualBlock(d, "10:30", "11:00", countsAs: .regular)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W - 5400)
        XCTAssertEqual(r.manualRegularSeconds, 1800)
        XCTAssertEqual(r.gapsDeductedSeconds, 5400) // 10:00–10:30 and 11:00–12:00, both personal by default
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, -5400)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        XCTAssertFalse(r.flags.contains(.noShow))
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].sessionID, a.id)
        XCTAssertEqual(gaps[0].fromLocationID, Fixture.plantA)
        XCTAssertNil(gaps[0].toLocationID)
        XCTAssertEqual(gaps[0].interval, Interval(start: t(d, "10:00"), end: t(d, "10:30")))
        XCTAssertNil(gaps[1].sessionID) // ended with a manual segment: nothing carries a decision
        XCTAssertNil(gaps[1].fromLocationID)
        XCTAssertEqual(gaps[1].toLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[1].secondsInsideWindow, 3600)
        XCTAssertFalse(gaps[1].countsAsWork)

        // The earlier presence session's decision governs the gap that follows it.
        s.presence[0].followingGapIsWork = true
        let decided = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(decided.gapsWorkSeconds, 1800)
        XCTAssertEqual(decided.gapsDeductedSeconds, 3600)
        XCTAssertEqual(decided.deltaSeconds, -3600)
        XCTAssertTrue(decided.flags.contains(.gapUndecided)) // the manual-ended gap stays undecided

        // Conservative reading of the default: a manual segment has no location, so a gap next to it
        // is never "a different location" and is deducted (see spec question in the verification notes).
        s.presence[0].followingGapIsWork = nil
        s.presence[1].locationID = Fixture.plantB
        let otherSite = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(otherSite.gapsDeductedSeconds, 5400)
        XCTAssertEqual(otherSite.gapsWorkSeconds, 0)
    }

    func testGapStraddlingTheWindowStartCountsOnlyTheInsidePart() {
        var s = Fixture.store()
        s.presence = [presence(d, "05:00", "06:00"), presence(d, "08:00", "15:30")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.extraBeforeSeconds, 3600)
        XCTAssertTrue(r.flags.contains(.earlyArrivalUncounted))
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 3600) // 07:00–08:00
        XCTAssertEqual(r.deltaSeconds, -3600)
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].interval, Interval(start: t(d, "06:00"), end: t(d, "08:00")))
        XCTAssertEqual(gaps[0].secondsInsideWindow, 3600)
    }

    func testGapWhollyOutsideTheWindowIsNotAGapAndCarriesNoFlag() {
        let r = ledger { $0.presence = [presence(d, "05:00", "06:00"), presence(d, "06:30", "15:30")] }
        XCTAssertFalse(r.flags.contains(.gapUndecided))
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.extraBeforeSeconds, 5400)
        XCTAssertEqual(r.deltaSeconds, 0)
    }

    func testNestedSessionAtTheSameSiteKeepsTheOuterSessionsDecision() {
        let outer = presence(d, "07:00", "12:00", gapIsWork: true)
        let inner = presence(d, "08:00", "11:00", gapIsWork: false)
        var s = Fixture.store()
        s.presence = [inner, outer, presence(d, "13:00", "15:30")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.gapsWorkSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow).first?.sessionID, outer.id)
    }
}

// MARK: - 4.5 No-show, one condition at a time

final class NoShowConditionTests: XCTestCase {
    func testAllConditionsTogetherFlag() {
        let r = ledger()
        XCTAssertTrue(r.flags.contains(.noShow))
        XCTAssertEqual(r.deltaSeconds, -W)
    }

    func testOneSecondInsideTheWindowPreventsTheFlag() {
        let r = ledger { $0.presence = [presence(from: S, to: at(d, "07:00", 1))] }
        XCTAssertEqual(r.presenceInsideSeconds, 1)
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertEqual(r.earlyExitSeconds, W - 1)
        XCTAssertEqual(r.deltaSeconds, -(W - 1))
        // Touching the start from outside is not "inside".
        let touching = ledger { $0.presence = [presence(from: at(d, "07:00", -1), to: S)] }
        XCTAssertEqual(touching.presenceInsideSeconds, 0)
        XCTAssertTrue(touching.flags.contains(.noShow))
        XCTAssertEqual(touching.deltaSeconds, -W)
    }

    func testOneSecondOfRegularManualTimeAnywherePreventsTheFlag() {
        let r = ledger { $0.manual = [ManualSession.block(category: "Home work", countsAs: .regular, start: t(d, "20:00"), end: at(d, "20:00", 1), createdAt: Fixture.created)] }
        XCTAssertEqual(r.manualRegularSeconds, 1)
        XCTAssertEqual(r.presenceInsideSeconds, 0)
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertEqual(r.deltaSeconds, 1 - W)
        // Extra manual time, however much, does not.
        let extra = ledger { $0.manual = [manualBlock(d, "07:00", "15:30", countsAs: .extra)] }
        XCTAssertTrue(extra.flags.contains(.noShow))
        XCTAssertEqual(extra.deltaSeconds, 0)
    }

    func testTimeOffEqualToTheWindowPreventsTheFlagOneSecondLessDoesNot() {
        for typeID in [TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID] {
            let full = ledger { $0.timeOff = [timeOff(d, typeID, seconds: W)] }
            XCTAssertFalse(full.flags.contains(.noShow), "\(typeID)")
            let split = ledger { $0.timeOff = [timeOff(d, typeID, seconds: W - 1), timeOff(d, TimeOffType.ptoID, seconds: 1)] }
            XCTAssertFalse(split.flags.contains(.noShow), "\(typeID)")
            let short = ledger { $0.timeOff = [timeOff(d, typeID, seconds: W - 1)] }
            XCTAssertTrue(short.flags.contains(.noShow), "\(typeID)")
        }
    }

    func testExcusedPreventsTheFlag() {
        let r = ledger { $0.setOverride(DayOverride(day: day(d), excused: true)) }
        XCTAssertFalse(r.flags.contains(.noShow))
        XCTAssertEqual(r.gapsDeductedSeconds, W)
    }

    func testWindowEndMustHavePassedToTheSecond() {
        let friday = "2026-10-16"
        let end = t(friday, "15:30")
        let before = ledger(day: friday, now: end.addingTimeInterval(-1))
        XCTAssertFalse(before.flags.contains(.noShow))
        XCTAssertTrue(before.flags.contains(.inProgress))
        // The deficit grows with the clock on an in-progress day (SPEC 4.3): one second before E it is
        // one second short of the window; only the flag waits for E itself (SPEC 4.5).
        XCTAssertEqual(before.deltaSeconds, -(W - 1))
        XCTAssertEqual(before.gapsDeductedSeconds, W - 1)
        let atEnd = ledger(day: friday, now: end)
        XCTAssertTrue(atEnd.flags.contains(.noShow))
        XCTAssertTrue(atEnd.flags.contains(.inProgress))
        XCTAssertEqual(atEnd.deltaSeconds, -W)
    }

    func testNoWindowDaysNeverFlag() {
        XCTAssertFalse(ledger(day: "2026-10-10").flags.contains(.noShow))
        XCTAssertFalse(ledger({ $0.setOverride(DayOverride(day: day(d), kind: .dayOff)) }).flags.contains(.noShow))
        XCTAssertFalse(ledger({ $0.holidays = [Holiday(day: day(d), name: "H")] }).flags.contains(.noShow))
    }
}

// MARK: - 4.3 / 4.4 Components on excused and future days

final class ExcusedAndFutureDayTests: XCTestCase {
    func testExcusedKeepsEveryComponentButZeroesDeltaAndGross() {
        let r = ledger {
            $0.setOverride(DayOverride(day: day(d), excused: true))
            $0.presence = [presence(d, "07:10", "16:00")]
            $0.timeOff = [timeOff(d, TimeOffType.flexID, seconds: 3600)]
            $0.adjustments = [Adjustment(day: day(d), seconds: -600)]
            $0.manual = [manualBlock(d, "19:00", "20:00")]
        }
        XCTAssertEqual(r.kind, .excused)
        XCTAssertEqual(r.lateArrivalSeconds, 600)
        XCTAssertEqual(r.extraAfterSeconds, 1800)
        XCTAssertEqual(r.timeOffSeconds, 3600)
        XCTAssertEqual(r.flexSpentSeconds, 3600)
        XCTAssertEqual(r.adjustmentSeconds, -600)
        XCTAssertEqual(r.manualExtraSeconds, 3600)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.grossExtraSeconds, 0)
        XCTAssertFalse(r.flags.contains(.noShow))
    }

    func testFutureDayIgnoresBookedFactsUntilItArrives() {
        // Not in the spec: a day after today carries only its schedule. Booked PTO / flex / adjustments
        // move nothing yet (see spec question).
        let future = "2026-10-19"
        let r = ledger({
            $0.timeOff = [timeOff(future, TimeOffType.flexID, seconds: W)]
            $0.adjustments = [Adjustment(day: day(future), seconds: 3600)]
            $0.manual = [manualBlock(future, "18:00", "19:00")]
        }, day: future)
        XCTAssertEqual(r.flags, [.future])
        XCTAssertEqual(r.kind, .workday)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.timeOffSeconds, 0)
        XCTAssertEqual(r.flexSpentSeconds, 0)
        XCTAssertEqual(r.adjustmentSeconds, 0)
        XCTAssertEqual(r.manualExtraSeconds, 0)
        var s = Fixture.store()
        s.timeOff = [timeOff(future, TimeOffType.flexID, seconds: W)]
        XCTAssertEqual(Ledger.balance(store: s, asOf: day(future), now: defaultNow), 0)
    }

    func testManualExtraOnWindowAndNoWindowDays() {
        let window = ledger {
            $0.presence = [presence(d, "07:00", "15:30")]
            $0.manual = [manualBlock(d, "05:00", "06:00"), manualBlock(d, "12:00", "12:30")] // extra never fills the window
        }
        XCTAssertEqual(window.manualExtraSeconds, 5400)
        XCTAssertEqual(window.presenceSeconds, W)
        XCTAssertEqual(window.deltaSeconds, 5400)
        XCTAssertEqual(window.grossExtraSeconds, 5400)
        let weekend = ledger({ $0.manual = [manualBlock("2026-10-10", "05:00", "06:00")] }, day: "2026-10-10")
        XCTAssertEqual(weekend.deltaSeconds, 3600)
        XCTAssertEqual(weekend.grossExtraSeconds, 3600)
        XCTAssertEqual(weekend.presenceSeconds, 0)
    }

    func testAdjustmentsOnNoWindowDay() {
        let r = ledger({ $0.adjustments = [Adjustment(day: day("2026-10-10"), seconds: 1800), Adjustment(day: day("2026-10-10"), seconds: -2400)] }, day: "2026-10-10")
        XCTAssertEqual(r.adjustmentSeconds, -600)
        XCTAssertEqual(r.deltaSeconds, -600)
        XCTAssertEqual(r.grossExtraSeconds, 0)
        let positive = ledger({ $0.adjustments = [Adjustment(day: day("2026-10-10"), seconds: 900)] }, day: "2026-10-10")
        XCTAssertEqual(positive.deltaSeconds, 900)
        XCTAssertEqual(positive.grossExtraSeconds, 900)
    }
}

// MARK: - 4.7 Overlaps and determinism

final class DeterminismTests: XCTestCase {
    func testIdenticalArrivalInstantAtTwoLocationsIsOrderIndependent() {
        let a = presence(d, "07:00", "15:30", at: Fixture.plantA)
        let b = presence(d, "07:00", "08:00", at: Fixture.plantB)
        for order in [[a, b], [b, a]] {
            let r = ledger { $0.presence = order }
            XCTAssertEqual(r.presenceSeconds, W, "\(order.map { $0.locationID })")
            XCTAssertEqual(r.deltaSeconds, 0)
            XCTAssertTrue(r.flags.contains(.overlappingLocations))
            XCTAssertFalse(r.flags.contains(.gapUndecided))
        }
        // One second later elsewhere merges just the same (SPEC 4.7): nothing is cut, the day is flagged.
        let later = presence(from: at(d, "07:00", 1), to: t(d, "08:00"), at: Fixture.plantB)
        for order in [[a, later], [later, a]] {
            let r = ledger { $0.presence = order }
            XCTAssertEqual(r.presenceSeconds, W)
            XCTAssertEqual(r.earlyExitSeconds, 0)
            XCTAssertEqual(r.deltaSeconds, 0)
            XCTAssertEqual(r.flags, [.overlappingLocations])
        }
    }

    func testStoreArrayOrderDoesNotChangeAnyResult() {
        var s = Fixture.store()
        s.presence = [
            presence("2026-10-12", "06:50", "12:00", at: Fixture.plantA, gapIsWork: true),
            presence("2026-10-12", "12:40", "15:28", at: Fixture.plantA, gapIsWork: nil),
            presence("2026-10-13", "07:00", "10:00", at: Fixture.plantA, gapIsWork: true),
            presence("2026-10-13", "09:30", "11:00", at: Fixture.plantB),
            presence("2026-10-13", "11:00", "11:30", at: Fixture.plantB, gapIsWork: false),
            presence("2026-10-13", "13:00", "16:00", at: Fixture.plantA),
            presence(from: t("2026-10-14", "22:00"), to: t("2026-10-15", "01:00")),
            presence("2026-10-15", "07:04", "15:26"),
            presence("2026-10-16", "07:00", nil),
        ]
        s.manual = [
            manualBlock("2026-10-12", "18:00", "19:00"),
            manualBlock("2026-10-13", "11:30", "12:00", countsAs: .regular),
            manualBlock("2026-10-14", "08:00", "12:00", countsAs: .regular),
            manualBlock("2026-10-14", "18:30", "19:30", countsAs: .extra),
        ]
        s.timeOff = [
            timeOff("2026-10-14", TimeOffType.ptoID, seconds: 3600),
            timeOff("2026-10-14", TimeOffType.flexID, seconds: 1800),
            timeOff("2026-10-15", TimeOffType.personalID, seconds: 600),
        ]
        s.adjustments = [Adjustment(day: day("2026-10-12"), seconds: 300), Adjustment(day: day("2026-10-12"), seconds: -120)]
        s.holidays = [Holiday(day: day("2026-10-10"), name: "H")]
        s.setOverride(DayOverride(day: day("2026-10-15"), countEarlyArrival: true))
        let from = day("2026-10-10"), through = day("2026-10-16")
        let reference = Ledger.dayResults(store: s, from: from, through: through, now: defaultNow)
        let referenceGaps = DayKey.days(from: from, through: through, calendar: Fixture.calendar).map { Ledger.gaps(store: s, day: $0, now: defaultNow) }
        XCTAssertTrue(reference.contains { $0.gapsWorkSeconds > 0 })
        XCTAssertTrue(reference.contains { $0.flags.contains(.overlappingLocations) })
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<25 {
            var copy = s
            copy.presence.shuffle(using: &rng)
            copy.manual.shuffle(using: &rng)
            copy.timeOff.shuffle(using: &rng)
            copy.adjustments.shuffle(using: &rng)
            XCTAssertEqual(Ledger.dayResults(store: copy, from: from, through: through, now: defaultNow), reference)
            XCTAssertEqual(DayKey.days(from: from, through: through, calendar: Fixture.calendar).map { Ledger.gaps(store: copy, day: $0, now: defaultNow) }, referenceGaps)
            XCTAssertEqual(Ledger.summary(store: copy, now: defaultNow), Ledger.summary(store: s, now: defaultNow))
        }
    }

    func testEmptyStoreWithoutScheduleIsAllZero() {
        var s = Fixture.store()
        s.schedules = []
        let results = Ledger.dayResults(store: s, from: day("2026-10-10"), through: day("2026-10-16"), now: defaultNow)
        XCTAssertEqual(results.count, 7)
        for r in results {
            XCTAssertEqual(r.kind, .weekend)
            XCTAssertEqual(r.deltaSeconds, 0)
            XCTAssertEqual(r.flags, r.day == day("2026-10-16") ? [.inProgress] : [])
            XCTAssertEqual(Ledger.gaps(store: s, day: r.day, now: defaultNow), [])
        }
        s.settings.bankStartingSeconds = -1200
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertEqual(sum, LedgerSummary(balanceSeconds: -1200))
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day(d)).map { $0.remainingSeconds }, [0, 0])
    }
}

// MARK: - 4.7 Overlapping sessions at different locations

final class OverlappingLocationTests: XCTestCase {
    func testNestedSessionAtASecondSiteIsPlainPresence() {
        // A 07:00–15:30 with B 08:00–09:00 inside it: presence is the whole window, no gap, flag set.
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "15:30", at: Fixture.plantA), presence(d, "08:00", "09:00", at: Fixture.plantB)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W)
        XCTAssertEqual(r.presenceInsideSeconds, W)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(r.flags, [.overlappingLocations])
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
    }

    func testOverlappingTailAtASecondSiteIsPlainPresence() {
        // A 07:00–12:00 then B 11:30–15:30: one block from 07:00 to 15:30.
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "12:00", at: Fixture.plantA), presence(d, "11:30", "15:30", at: Fixture.plantB)]
        for order in [s.presence, Array(s.presence.reversed())] {
            s.presence = order
            let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
            XCTAssertEqual(r.firstIn, t(d, "07:00"))
            XCTAssertEqual(r.lastOut, t(d, "15:30"))
            XCTAssertEqual(r.presenceSeconds, W)
            XCTAssertEqual(r.deltaSeconds, 0)
            XCTAssertEqual(r.flags, [.overlappingLocations])
        }
    }

    func testGapDefaultReadsTheLocationOfTheSessionThatEndsTheBlock() {
        // Block 1 starts at A and ends at B (B exits last); the next block starts at A: a different
        // location, so the undecided gap defaults to work, and B carries the decision.
        let a = presence(d, "07:00", "10:00", at: Fixture.plantA)
        let b = presence(d, "09:00", "11:00", at: Fixture.plantB)
        let back = presence(d, "12:00", "15:30", at: Fixture.plantA)
        var s = Fixture.store()
        s.presence = [back, b, a]
        let work = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(work.presenceSeconds, W - 3600)
        XCTAssertEqual(work.gapsWorkSeconds, 3600)
        XCTAssertEqual(work.gapsDeductedSeconds, 0)
        XCTAssertEqual(work.deltaSeconds, 0)
        XCTAssertEqual(Set(work.flags), [.overlappingLocations, .gapUndecided])
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].sessionID, b.id)
        XCTAssertEqual(gaps[0].fromLocationID, Fixture.plantB)
        XCTAssertEqual(gaps[0].toLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[0].interval, Interval(start: t(d, "11:00"), end: t(d, "12:00")))
        XCTAssertEqual(gaps[0].countsAsWork, true)
        // The ending session's stored decision wins over the default.
        s.presence[1].followingGapIsWork = false
        let decided = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(decided.gapsDeductedSeconds, 3600)
        XCTAssertEqual(decided.deltaSeconds, -3600)
        XCTAssertFalse(decided.flags.contains(.gapUndecided))
        // A's own decision is about a gap that does not exist (A is absorbed) and is never read.
        s.presence[1].followingGapIsWork = nil
        s.presence[2].followingGapIsWork = false
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).gapsWorkSeconds, 3600)
    }

    func testGapDefaultIsPersonalWhenTheBlockEndsWhereTheNextStarts() {
        // A 07:00–11:00 with B 08:00–09:00 nested: the block ends at A; the next block starts at A: personal.
        let a = presence(d, "07:00", "11:00", at: Fixture.plantA)
        let b = presence(d, "08:00", "09:00", at: Fixture.plantB)
        var s = Fixture.store()
        s.presence = [b, a, presence(d, "12:00", "15:30", at: Fixture.plantA)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.gapsDeductedSeconds, 3600)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, -3600)
        XCTAssertEqual(Set(r.flags), [.overlappingLocations, .gapUndecided])
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.map { $0.sessionID }, [a.id])
        XCTAssertEqual(gaps[0].fromLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[0].toLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[0].countsAsWork, false)
        // The next block's start location is the session that started it, even when another site joins later.
        s.presence.append(presence(d, "12:30", "15:30", at: Fixture.plantB))
        let joined = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].toLocationID, Fixture.plantA)
        XCTAssertEqual(joined[0].countsAsWork, false)
    }

    func testEndTiesResolveByEnteredAtThenByUUIDAndStayOrderIndependent() {
        // Both sessions exit at 11:00; B entered later, so B ends the block: the gap runs B→A and defaults to work.
        var a = presence(d, "07:00", "11:00", at: Fixture.plantA)
        var b = presence(d, "08:00", "11:00", at: Fixture.plantB)
        let back = presence(d, "12:00", "15:30", at: Fixture.plantA)
        a.id = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")! // the larger UUID does not matter when enteredAt differs
        b.id = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        for order in [[a, b, back], [b, a, back], [back, a, b]] {
            var s = Fixture.store()
            s.presence = order
            let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
            XCTAssertEqual(gaps.map { $0.sessionID }, [b.id])
            XCTAssertEqual(gaps[0].fromLocationID, Fixture.plantB)
            XCTAssertEqual(gaps[0].countsAsWork, true)
            XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).gapsWorkSeconds, 3600)
        }
        // Same enteredAt and same exit: the lexically larger UUID string ends the block.
        b.enteredAt = a.enteredAt
        for order in [[a, b, back], [b, a, back]] {
            var s = Fixture.store()
            s.presence = order
            let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
            XCTAssertEqual(gaps.map { $0.sessionID }, [a.id])
            XCTAssertEqual(gaps[0].fromLocationID, Fixture.plantA)
            XCTAssertEqual(gaps[0].countsAsWork, false)
            XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).gapsDeductedSeconds, 3600)
        }
    }

    func testOverlapFlagNeedsTwoLocationsAndStrictOverlap() {
        var s = Fixture.store()
        // Touching at 12:00 is not an overlap.
        s.presence = [presence(d, "07:00", "12:00", at: Fixture.plantA), presence(d, "12:00", "15:30", at: Fixture.plantB)]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).flags, [])
        // Same site overlapping is not the flag either.
        s.presence = [presence(d, "07:00", "12:00"), presence(d, "11:00", "15:30")]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).flags, [])
        // A third site overlapping only the first flags the day even though the latest end is elsewhere.
        let siteC = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        s.presence = [presence(d, "07:00", "15:30", at: Fixture.plantA), presence(d, "07:00", "08:00", at: Fixture.plantA),
                      presence(d, "07:30", "07:45", at: siteC)]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).flags, [.overlappingLocations])
        // Pieces at the latest-ending site never overlap another site: no flag.
        s.presence = [presence(d, "07:00", "10:00", at: Fixture.plantA), presence(d, "10:00", "15:30", at: Fixture.plantB),
                      presence(d, "11:00", "12:00", at: Fixture.plantB)]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).flags, [])
        // A regular manual segment has no location and never triggers the flag.
        s.presence = [presence(d, "07:00", "15:30")]
        s.manual = [manualBlock(d, "09:00", "10:00", countsAs: .regular)]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).flags, [])
    }
}

// MARK: - 4.3 In-progress day

final class InProgressDayTests: XCTestCase {
    /// Friday 2026-10-16, the fixture's `today` for a `now` on that day.
    let friday = "2026-10-16"

    func at(_ hhmm: String, _ seconds: Int = 0) -> Date { t(friday, hhmm).addingTimeInterval(TimeInterval(seconds)) }

    func today(now: Date, _ configure: (inout Store) -> Void = { _ in }) -> DayResult {
        ledger(configure, day: friday, now: now)
    }

    func testNothingRecordedBeforeTheWindowStartsIsNoDeficitYet() {
        let r = today(now: at("06:00"))
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.lateArrivalSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.flags, [.inProgress])
        XCTAssertEqual(Ledger.gaps(store: Fixture.store(), day: day(friday), now: at("06:00")), [])
        // At S itself nothing has elapsed; one second later one second is missing.
        XCTAssertEqual(today(now: at("07:00")).deltaSeconds, 0)
        let second = today(now: at("07:00", 1))
        XCTAssertEqual(second.deltaSeconds, -1)
        XCTAssertEqual(second.gapsDeductedSeconds, 1)
        XCTAssertFalse(second.flags.contains(.noShow))
    }

    func testPresentSinceTheStartIsZeroMidMorning() {
        let r = today(now: at("10:00")) { $0.presence = [presence(self.friday, "07:00", nil)] }
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.presenceInsideSeconds, 3 * 3600)
        XCTAssertEqual(Set(r.flags), [.inProgress, .openPresence])
    }

    func testLateArrivalIsDeductedAsSoonAsItHappened() {
        let r = today(now: at("10:00")) { $0.presence = [presence(self.friday, "07:10", nil)] }
        XCTAssertEqual(r.deltaSeconds, -600)
        XCTAssertEqual(r.lateArrivalSeconds, 600)
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 600)
        // Within grace it is forgiven, as on any day.
        let graced = today(now: at("10:00")) { $0.presence = [presence(self.friday, "07:04", nil)] }
        XCTAssertEqual(graced.deltaSeconds, 0)
        XCTAssertTrue(graced.flags.contains(.graceApplied))
        // Not there yet at 07:03: three minutes missing so far.
        XCTAssertEqual(today(now: at("07:03")).deltaSeconds, -180)
    }

    func testEarlyExitIsProvisionalAndGrowsUntilTheWindowEnds() {
        func left(at exit: String, now: String, _ seconds: Int = 0) -> DayResult {
            today(now: at(now, seconds)) { $0.presence = [presence(self.friday, "07:00", exit)] }
        }
        let halfHour = left(at: "14:00", now: "14:30")
        XCTAssertEqual(halfHour.deltaSeconds, -1800)
        XCTAssertEqual(halfHour.earlyExitSeconds, 1800)
        XCTAssertEqual(halfHour.gapsDeductedSeconds, 1800)
        XCTAssertEqual(left(at: "14:00", now: "15:00").earlyExitSeconds, 3600)
        let atEnd = left(at: "14:00", now: "15:30")
        XCTAssertEqual(atEnd.deltaSeconds, -5400)
        XCTAssertEqual(atEnd.earlyExitSeconds, 5400)
        let afterEnd = left(at: "14:00", now: "15:30", 1)
        XCTAssertEqual(afterEnd.deltaSeconds, -5400)
        XCTAssertEqual(afterEnd.earlyExitSeconds, 5400)
        XCTAssertFalse(afterEnd.flags.contains(.noShow))
        // Grace is judged against the scheduled end, not against now: leaving at 15:26 is forgiven at 15:28 and later.
        let graced = left(at: "15:26", now: "15:28")
        XCTAssertEqual(graced.deltaSeconds, 0)
        XCTAssertEqual(graced.earlyExitSeconds, 0)
        XCTAssertTrue(graced.flags.contains(.graceApplied))
        XCTAssertEqual(left(at: "15:26", now: "16:00").deltaSeconds, 0)
        // Leaving at 15:24 is one minute of deficit at 15:25 and six at the end.
        XCTAssertEqual(left(at: "15:24", now: "15:25").deltaSeconds, -60)
        XCTAssertEqual(left(at: "15:24", now: "15:30").deltaSeconds, -360)
    }

    func testMidDayGapIsClippedToNow() {
        // Left at 12:00; at 12:30 that is a provisional early exit of 30 minutes.
        let out = today(now: at("12:30")) { $0.presence = [presence(self.friday, "07:00", "12:00")] }
        XCTAssertEqual(out.earlyExitSeconds, 1800)
        XCTAssertEqual(out.deltaSeconds, -1800)
        // With a hand-entered afternoon session it becomes a mid-day gap, deducted only up to now.
        var s = Fixture.store()
        let morning = presence(friday, "07:00", "12:00")
        s.presence = [morning, presence(friday, "14:00", "15:30")]
        let r = Ledger.dayResult(store: s, day: day(friday), now: at("12:30"))
        XCTAssertEqual(r.earlyExitSeconds, 0)
        XCTAssertEqual(r.gapsDeductedSeconds, 1800)
        XCTAssertEqual(r.deltaSeconds, -1800)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        let gaps = Ledger.gaps(store: s, day: day(friday), now: at("12:30"))
        XCTAssertEqual(gaps.map { $0.sessionID }, [morning.id])
        XCTAssertEqual(gaps[0].secondsInsideWindow, 1800)
        XCTAssertEqual(gaps[0].interval, Interval(start: t(friday, "12:00"), end: t(friday, "14:00")))
        XCTAssertEqual(Ledger.gaps(store: s, day: day(friday), now: at("16:00"))[0].secondsInsideWindow, 7200)
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(friday), now: at("16:00")).deltaSeconds, -7200)
        // Before the gap has begun, nothing is deducted for it.
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(friday), now: at("11:00")).deltaSeconds, 0)
        XCTAssertEqual(Ledger.gaps(store: s, day: day(friday), now: at("11:00")), [])
    }

    func testFullDayPTOReliefNeverExceedsTheElapsedWindow() {
        func pto(now: Date) -> DayResult { today(now: now) { $0.timeOff = [timeOff(self.friday, TimeOffType.ptoID, seconds: W)] } }
        let dawn = pto(now: at("06:00"))
        XCTAssertEqual(dawn.deltaSeconds, 0)
        XCTAssertEqual(dawn.timeOffSeconds, 0)
        XCTAssertEqual(dawn.gapsDeductedSeconds, 0)
        let midday = pto(now: at("11:00"))
        XCTAssertEqual(midday.deltaSeconds, 0)
        XCTAssertEqual(midday.timeOffSeconds, 4 * 3600)
        XCTAssertEqual(midday.gapsDeductedSeconds, 4 * 3600)
        for now in [at("15:30"), at("15:30", 1), at("20:00")] {
            let r = pto(now: now)
            XCTAssertEqual(r.deltaSeconds, 0, "\(now)")
            XCTAssertEqual(r.timeOffSeconds, W, "\(now)")
            XCTAssertFalse(r.flags.contains(.noShow), "\(now)")
        }
        // Full-day PTO but came in for two hours: the worked time counts all day long.
        let worked = today(now: at("11:00")) {
            $0.timeOff = [timeOff(self.friday, TimeOffType.ptoID, seconds: W)]
            $0.presence = [presence(self.friday, "07:00", "09:00")]
        }
        XCTAssertEqual(worked.deltaSeconds, 7200)
        XCTAssertEqual(worked.timeOffSeconds, 4 * 3600)
        XCTAssertEqual(worked.earlyExitSeconds, 7200)
        XCTAssertEqual(today(now: at("20:00")) {
            $0.timeOff = [timeOff(self.friday, TimeOffType.ptoID, seconds: W)]
            $0.presence = [presence(self.friday, "07:00", "09:00")]
        }.deltaSeconds, 7200)
    }

    func testFlexDayIsSpentImmediatelyAndInFull() {
        for now in [at("06:00"), at("11:00"), at("15:30"), at("20:00")] {
            let r = today(now: now) { $0.timeOff = [timeOff(self.friday, TimeOffType.flexID, seconds: W)] }
            XCTAssertEqual(r.deltaSeconds, -W, "\(now)")
            XCTAssertEqual(r.flexSpentSeconds, W, "\(now)")
            XCTAssertEqual(r.timeOffSeconds, r.gapsDeductedSeconds, "relief equals what has elapsed (\(now))")
            XCTAssertFalse(r.flags.contains(.noShow), "\(now)")
        }
        XCTAssertEqual(today(now: at("06:00")) { $0.timeOff = [timeOff(self.friday, TimeOffType.flexID, seconds: W)] }.timeOffSeconds, 0)
    }

    func testOtherTermsAreUnchangedWhileTheDayIsInProgress() {
        let r = today(now: at("10:00")) {
            $0.presence = [presence(self.friday, "06:30", nil)]
            $0.manual = [manualBlock(self.friday, "05:00", "06:00")]
            $0.adjustments = [Adjustment(day: day(self.friday), seconds: -300)]
            $0.setOverride(DayOverride(day: day(self.friday), countEarlyArrival: true))
        }
        XCTAssertEqual(r.extraBeforeSeconds, 1800)
        XCTAssertTrue(r.extraBeforeCounted)
        XCTAssertEqual(r.manualExtraSeconds, 3600)
        XCTAssertEqual(r.adjustmentSeconds, -300)
        XCTAssertEqual(r.gapsDeductedSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, 1800 + 3600 - 300)
        XCTAssertEqual(r.grossExtraSeconds, 1800 + 3600)
        // A hand-entered session that already runs past E credits its tail now, as before.
        let future = today(now: at("10:00")) { $0.presence = [presence(self.friday, "07:00", "17:00")] }
        XCTAssertEqual(future.extraAfterSeconds, 5400)
        XCTAssertEqual(future.deltaSeconds, 5400)
        XCTAssertEqual(future.gapsDeductedSeconds, 0)
    }

    func testDeltaIdentityHoldsAtEveryInstantOfTheDay() {
        var s = Fixture.store()
        s.presence = [presence(friday, "07:08", "11:00"), presence(friday, "11:40", "13:00", at: Fixture.plantB), presence(friday, "14:00", nil)]
        s.manual = [manualBlock(friday, "05:30", "06:00"), manualBlock(friday, "13:10", "13:20", countsAs: .regular)]
        s.timeOff = [timeOff(friday, TimeOffType.ptoID, seconds: 3600), timeOff(friday, TimeOffType.flexID, seconds: 1800)]
        s.adjustments = [Adjustment(day: day(friday), seconds: 240)]
        var previousDelta: Int? = nil
        for minute in stride(from: 5 * 60, through: 18 * 60, by: 7) {
            let now = t(friday, "00:00").addingTimeInterval(TimeInterval(minute * 60 + 13))
            let r = Ledger.dayResult(store: s, day: day(friday), now: now)
            let earlyCounted = r.extraBeforeCounted ? r.extraBeforeSeconds : 0
            XCTAssertEqual(r.deltaSeconds, r.extraAfterSeconds + earlyCounted - r.gapsDeductedSeconds + r.timeOffSeconds
                           - r.flexSpentSeconds + r.manualExtraSeconds + r.adjustmentSeconds, "\(now)")
            XCTAssertLessThanOrEqual(r.timeOffSeconds, max(0, min(W, minute * 60 + 13 - 7 * 3600)), "\(now)")
            XCTAssertEqual(r.gapsDeducted(coveredBy: s, now: now), r.gapsDeductedSeconds, "\(now)")
            XCTAssertTrue(r.flags.contains(.inProgress), "\(now)")
            XCTAssertEqual(Ledger.gaps(store: s, day: day(friday), now: now).filter { !$0.countsAsWork }.reduce(0) { $0 + $1.secondsInsideWindow },
                           r.gapsDeductedSeconds - r.lateArrivalSeconds - r.earlyExitSeconds, "\(now)")
            // Back for good at 14:00: from then on every deficit term is final and the delta never falls.
            if now >= t(friday, "14:00") {
                if let p = previousDelta { XCTAssertGreaterThanOrEqual(r.deltaSeconds, p, "\(now)") }
                previousDelta = r.deltaSeconds
            }
        }
    }

    func testCompletedDaysDoNotDependOnNow() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:10", "12:00"), presence(d, "13:00", "15:20")]
        s.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: 3600)]
        let reference = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        for now in [t(d, "15:30"), t(d, "23:59"), t("2026-10-15", "06:00"), Date.distantFuture] {
            // Seen from the day itself (E already passed) only the `.inProgress` flag differs; every component agrees.
            var r = Ledger.dayResult(store: s, day: day(d), now: now)
            XCTAssertEqual(r.flags.contains(.inProgress), DayKey(now, calendar: Fixture.calendar) == day(d), "\(now)")
            r.flags.removeAll { $0 == .inProgress }
            XCTAssertEqual(r, reference, "\(now)")
        }
        XCTAssertEqual(reference.deltaSeconds, -600 - 3600 - 600 + 3600)
    }

    func testSummaryTodayDeltaFollowsTheClock() {
        var s = Fixture.store()
        s.presence = [presence(friday, "07:00", nil)]
        XCTAssertEqual(Ledger.summary(store: s, now: at("12:00")).todayDeltaSeconds, 0)
        XCTAssertEqual(Ledger.summary(store: s, now: at("12:00")).balanceSeconds, 0)
        XCTAssertEqual(Ledger.summary(store: s, now: at("16:00")).todayDeltaSeconds, 1800)
        s.presence = [presence(friday, "07:00", "12:00")]
        XCTAssertEqual(Ledger.summary(store: s, now: at("12:00")).todayDeltaSeconds, 0)
        XCTAssertEqual(Ledger.summary(store: s, now: at("13:00")).todayDeltaSeconds, -3600)
        XCTAssertEqual(Ledger.summary(store: s, now: at("20:00")).todayDeltaSeconds, -12600)
    }
}

private extension DayResult {
    /// What SPEC 4.3 says the deficit must be on an in-progress day: `(Ecut − S) − inside(S, Ecut)` minus the
    /// grace that forgave a boundary and the mid-day gaps that count as work.
    func gapsDeducted(coveredBy store: Store, now: Date) -> Int {
        guard let w = scheduledWindow else { return 0 }
        let cutoff = min(w.end, now)
        guard cutoff > w.start else { return 0 }
        let elapsedWindow = Interval(start: w.start, end: cutoff)
        var intervals = store.presence.map { $0.interval(now: now) }
        for m in store.manual where m.countsAs == .regular {
            for seg in m.segments { intervals.append(seg.interval(now: now)) }
        }
        let insideSoFar = Interval.seconds(of: intervals, inside: elapsedWindow)
        let g = store.settings.graceSeconds
        var forgiven = 0
        if let firstIn, firstIn > w.start, Int(firstIn.timeIntervalSince(w.start).rounded()) <= g {
            forgiven += Int(firstIn.timeIntervalSince(w.start).rounded())
        }
        if let lastOut, lastOut < w.end, Int(w.end.timeIntervalSince(lastOut).rounded()) <= g {
            forgiven += max(0, Int(cutoff.timeIntervalSince(lastOut).rounded()))
        }
        return elapsedWindow.seconds - insideSoFar - forgiven - gapsWorkSeconds
    }
}

// MARK: - 4.6 Summaries

final class SummaryBoundaryTests: XCTestCase {
    /// Sat 10-10 +3h; Mon 10-12 +1h; Tue 10-13 +42m; Wed exact; Thu −10m; Fri exact. Bank +1h as of 10-01.
    func weekStore() -> Store {
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

    func testWeekDeltaOnASundayDependsOnWeekStart() {
        var s = weekStore()
        let sunday = t("2026-10-11", "20:00")
        XCTAssertEqual(Ledger.summary(store: s, now: sunday).weekDeltaSeconds, 0) // Sunday-start week is just today
        XCTAssertEqual(Ledger.summary(store: s, now: sunday).balanceSeconds, 3600 + 10800)
        s.settings.weekStartsOn = .monday
        XCTAssertEqual(Ledger.summary(store: s, now: sunday).weekDeltaSeconds, 10800) // Mon 10-05 … Sun 10-11 includes Saturday
        XCTAssertEqual(Ledger.summary(store: s, now: sunday).balanceSeconds, 3600 + 10800)

        let nextSunday = t("2026-10-18", "20:00")
        s.settings.weekStartsOn = .sunday
        XCTAssertEqual(Ledger.summary(store: s, now: nextSunday).weekDeltaSeconds, 0)
        s.settings.weekStartsOn = .monday
        XCTAssertEqual(Ledger.summary(store: s, now: nextSunday).weekDeltaSeconds, 3600 + 2520 - 600)
        XCTAssertEqual(Ledger.summary(store: s, now: nextSunday).monthGrossExtraSeconds, 10800 + 3600 + 2520)
    }

    func testWeekStartForEveryWeekday() {
        let cal = Fixture.calendar
        for start in Weekday.allCases {
            for offset in 0..<14 {
                let dk = day("2026-10-04").adding(days: offset, calendar: cal)
                let ws = Ledger.weekStart(containing: dk, weekStartsOn: start, calendar: cal)
                XCTAssertEqual(ws.weekday(in: cal), start)
                XCTAssertLessThanOrEqual(ws, dk)
                XCTAssertLessThan(ws.daysUntil(dk, calendar: cal), 7)
            }
        }
    }

    func testBalanceHonoursStartingSecondsAndInclusiveAsOf() {
        var s = weekStore()
        s.settings.bankStartingSeconds = -7200
        s.settings.bankStartingAsOf = day("2026-10-12")
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-11"), now: defaultNow), -7200)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-12"), now: defaultNow), -7200 + 3600)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), -7200 + 3600 + 2520 - 600)
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow).balanceSeconds, -7200 + 3600 + 2520 - 600)
        // Balance mid-day today only includes what has happened; an open session counts to `now`.
        s.presence[5] = presence("2026-10-16", "07:00", nil)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: t("2026-10-16", "15:30")), -7200 + 3600 + 2520 - 600)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: t("2026-10-16", "16:30")), -7200 + 3600 + 2520 - 600 + 3600)
    }

    func testYearToDateAndMonthFollowTheCalendar() {
        var s = Fixture.store(scheduleFrom: "2025-01-01")
        s.settings.bankStartingAsOf = day("2025-12-29")
        s.presence = [
            presence("2025-12-29", "07:00", "16:00"), // Mon +30m last year
            presence("2025-12-30", "07:00", "15:30"),
            presence("2025-12-31", "07:00", "15:30"),
            presence("2026-01-01", "07:00", "15:30"),
            presence("2026-01-02", "07:00", "16:00"), // Fri +30m this year
        ]
        let now = t("2026-01-02", "20:00")
        let sum = Ledger.summary(store: s, now: now)
        XCTAssertEqual(sum.balanceSeconds, 3600)
        XCTAssertEqual(sum.ytdDeltaSeconds, 1800)
        XCTAssertEqual(sum.monthDeltaSeconds, 1800)
        XCTAssertEqual(sum.monthGrossExtraSeconds, 1800)
        XCTAssertEqual(sum.weekDeltaSeconds, 3600) // Sunday 12-28 … Friday 01-02 spans the year end
        XCTAssertEqual(sum.todayDeltaSeconds, 1800)
    }
}

// MARK: - 4.6 Leave balances

final class LeaveAccrualBoundaryTests: XCTestCase {
    let cal = Fixture.calendar

    func testBoundariesBeforeAsOfAreExcludedAndOnAsOfIncluded() {
        let rule = AccrualRule(seconds: 60, period: .monthly, anchor: day("2026-01-31"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-03-01"), through: day("2026-04-30"), calendar: cal), 120) // Mar 31, Apr 30
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-03-31"), through: day("2026-03-31"), calendar: cal), 60)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-04-01"), through: day("2026-04-29"), calendar: cal), 0)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2026-05-01"), through: day("2026-04-30"), calendar: cal), 0) // from after through
    }

    func testMonthlyAnchoredOnThe31stAndThe30th() {
        let on31 = AccrualRule(seconds: 1, period: .monthly, anchor: day("2026-01-31"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: on31, from: day("2026-01-01"), through: day("2026-12-30"), calendar: cal), 11)
        XCTAssertEqual(Ledger.accruedSeconds(rule: on31, from: day("2026-01-01"), through: day("2026-12-31"), calendar: cal), 12)
        XCTAssertEqual(Ledger.accruedSeconds(rule: on31, from: day("2026-01-01"), through: day("2027-01-31"), calendar: cal), 13)
        let on30 = AccrualRule(seconds: 1, period: .monthly, anchor: day("2026-01-30"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: on30, from: day("2026-01-01"), through: day("2026-03-29"), calendar: cal), 2) // Jan 30, Feb 28
        XCTAssertEqual(Ledger.accruedSeconds(rule: on30, from: day("2026-01-01"), through: day("2026-03-30"), calendar: cal), 3)
        let leapFeb = AccrualRule(seconds: 1, period: .monthly, anchor: day("2024-01-31"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: leapFeb, from: day("2024-01-01"), through: day("2024-02-28"), calendar: cal), 1)
        XCTAssertEqual(Ledger.accruedSeconds(rule: leapFeb, from: day("2024-01-01"), through: day("2024-02-29"), calendar: cal), 2)
    }

    func testYearlyAnchoredOnLeapDay() {
        let rule = AccrualRule(seconds: 1, period: .yearly, anchor: day("2024-02-29"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2024-02-28"), calendar: cal), 0)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2024-02-29"), calendar: cal), 1)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2025-02-27"), calendar: cal), 1)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2025-02-28"), calendar: cal), 2)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2028-02-28"), calendar: cal), 4)
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2024-01-01"), through: day("2028-02-29"), calendar: cal), 5)
    }

    func testWeeklyAndBiweeklyBoundariesIncludingDST() {
        let biweekly = AccrualRule(seconds: 1, period: .biweekly, anchor: day("2026-01-02"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: biweekly, from: day("2026-01-01"), through: day("2026-02-12"), calendar: cal), 3) // 01-02, 01-16, 01-30
        XCTAssertEqual(Ledger.accruedSeconds(rule: biweekly, from: day("2026-01-01"), through: day("2026-02-13"), calendar: cal), 4)
        let spring = AccrualRule(seconds: 1, period: .weekly, anchor: day("2026-03-02"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: spring, from: day("2026-03-02"), through: day("2026-03-15"), calendar: cal), 2)
        XCTAssertEqual(Ledger.accruedSeconds(rule: spring, from: day("2026-03-02"), through: day("2026-03-16"), calendar: cal), 3)
        let fall = AccrualRule(seconds: 1, period: .weekly, anchor: day("2026-10-26"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: fall, from: day("2026-10-26"), through: day("2026-11-01"), calendar: cal), 1)
        XCTAssertEqual(Ledger.accruedSeconds(rule: fall, from: day("2026-10-26"), through: day("2026-11-02"), calendar: cal), 2)
    }

    func testHugeAccrualDoesNotTrap() {
        let rule = AccrualRule(seconds: Int.max / 2, period: .weekly, anchor: day("2020-01-01"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: rule, from: day("2020-01-01"), through: day("2026-10-16"), calendar: cal), Int.max)
        let negative = AccrualRule(seconds: Int.min / 2, period: .weekly, anchor: day("2020-01-01"))
        XCTAssertEqual(Ledger.accruedSeconds(rule: negative, from: day("2020-01-01"), through: day("2026-10-16"), calendar: cal), Int.min)
    }

    func testConfigAsOfBoundsUsageAndAccrual() {
        var s = Fixture.store()
        s.upsert(LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 36000, asOf: day("2026-10-14"),
                                    accrual: AccrualRule(seconds: 3600, period: .weekly, anchor: day("2026-10-07"))))
        s.timeOff = [
            timeOff("2026-10-13", TimeOffType.ptoID, seconds: 100), // day before asOf: already in the starting balance
            timeOff("2026-10-14", TimeOffType.ptoID, seconds: 200), // on asOf: counts
            timeOff("2026-10-16", TimeOffType.ptoID, seconds: 300), // on the query day: counts
            timeOff("2026-10-17", TimeOffType.ptoID, seconds: 400), // after: not yet
        ]
        let pto = Ledger.leaveBalances(store: s, asOf: day("2026-10-16")).first { $0.typeID == TimeOffType.ptoID }
        XCTAssertEqual(pto?.usedSeconds, 500)
        XCTAssertEqual(pto?.accruedSeconds, 3600) // 10-07 is before asOf, 10-14 counts, 10-21 is after the query day
        XCTAssertEqual(pto?.remainingSeconds, 36000 + 3600 - 500)
        // Config dated after the day asked for: starting balance only.
        s.upsert(LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 36000, asOf: day("2026-12-01"),
                                    accrual: AccrualRule(seconds: 3600, period: .weekly, anchor: day("2026-10-07"))))
        let later = Ledger.leaveBalances(store: s, asOf: day("2026-10-16")).first { $0.typeID == TimeOffType.ptoID }
        XCTAssertEqual(later?.accruedSeconds, 0)
        XCTAssertEqual(later?.usedSeconds, 0)
        XCTAssertEqual(later?.remainingSeconds, 36000)
    }
}

// MARK: - Randomized identity over 300 days

final class SpecPropertyTests: XCTestCase {
    func testDeltaIdentityFlagsAndGapsOver300RandomDays() {
        check(seed: 0xC0FF_EE26, grace: 5)
        check(seed: 0xBEEF_2026, grace: 7)
    }

    private func check(seed: UInt64, grace: Int) {
        var rng = SeededGenerator(seed: seed)
        let cal = Fixture.calendar
        var s = Fixture.store(scheduleFrom: "2026-01-04")
        s.settings.graceMinutes = grace
        // A second version from June: Mon–Thu 08:00–16:30 with a 30-min break, Saturday 09:00–13:00, Friday off.
        var v2 = ScheduleVersion.standardWeek(effectiveFrom: day("2026-06-01"), start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 16, minute: 30), breakMinutes: 30)
        v2[.friday] = .off
        v2[.saturday] = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 13))
        s.schedules.append(v2)

        let first = day("2026-02-01")
        let count = 300
        let last = first.adding(days: count - 1, calendar: cal)
        XCTAssertEqual(last, day("2026-11-27")) // covers both DST changes
        let now = last.start(in: cal).addingTimeInterval(23.5 * 3600)
        let today = DayKey(now, calendar: cal)
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17), unpaidBreakMinutes: 30)

        for i in 0..<count {
            let dk = first.adding(days: i, calendar: cal)
            let start = dk.start(in: cal)
            func instant(_ secs: Int) -> Date { start.addingTimeInterval(TimeInterval(secs)) }
            var cursor = Int.random(in: 4 * 3600...9 * 3600, using: &rng)
            let n = Int.random(in: 0...3, using: &rng)
            for k in 0..<n {
                var end = cursor + Int.random(in: 60...5 * 3600, using: &rng)
                let crosses = k == n - 1 && Int.random(in: 0..<10, using: &rng) == 0
                if crosses { end = 24 * 3600 + Int.random(in: 1...3 * 3600, using: &rng) }
                let open = dk == today && k == n - 1 && Bool.random(using: &rng)
                let loc = Bool.random(using: &rng) ? Fixture.plantA : Fixture.plantB
                let decision: Bool? = [nil, true, false][Int.random(in: 0..<3, using: &rng)]
                s.presence.append(PresenceSession(locationID: loc, enteredAt: instant(cursor), exitedAt: open ? nil : instant(end), followingGapIsWork: decision))
                if !open && !crosses && Int.random(in: 0..<8, using: &rng) == 0 {
                    // A session at the other site overlapping this one (SPEC 4.7), sometimes at the very same instant.
                    let other = loc == Fixture.plantA ? Fixture.plantB : Fixture.plantA
                    let offset = Int.random(in: 0...2, using: &rng) == 0 ? 0 : Int.random(in: 1...600, using: &rng)
                    let overlapEnd = min(end + Int.random(in: -600...600, using: &rng), 24 * 3600 - 1)
                    s.presence.append(PresenceSession(locationID: other, enteredAt: instant(cursor + offset), exitedAt: instant(max(cursor + offset + 60, overlapEnd)),
                                                      followingGapIsWork: [nil, true, false][Int.random(in: 0..<3, using: &rng)]))
                    end = max(end, overlapEnd)
                }
                cursor = end + Int.random(in: 1...2 * 3600, using: &rng)
                if cursor >= 23 * 3600 || crosses { break }
            }
            if Int.random(in: 0..<3, using: &rng) == 0 {
                let ms = Int.random(in: 6 * 3600...22 * 3600, using: &rng)
                let me = ms + Int.random(in: 60...4 * 3600, using: &rng)
                s.manual.append(ManualSession.block(category: "Home work", countsAs: Bool.random(using: &rng) ? .extra : .regular,
                                                    start: instant(ms), end: instant(me), createdAt: Fixture.created))
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                let typeID = [TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID][Int.random(in: 0..<3, using: &rng)]
                s.timeOff.append(TimeOffEntry(day: dk, typeID: typeID, seconds: Int.random(in: 1...10 * 3600, using: &rng)))
            }
            if Int.random(in: 0..<5, using: &rng) == 0 {
                s.adjustments.append(Adjustment(day: dk, seconds: Int.random(in: -3600...3600, using: &rng)))
            }
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: s.setOverride(DayOverride(day: dk, kind: .dayOff))
            case 1: s.setOverride(DayOverride(day: dk, countEarlyArrival: true))
            case 2: s.setOverride(DayOverride(day: dk, excused: true))
            case 3: s.holidays.append(Holiday(day: dk, name: "H"))
            case 4: s.setOverride(DayOverride(day: dk, kind: .schedule(custom), countEarlyArrival: Bool.random(using: &rng)))
            case 5: s.setOverride(DayOverride(day: dk, kind: .schedule(custom), excused: true))
            default: break
            }
        }
        // Make sure both DST Sundays have a window and presence across the transition hour.
        for iso in ["2026-03-08", "2026-11-01"] {
            s.setOverride(DayOverride(day: day(iso), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 5)))))
            s.presence.append(presence(iso, "00:40", "03:20"))
            s.presence.append(presence(iso, "03:40", "05:10", at: Fixture.plantB))
        }

        let results = Ledger.dayResults(store: s, from: first, through: last, now: now)
        XCTAssertEqual(results.count, count)
        let g = s.settings.graceSeconds
        let trackingStart = Ledger.trackingStart(store: s, now: now)
        var running = s.settings.bankStartingSeconds
        var windowDays = 0
        var daysWithGaps = 0
        var noShows = 0
        var dayStart = first.start(in: cal)
        for (i, r) in results.enumerated() {
            let msg = "\(r.day) seed \(seed)"
            XCTAssertEqual(r.day, first.adding(days: i, calendar: cal), msg)
            let dayEnd = r.day.end(in: cal)
            defer { dayStart = dayEnd }
            XCTAssertFalse(r.flags.contains(.future), msg)
            XCTAssertEqual(r.flags.contains(.inProgress), r.day == today, msg)
            XCTAssertEqual(Ledger.dayResult(store: s, day: r.day, now: now), r, msg)
            let sched = Ledger.daySchedule(store: s, day: r.day)
            XCTAssertEqual(sched.kind, r.kind, msg)
            XCTAssertEqual(sched.window, r.scheduledWindow, msg)
            let gaps = Ledger.gaps(store: s, day: r.day, now: now)
            if let fi = r.firstIn, let lo = r.lastOut {
                XCTAssertLessThanOrEqual(fi, lo, msg)
                XCTAssertGreaterThanOrEqual(fi, dayStart, msg)
                XCTAssertLessThanOrEqual(lo, dayEnd, msg)
                XCTAssertGreaterThan(r.presenceSeconds, 0, msg)
                XCTAssertLessThanOrEqual(r.presenceSeconds, Int(lo.timeIntervalSince(fi).rounded()), msg)
            } else {
                XCTAssertNil(r.firstIn, msg)
                XCTAssertNil(r.lastOut, msg)
                XCTAssertEqual(r.presenceSeconds, 0, msg)
                XCTAssertEqual(r.manualRegularSeconds, 0, msg)
            }
            XCTAssertGreaterThanOrEqual(r.flexSpentSeconds, 0, msg)
            XCTAssertLessThanOrEqual(r.flexSpentSeconds, s.timeOff.filter { $0.day == r.day }.reduce(0) { $0 + $1.seconds }, msg)
            let earlyCounted = r.extraBeforeCounted ? r.extraBeforeSeconds : 0
            if let w = r.scheduledWindow {
                windowDays += 1
                let breakSeconds = (sched.weekdaySchedule?.unpaidBreakMinutes ?? 0) * 60
                XCTAssertEqual(r.expectedSeconds, max(0, w.seconds - breakSeconds), msg)
                let identity = r.extraAfterSeconds + earlyCounted - r.gapsDeductedSeconds + r.timeOffSeconds
                    - r.flexSpentSeconds + r.manualExtraSeconds + r.adjustmentSeconds
                let gross = r.extraAfterSeconds + earlyCounted + r.manualExtraSeconds + max(0, r.adjustmentSeconds)
                if r.kind == .excused {
                    XCTAssertEqual(r.deltaSeconds, 0, msg)
                    XCTAssertEqual(r.grossExtraSeconds, 0, msg)
                } else {
                    XCTAssertEqual(r.kind, .workday, msg)
                    XCTAssertEqual(r.deltaSeconds, identity, msg)
                    XCTAssertEqual(r.grossExtraSeconds, gross, msg)
                }
                XCTAssertLessThanOrEqual(r.timeOffSeconds, w.seconds, msg)
                let uncovered = w.seconds - r.presenceInsideSeconds
                XCTAssertGreaterThanOrEqual(uncovered, 0, msg)
                XCTAssertLessThanOrEqual(r.gapsDeductedSeconds + r.gapsWorkSeconds, uncovered, msg)
                XCTAssertGreaterThanOrEqual(r.gapsDeductedSeconds + r.gapsWorkSeconds, uncovered - 2 * g, msg)
                XCTAssertGreaterThanOrEqual(r.presenceSeconds, r.presenceInsideSeconds + r.extraAfterSeconds + r.extraBeforeSeconds, msg)
                XCTAssertGreaterThanOrEqual(r.lateArrivalSeconds, 0, msg)
                XCTAssertGreaterThanOrEqual(r.earlyExitSeconds, 0, msg)
                XCTAssertLessThanOrEqual(r.lateArrivalSeconds + r.earlyExitSeconds, w.seconds, msg)
                if r.firstIn == nil {
                    XCTAssertEqual(r.gapsDeductedSeconds, w.seconds, msg)
                    XCTAssertEqual(r.gapsWorkSeconds, 0, msg)
                    XCTAssertTrue(gaps.isEmpty, msg)
                    XCTAssertFalse(r.flags.contains(.graceApplied), msg)
                } else {
                    XCTAssertEqual(gaps.filter { !$0.countsAsWork }.reduce(0) { $0 + $1.secondsInsideWindow },
                                   r.gapsDeductedSeconds - r.lateArrivalSeconds - r.earlyExitSeconds, msg)
                }
                XCTAssertEqual(gaps.filter { $0.countsAsWork }.reduce(0) { $0 + $1.secondsInsideWindow }, r.gapsWorkSeconds, msg)
                XCTAssertEqual(r.flags.contains(.gapUndecided), gaps.contains { $0.isUndecided }, msg)
                if !gaps.isEmpty { daysWithGaps += 1 }
                for (k, gap) in gaps.enumerated() {
                    XCTAssertGreaterThan(gap.secondsInsideWindow, 0, msg)
                    XCTAssertLessThanOrEqual(gap.secondsInsideWindow, gap.interval.seconds, msg)
                    XCTAssertTrue(gap.interval.overlaps(w), msg)
                    if let decision = gap.decision { XCTAssertEqual(decision, gap.countsAsWork, msg) }
                    if gap.decision == nil {
                        let different = gap.fromLocationID != nil && gap.toLocationID != nil && gap.fromLocationID != gap.toLocationID
                        XCTAssertEqual(gap.countsAsWork, different, msg)
                    }
                    if k > 0 { XCTAssertGreaterThanOrEqual(gap.interval.start, gaps[k - 1].interval.end, msg) }
                    if let id = gap.sessionID {
                        XCTAssertEqual(s.presence.first { $0.id == id }?.followingGapIsWork, gap.decision, msg)
                    } else {
                        XCTAssertNil(gap.fromLocationID, msg)
                    }
                }
                let expectNoShow = w.end <= now && r.presenceInsideSeconds == 0 && r.manualRegularSeconds == 0
                    && r.timeOffSeconds < w.seconds && r.kind != .excused
                XCTAssertEqual(r.flags.contains(.noShow), expectNoShow, msg)
                if expectNoShow { noShows += 1 }
                XCTAssertEqual(r.flags.contains(.earlyArrivalUncounted), r.extraBeforeSeconds > 0 && !r.extraBeforeCounted, msg)
            } else {
                XCTAssertEqual(r.expectedSeconds, 0, msg)
                if r.kind == .excused {
                    XCTAssertEqual(r.deltaSeconds, 0, msg)
                    XCTAssertEqual(r.grossExtraSeconds, 0, msg)
                } else {
                    XCTAssertEqual(r.deltaSeconds, r.presenceSeconds + r.manualExtraSeconds + r.adjustmentSeconds - r.flexSpentSeconds, msg)
                    XCTAssertEqual(r.grossExtraSeconds, r.presenceSeconds + r.manualExtraSeconds + max(0, r.adjustmentSeconds), msg)
                }
                for zero in [r.presenceInsideSeconds, r.extraAfterSeconds, r.extraBeforeSeconds, r.gapsDeductedSeconds,
                             r.gapsWorkSeconds, r.lateArrivalSeconds, r.earlyExitSeconds] {
                    XCTAssertEqual(zero, 0, msg)
                }
                XCTAssertTrue(gaps.isEmpty, msg)
                for flag in [DayFlag.noShow, .graceApplied, .gapUndecided, .earlyArrivalUncounted] {
                    XCTAssertFalse(r.flags.contains(flag), msg)
                }
            }
            if r.day >= trackingStart { running += r.deltaSeconds }
        }
        XCTAssertGreaterThan(windowDays, 150, "seed \(seed)")
        XCTAssertGreaterThan(daysWithGaps, 30, "seed \(seed)")
        XCTAssertGreaterThan(noShows, 5, "seed \(seed)")
        XCTAssertTrue(results.contains { $0.flags.contains(.graceApplied) }, "seed \(seed)")
        XCTAssertTrue(results.contains { $0.flags.contains(.overlappingLocations) }, "seed \(seed)")
        XCTAssertEqual(Ledger.balance(store: s, asOf: last, now: now), running, "seed \(seed)")
        XCTAssertEqual(Ledger.summary(store: s, now: now).balanceSeconds, running, "seed \(seed)")

        // The same facts in a different array order give identical results.
        var shuffled = s
        shuffled.presence.shuffle(using: &rng)
        shuffled.manual.shuffle(using: &rng)
        shuffled.timeOff.shuffle(using: &rng)
        shuffled.adjustments.shuffle(using: &rng)
        shuffled.overrides.shuffle(using: &rng)
        shuffled.holidays.shuffle(using: &rng)
        shuffled.schedules.reverse()
        let reordered = Ledger.dayResults(store: shuffled, from: first, through: last, now: now)
        XCTAssertEqual(reordered.count, results.count)
        for (a, b) in zip(reordered, results) where a != b {
            XCTFail("order-dependent result on \(a.day) (seed \(seed)):\n  shuffled: \(a)\n  original: \(b)")
        }
    }
}
