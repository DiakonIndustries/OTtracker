import XCTest
import OTModels
@testable import OTLedger

// Time, boundaries and robustness: sessions crossing midnight and spanning several days, open
// sessions on past days, DST days (2026-03-08 is 23 h, 2026-11-01 is 25 h, both Sundays; Santiago
// shifts at midnight), windows at the day edges, zero-length and duplicated sessions, a session
// nested in another at a second site, facts in the far past and future, stores without schedules
// or locations, unknown locations, huge inputs, summaries on January 1 and on the first day of
// the week, accrual anchored after the config date, determinism, and absurd imported numbers.
// Reuses the fixture of LedgerTests.swift: America/New_York, Mon–Fri 07:00–15:30 effective
// 2026-01-04, grace 5 min, 2026-10-14 is a Wednesday, `defaultNow` is Friday 2026-10-16 20:00.

private let W = Fixture.window // 30600
private let H = 3600

private func range(_ s: Store, _ from: String, _ through: String, now: Date = defaultNow) -> [DayResult] {
    Ledger.dayResults(store: s, from: day(from), through: day(through), now: now)
}

// MARK: - Midnight and multi-day sessions (SPEC 4.2)

final class MidnightAndMultiDayTests: XCTestCase {
    func testSessionCrossingMidnightBetweenTwoWorkdaysMeetsEachWindowSeparately() {
        var s = Fixture.store()
        s.presence = [presence(from: t("2026-10-14", "14:00"), to: t("2026-10-15", "09:00"))]
        let r = range(s, "2026-10-14", "2026-10-15")
        let wed = r[0], thu = r[1]
        XCTAssertEqual(wed.firstIn, t("2026-10-14", "14:00"))
        XCTAssertEqual(wed.lastOut, t("2026-10-15", "00:00"))
        XCTAssertEqual(wed.presenceSeconds, 10 * H)
        XCTAssertEqual(wed.presenceInsideSeconds, 5400)
        XCTAssertEqual(wed.lateArrivalSeconds, 7 * H)
        XCTAssertEqual(wed.earlyExitSeconds, 0)
        XCTAssertEqual(wed.extraAfterSeconds, W)
        XCTAssertEqual(wed.gapsDeductedSeconds, 7 * H)
        XCTAssertEqual(wed.deltaSeconds, W - 7 * H)
        XCTAssertEqual(wed.flags, [])
        XCTAssertEqual(thu.firstIn, t("2026-10-15", "00:00"))
        XCTAssertEqual(thu.lastOut, t("2026-10-15", "09:00"))
        XCTAssertEqual(thu.presenceSeconds, 9 * H)
        XCTAssertEqual(thu.extraBeforeSeconds, 7 * H)
        XCTAssertFalse(thu.extraBeforeCounted)
        XCTAssertEqual(thu.presenceInsideSeconds, 2 * H)
        XCTAssertEqual(thu.lateArrivalSeconds, 0)
        XCTAssertEqual(thu.earlyExitSeconds, W - 2 * H)
        XCTAssertEqual(thu.deltaSeconds, -(W - 2 * H))
        XCTAssertEqual(thu.flags, [.earlyArrivalUncounted])
        // Continuing at 09:00 joins the overnight piece into one block: a full Thursday, no gap.
        s.presence.append(presence("2026-10-15", "09:00", "15:30"))
        let joined = Ledger.dayResult(store: s, day: day("2026-10-15"), now: defaultNow)
        XCTAssertEqual(joined.firstIn, t("2026-10-15", "00:00"))
        XCTAssertEqual(joined.lastOut, t("2026-10-15", "15:30"))
        XCTAssertEqual(joined.presenceSeconds, 15 * H + 1800)
        XCTAssertEqual(joined.deltaSeconds, 0)
        XCTAssertEqual(joined.flags, [.earlyArrivalUncounted])
        XCTAssertEqual(Ledger.gaps(store: s, day: day("2026-10-15"), now: defaultNow), [])
    }

    func testSessionSpanningFourDaysFillsTheMiddleDaysCompletely() {
        var s = Fixture.store()
        s.presence = [presence(from: t("2026-10-09", "20:00"), to: t("2026-10-12", "09:00")), presence("2026-10-12", "09:00", "15:30")]
        let r = range(s, "2026-10-09", "2026-10-12")
        XCTAssertEqual(r.map { $0.presenceSeconds }, [4 * H, 24 * H, 24 * H, W + 7 * H])
        let fri = r[0]
        XCTAssertEqual(fri.kind, .workday)
        XCTAssertEqual(fri.presenceInsideSeconds, 0)
        XCTAssertEqual(fri.lateArrivalSeconds, W)
        XCTAssertEqual(fri.extraAfterSeconds, 4 * H)
        XCTAssertEqual(fri.deltaSeconds, 4 * H - W)
        XCTAssertTrue(fri.flags.contains(.noShow))
        for weekend in r[1...2] {
            XCTAssertEqual(weekend.kind, .weekend, "\(weekend.day)")
            XCTAssertEqual(weekend.firstIn, weekend.day.start(in: Fixture.calendar))
            XCTAssertEqual(weekend.lastOut, weekend.day.end(in: Fixture.calendar))
            XCTAssertEqual(weekend.deltaSeconds, 24 * H)
            XCTAssertEqual(weekend.grossExtraSeconds, 24 * H)
            XCTAssertEqual(weekend.flags, [])
        }
        let mon = r[3]
        XCTAssertEqual(mon.extraBeforeSeconds, 7 * H)
        XCTAssertEqual(mon.deltaSeconds, 0)
        XCTAssertEqual(mon.flags, [.earlyArrivalUncounted])
        // A range that starts and ends inside the session still sees full days, and single-day calls agree.
        XCTAssertEqual(range(s, "2026-10-10", "2026-10-11").map { $0.presenceSeconds }, [24 * H, 24 * H])
        for x in r { XCTAssertEqual(Ledger.dayResult(store: s, day: x.day, now: defaultNow), x) }
    }

    func testMultiDaySessionsAcrossDSTGiveRealElapsedSecondsPerDay() {
        let now = t("2026-11-05", "20:00")
        var s = Fixture.store()
        s.presence = [presence(from: t("2026-10-31", "12:00"), to: t("2026-11-02", "12:00"))]
        let fall = range(s, "2026-10-31", "2026-11-02", now: now)
        XCTAssertEqual(fall.map { $0.presenceSeconds }, [12 * H, 25 * H, 12 * H])
        XCTAssertEqual(fall[1].deltaSeconds, 25 * H)
        XCTAssertEqual(fall[2].extraBeforeSeconds, 7 * H)
        XCTAssertEqual(fall[2].presenceInsideSeconds, 5 * H)
        XCTAssertEqual(fall[2].earlyExitSeconds, W - 5 * H)
        XCTAssertEqual(fall[2].deltaSeconds, -(W - 5 * H))
        s.presence = [presence(from: t("2026-03-07", "12:00"), to: t("2026-03-09", "12:00"))]
        let spring = range(s, "2026-03-07", "2026-03-09")
        XCTAssertEqual(spring.map { $0.presenceSeconds }, [12 * H, 23 * H, 12 * H])
        XCTAssertEqual(spring[1].deltaSeconds, 23 * H)
        XCTAssertEqual(spring[2].deltaSeconds, -(W - 5 * H))
    }
}

// MARK: - Open sessions (SPEC 4.2)

final class OpenSessionTests: XCTestCase {
    func testOpenSessionFromThreeDaysAgoRunsToMidnightOnEachPastDayAndToNowToday() {
        let now = t("2026-10-15", "12:00") // Thursday
        var s = Fixture.store()
        s.presence = [presence("2026-10-12", "07:00", nil)]
        let r = range(s, "2026-10-12", "2026-10-15", now: now)
        XCTAssertEqual(r.map { $0.presenceSeconds }, [17 * H, 24 * H, 24 * H, 12 * H])
        for x in r { XCTAssertTrue(x.flags.contains(.openPresence), "\(x.day)") }
        XCTAssertEqual(r.map { $0.flags.contains(.inProgress) }, [false, false, false, true])
        XCTAssertEqual(r[0].lastOut, t("2026-10-13", "00:00"))
        XCTAssertEqual(r[0].extraAfterSeconds, W)
        XCTAssertEqual(r[0].deltaSeconds, W)
        XCTAssertEqual(r[1].extraBeforeSeconds, 7 * H)
        XCTAssertEqual(r[1].extraAfterSeconds, W)
        XCTAssertEqual(r[1].deltaSeconds, W)
        XCTAssertEqual(r[3].lastOut, now)
        XCTAssertEqual(r[3].earlyExitSeconds, W - 5 * H)
        XCTAssertEqual(r[3].deltaSeconds, -(W - 5 * H))
        XCTAssertFalse(r[3].flags.contains(.noShow))
        // Seen from a later `now`, every closed day of the same open session is unchanged.
        XCTAssertEqual(range(s, "2026-10-12", "2026-10-14", now: t("2026-10-16", "20:00")), Array(r[0...2]))
    }

    func testOpenSessionStartedYesterdayEveningCountsAsExtraYesterdayAndEarlyToday() {
        let now = t("2026-10-16", "08:00")
        var s = Fixture.store()
        s.presence = [presence("2026-10-15", "07:00", "15:30"), presence("2026-10-15", "20:00", nil)]
        let r = range(s, "2026-10-15", "2026-10-16", now: now)
        XCTAssertEqual(r[0].extraAfterSeconds, 4 * H)
        XCTAssertEqual(r[0].deltaSeconds, 4 * H)
        XCTAssertEqual(r[0].flags, [.openPresence]) // 15:30–20:00 lies outside the window: no gap
        XCTAssertEqual(r[1].firstIn, t("2026-10-16", "00:00"))
        XCTAssertEqual(r[1].lastOut, now)
        XCTAssertEqual(r[1].extraBeforeSeconds, 7 * H)
        XCTAssertEqual(r[1].presenceInsideSeconds, H)
        XCTAssertEqual(r[1].earlyExitSeconds, W - H)
        XCTAssertEqual(Set(r[1].flags), [.openPresence, .earlyArrivalUncounted, .inProgress])
    }

    func testOpenSessionEnteredAtNowOrAfterNowShowsTheFlagButNoPresence() {
        let now = t("2026-10-16", "16:00")
        for enteredAt in [now, now.addingTimeInterval(TimeInterval(H))] {
            var s = Fixture.store()
            s.presence = [presence(from: enteredAt, to: nil)]
            let r = Ledger.dayResult(store: s, day: day("2026-10-16"), now: now)
            XCTAssertEqual(r.presenceSeconds, 0)
            XCTAssertNil(r.firstIn)
            XCTAssertNil(r.lastOut)
            XCTAssertEqual(Set(r.flags), [.openPresence, .inProgress, .noShow]) // the window ended at 15:30 with nobody there
            XCTAssertEqual(r.deltaSeconds, -W)
        }
    }
}

// MARK: - DST days (SPEC 4.7)

final class DSTDayTests: XCTestCase {
    func testSpringForwardSessionAcrossTheMissingHour() {
        var s = Fixture.store()
        // 01:30 EST → 03:30 EDT is one real hour.
        s.presence = [presence("2026-03-08", "01:30", "03:30")]
        let open = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(open.presenceSeconds, H)
        XCTAssertEqual(open.deltaSeconds, H)
        // A window 01:00–04:00 on that day is two real hours; the session is 30 min late and 30 min early.
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 4)))))
        let r = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(r.scheduledWindow?.seconds, 2 * H)
        XCTAssertEqual(r.expectedSeconds, 2 * H)
        XCTAssertEqual(r.presenceInsideSeconds, H)
        XCTAssertEqual(r.lateArrivalSeconds, 1800)
        XCTAssertEqual(r.earlyExitSeconds, 1800)
        XCTAssertEqual(r.deltaSeconds, -H)
        // The standard window is still 8.5 h of wall clock on the 23-hour day.
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule())))
        s.presence = [presence("2026-03-08", "07:00", "15:30")]
        let standard = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(standard.scheduledWindow?.seconds, W)
        XCTAssertEqual(standard.expectedSeconds, W)
        XCTAssertEqual(standard.deltaSeconds, 0)
        XCTAssertEqual(standard.flags, [])
    }

    func testScheduleInsideTheMissingHourCollapsesToNoWindow() {
        // 02:00 and 03:00 are the same instant on 2026-03-08 (both resolve to 03:00 EDT): no window, not a workday.
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 3)))))
        s.presence = [presence("2026-03-08", "03:00", "05:00")]
        let sched = Ledger.daySchedule(store: s, day: day("2026-03-08"))
        XCTAssertEqual(sched.kind, .weekend)
        XCTAssertNil(sched.window)
        let r = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(r.expectedSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, 2 * H)
        XCTAssertFalse(r.flags.contains(.noShow))
        // 02:00–03:30 is the half hour that exists.
        s.setOverride(DayOverride(day: day("2026-03-08"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 3, minute: 30)))))
        s.presence = [presence("2026-03-08", "03:00", "03:30")]
        let half = Ledger.dayResult(store: s, day: day("2026-03-08"), now: defaultNow)
        XCTAssertEqual(half.scheduledWindow?.seconds, 1800)
        XCTAssertEqual(half.deltaSeconds, 0)
        XCTAssertEqual(half.flags, [])
    }

    func testFallBackSessionAcrossTheRepeatedHour() {
        let now = t("2026-11-05", "20:00")
        var s = Fixture.store()
        // 00:30 EDT → 02:30 EST is three real hours.
        s.presence = [presence("2026-11-01", "00:30", "02:30")]
        let open = Ledger.dayResult(store: s, day: day("2026-11-01"), now: now)
        XCTAssertEqual(open.presenceSeconds, 3 * H)
        XCTAssertEqual(open.deltaSeconds, 3 * H)
        // A window 00:00–04:00 is five real hours on that day and starts at the day start.
        s.setOverride(DayOverride(day: day("2026-11-01"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 4)))))
        let r = Ledger.dayResult(store: s, day: day("2026-11-01"), now: now)
        XCTAssertEqual(r.scheduledWindow?.seconds, 5 * H)
        XCTAssertEqual(r.presenceInsideSeconds, 3 * H)
        XCTAssertEqual(r.lateArrivalSeconds, 1800)
        XCTAssertEqual(r.earlyExitSeconds, 5400)
        XCTAssertEqual(r.deltaSeconds, -2 * H)
        XCTAssertEqual(r.extraBeforeSeconds, 0)
        // An ambiguous wall-clock time resolves the same way for the schedule and for a session, so they agree.
        s.setOverride(DayOverride(day: day("2026-11-01"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2)))))
        s.presence = [presence("2026-11-01", "01:00", "02:00")]
        let ambiguous = Ledger.dayResult(store: s, day: day("2026-11-01"), now: now)
        XCTAssertEqual(ambiguous.scheduledWindow?.seconds, ambiguous.presenceSeconds)
        XCTAssertEqual(ambiguous.deltaSeconds, 0)
        XCTAssertEqual(ambiguous.flags, [])
    }

    func testTimeZoneWithDSTAtMidnightKeepsDayBoundariesConsistent() {
        // America/Santiago shifts its clocks at midnight: 2026-09-06 starts at 01:00 (23 h), 2026-04-04 lasts 25 h.
        var s = Store(settings: Settings(timeZone: TimeZone(identifier: "America/Santiago")!))
        let cal = s.calendar
        func at(_ iso: String, _ hhmm: String) -> Date { TimeOfDay(hhmm: hhmm)!.date(on: day(iso), calendar: cal) }
        let now = at("2026-09-10", "20:00")
        XCTAssertEqual(day("2026-09-06").interval(in: cal).seconds, 23 * H)
        XCTAssertEqual(day("2026-04-04").interval(in: cal).seconds, 25 * H)
        s.setOverride(DayOverride(day: day("2026-09-06"), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 0, minute: 30), end: TimeOfDay(hour: 8)))))
        s.presence = [PresenceSession(locationID: Fixture.plantA, enteredAt: at("2026-09-05", "23:00"), exitedAt: at("2026-09-06", "08:00"))]
        let r = Ledger.dayResults(store: s, from: day("2026-09-05"), through: day("2026-09-06"), now: now)
        XCTAssertEqual(r[0].presenceSeconds, H)
        XCTAssertEqual(r[0].deltaSeconds, H)
        XCTAssertEqual(r[1].firstIn, day("2026-09-06").start(in: cal))
        XCTAssertEqual(r[1].presenceSeconds, 7 * H)
        XCTAssertEqual(r[1].scheduledWindow?.seconds, 6 * H + 1800) // 00:30 does not exist and resolves to 01:30
        XCTAssertEqual(r[1].extraBeforeSeconds, 1800)
        XCTAssertEqual(r[1].presenceInsideSeconds, 6 * H + 1800)
        XCTAssertEqual(r[1].deltaSeconds, 0)
        XCTAssertEqual(r[1].flags, [.earlyArrivalUncounted])
        s.presence = [PresenceSession(locationID: Fixture.plantA, enteredAt: at("2026-04-04", "22:00"), exitedAt: at("2026-04-05", "02:00"))]
        let fall = Ledger.dayResults(store: s, from: day("2026-04-04"), through: day("2026-04-05"), now: now)
        XCTAssertEqual(fall.map { $0.presenceSeconds }, [3 * H, 2 * H])
        XCTAssertEqual(fall[0].lastOut, day("2026-04-05").start(in: cal))
    }
}

// MARK: - Windows at the day edges (SPEC 4.1 / 4.3)

final class WindowEdgeTests: XCTestCase {
    static let allDay = WeekdaySchedule(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))
    let d = "2026-10-14"

    func testWindowFromDayStartToLastMinute() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day(d), kind: .schedule(WindowEdgeTests.allDay)))
        let sched = Ledger.daySchedule(store: s, day: day(d))
        XCTAssertEqual(sched.window?.start, day(d).start(in: Fixture.calendar))
        XCTAssertEqual(sched.window?.seconds, 24 * H - 60)
        s.presence = [presence(d, "00:00", "23:59")]
        let exact = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(exact.deltaSeconds, 0)
        XCTAssertEqual(exact.expectedSeconds, 24 * H - 60)
        XCTAssertEqual(exact.flags, [])
        // Arriving the evening before: the piece starts at the day start, which is S — neither late nor early.
        s.presence = [presence(from: t("2026-10-13", "22:00"), to: t(d, "23:59"))]
        let r = range(s, "2026-10-13", d)
        XCTAssertEqual(r[0].extraAfterSeconds, 2 * H)
        XCTAssertEqual(r[1].firstIn, day(d).start(in: Fixture.calendar))
        XCTAssertEqual(r[1].extraBeforeSeconds, 0)
        XCTAssertEqual(r[1].lateArrivalSeconds, 0)
        XCTAssertEqual(r[1].deltaSeconds, 0)
        XCTAssertEqual(r[1].flags, [])
        // Leaving after midnight is one minute past E on this day: inside grace nothing counts; with grace 0 it is 60 s.
        s.presence = [presence(from: t(d, "00:00"), to: t("2026-10-15", "01:00"))]
        let past = range(s, d, "2026-10-15")
        XCTAssertEqual(past[0].lastOut, day("2026-10-15").start(in: Fixture.calendar))
        XCTAssertEqual(past[0].extraAfterSeconds, 0)
        XCTAssertEqual(past[0].deltaSeconds, 0)
        XCTAssertEqual(past[0].flags, [.graceApplied])
        XCTAssertEqual(past[1].extraBeforeSeconds, H)
        s.settings.graceMinutes = 0
        let strict = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(strict.extraAfterSeconds, 60)
        XCTAssertEqual(strict.deltaSeconds, 60)
        XCTAssertEqual(strict.flags, [])
    }

    func testTinyWindowsAtTheDayEdges() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day(d), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 0, minute: 1)))))
        let noShow = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(noShow.expectedSeconds, 60)
        XCTAssertEqual(noShow.deltaSeconds, -60)
        XCTAssertTrue(noShow.flags.contains(.noShow))
        s.presence = [presence(d, "00:00", "00:01")]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).deltaSeconds, 0)
        s.setOverride(DayOverride(day: day(d), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: 23, minute: 58), end: TimeOfDay(hour: 23, minute: 59)))))
        s.presence = [presence(from: t(d, "23:00"), to: t("2026-10-15", "01:00"))]
        let late = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(late.extraBeforeSeconds, 58 * 60)
        XCTAssertEqual(late.presenceInsideSeconds, 60)
        XCTAssertEqual(late.extraAfterSeconds, 0)
        XCTAssertEqual(late.deltaSeconds, 0)
        XCTAssertEqual(Set(late.flags), [.earlyArrivalUncounted, .graceApplied])
    }

    func testWindowWithStartEqualToOrAfterEndIsNoWindow() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "15:30")]
        for (start, end) in [(10, 10), (10, 9), (0, 0), (23, 0)] {
            s.setOverride(DayOverride(day: day(d), kind: .schedule(WeekdaySchedule(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end)))))
            let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
            XCTAssertEqual(r.kind, .weekend, "\(start)-\(end)")
            XCTAssertNil(r.scheduledWindow)
            XCTAssertEqual(r.expectedSeconds, 0)
            XCTAssertEqual(r.deltaSeconds, W) // no window: all presence counts
            XCTAssertFalse(r.flags.contains(.noShow))
        }
    }
}

// MARK: - Overlaps and identical instants (SPEC 4.7)

final class OverlapAndInstantTests: XCTestCase {
    let d = "2026-10-14"

    func testSessionNestedInsideAnotherAtADifferentSiteEndsTheOuterOne() {
        // SPEC 4.7 taken literally: Plant B at 10:00 ends the Plant A session for computation, so after
        // leaving B at 11:00 the ledger sees nobody at work (see spec question).
        let outer = presence(d, "07:00", "15:30", at: Fixture.plantA)
        let inner = presence(d, "10:00", "11:00", at: Fixture.plantB)
        for order in [[outer, inner], [inner, outer]] {
            var s = Fixture.store()
            s.presence = order
            let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
            XCTAssertEqual(r.firstIn, t(d, "07:00"))
            XCTAssertEqual(r.lastOut, t(d, "11:00"))
            XCTAssertEqual(r.presenceSeconds, 4 * H)
            XCTAssertEqual(r.earlyExitSeconds, W - 4 * H)
            XCTAssertEqual(r.deltaSeconds, -(W - 4 * H))
            XCTAssertEqual(r.flags, [.overlappingLocations])
            XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
        }
    }

    func testSessionNestedInsideAnotherAtTheSameSiteIsAbsorbed() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "15:30"), presence(d, "10:00", "11:00")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.flags, [])
    }

    func testZeroLengthSessionsContributeNothing() {
        var s = Fixture.store()
        s.presence = [presence(d, "10:00", "10:00")]
        let alone = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertNil(alone.firstIn)
        XCTAssertEqual(alone.presenceSeconds, 0)
        XCTAssertEqual(alone.flags, [.noShow])
        XCTAssertEqual(alone.deltaSeconds, -W)
        // A zero-second visit to Plant B between two Plant A sessions is no visit: the gap stays same-site, personal.
        s.presence = [presence(d, "07:00", "12:00"), presence(d, "12:30", "12:30", at: Fixture.plantB), presence(d, "13:00", "15:30")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.gapsDeductedSeconds, H)
        XCTAssertEqual(r.gapsWorkSeconds, 0)
        XCTAssertEqual(Set(r.flags), [.gapUndecided])
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].toLocationID, Fixture.plantA)
        XCTAssertEqual(gaps[0].interval, Interval(start: t(d, "12:00"), end: t(d, "13:00")))
        // Exit before entry (a corrupt fact) is empty too; the model clamps it.
        s.presence = [PresenceSession(locationID: Fixture.plantA, enteredAt: t(d, "12:00"), exitedAt: t(d, "07:00"))]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).presenceSeconds, 0)
    }

    func testDuplicatedSessionsMergeWithoutFlags() {
        var s = Fixture.store()
        let a = presence(d, "07:00", "15:30")
        var copy = a
        copy.id = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        s.presence = [a, a, copy]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.flags, [])
        // The same instants at two sites merge too, flagged: SPEC 4.7 has no "later" one.
        var elsewhere = a
        elsewhere.id = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        elsewhere.locationID = Fixture.plantB
        s.presence = [a, elsewhere]
        let two = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(two.presenceSeconds, W)
        XCTAssertEqual(two.deltaSeconds, 0)
        XCTAssertEqual(two.flags, [.overlappingLocations])
    }

    func testExitEqualToNextEntryAtAnotherSiteIsOneBlockWithoutOverlap() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "12:00", at: Fixture.plantA), presence(d, "12:00", "15:30", at: Fixture.plantB)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W)
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertEqual(r.flags, [])
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
    }
}

// MARK: - Facts far away in time, bank start before / after / in the future (SPEC 4.6)

final class FarAwayFactsTests: XCTestCase {
    func testFactsInTheFarPastAndFutureNeitherCrashNorLeakIntoTheRange() {
        var s = Fixture.store()
        s.presence = [
            presence("2026-10-14", "07:00", "15:30"),
            presence(from: Date.distantPast, to: Date.distantPast.addingTimeInterval(3600)),
            presence(from: Date.distantFuture.addingTimeInterval(-3600), to: Date.distantFuture),
            presence(from: Date.distantFuture, to: nil),
            presence(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200)),
            presence(from: t("2100-01-01", "09:00"), to: nil),
        ]
        s.manual = [ManualSession.block(category: "Travel", start: Date.distantPast, end: Date.distantPast.addingTimeInterval(60), createdAt: Fixture.created)]
        let dawn = DayKey(year: 1, month: 1, day: 1)
        let dusk = DayKey(year: 9999, month: 12, day: 31)
        s.timeOff = [TimeOffEntry(day: dawn, typeID: TimeOffType.ptoID, seconds: H), TimeOffEntry(day: dusk, typeID: TimeOffType.flexID, seconds: H)]
        s.adjustments = [Adjustment(day: dusk, seconds: 1)]
        var plain = Fixture.store()
        plain.presence = [presence("2026-10-14", "07:00", "15:30")]
        XCTAssertEqual(range(s, "2026-10-12", "2026-10-18"), range(plain, "2026-10-12", "2026-10-18"))
        XCTAssertEqual(Ledger.earliestDay(store: s, now: defaultNow), dawn)
        XCTAssertEqual(Ledger.trackingStart(store: s, now: defaultNow), day("2000-01-01"))
        let started = Date()
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        // From 2000-01-01: nothing until the schedule starts, then 205 workdays through 10-16 of which only 10-14 is covered.
        XCTAssertEqual(sum.balanceSeconds, -204 * W)
        XCTAssertEqual(sum.ytdDeltaSeconds, -204 * W)
        XCTAssertEqual(sum.monthDeltaSeconds, -11 * W)
        XCTAssertEqual(sum.weekDeltaSeconds, -4 * W)
        XCTAssertEqual(sum.todayDeltaSeconds, -W)
        XCTAssertEqual(sum.monthGrossExtraSeconds, 0)
        XCTAssertEqual(Ledger.balance(store: s, asOf: dusk, now: defaultNow), -204 * W)
        let first = Ledger.dayResult(store: s, day: dawn, now: defaultNow)
        XCTAssertEqual(first.kind, .weekend)
        XCTAssertEqual(first.timeOffSeconds, H)
        XCTAssertEqual(first.deltaSeconds, 0)
        let last = Ledger.dayResult(store: s, day: dusk, now: defaultNow)
        XCTAssertEqual(last.flags, [.future])
        XCTAssertEqual(last.deltaSeconds, 0)
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day("2026-10-16")).map { $0.usedSeconds }, [0, 0]) // before the config's asOf
    }

    func testBankStartingAsOfBeforeAndAfterTheFirstFactAndInTheFuture() {
        var s = Fixture.store()
        s.settings.bankStartingSeconds = 100
        s.presence = [presence("2026-10-14", "07:00", "16:30")] // +1 h; Thursday and Friday are no-shows
        // Before the first fact: tracking starts at the fact; the empty days in between never count.
        s.settings.bankStartingAsOf = day("1990-01-01")
        XCTAssertEqual(Ledger.trackingStart(store: s, now: defaultNow), day("2026-10-14"))
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), 100 + H - 2 * W)
        // After the first fact: the fact is outside the bank.
        s.settings.bankStartingAsOf = day("2026-10-15")
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), 100 - 2 * W)
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow).balanceSeconds, 100 - 2 * W)
        // In the future: the starting balance alone, today still reported.
        s.settings.bankStartingAsOf = day("2027-01-01")
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), 100)
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2027-06-01"), now: defaultNow), 100)
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertEqual(sum.balanceSeconds, 100)
        XCTAssertEqual(sum.ytdDeltaSeconds, 0)
        XCTAssertEqual(sum.weekDeltaSeconds, 0)
        XCTAssertEqual(sum.todayDeltaSeconds, -W)
    }
}

// MARK: - Sparse stores and unknown locations

final class SparseStoreTests: XCTestCase {
    let d = "2026-10-14"
    let siteX = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let siteY = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    func testSessionsAtUnknownLocationsCountAsPresence() {
        var s = Fixture.store()
        s.locations = []
        s.presence = [presence(d, "07:00", "12:00", at: siteX), presence(d, "13:00", "15:30", at: siteY)]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.presenceSeconds, W - H)
        XCTAssertEqual(r.gapsWorkSeconds, H) // two different (unknown) sites: a work trip by default
        XCTAssertEqual(r.deltaSeconds, 0)
        XCTAssertTrue(r.flags.contains(.gapUndecided))
        s.presence[1].locationID = siteX
        let same = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(same.gapsDeductedSeconds, H)
        XCTAssertEqual(same.deltaSeconds, -H)
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow).first?.fromLocationID, siteX)
    }

    func testStoreWithoutSchedulesLocationsTypesOrConfigs() {
        var s = Store(settings: Settings(timeZone: Fixture.tz))
        s.schedules = []
        s.locations = []
        s.timeOffTypes = []
        s.leaveBalances = []
        s.presence = [presence(d, "07:00", "15:30", at: siteX)]
        s.timeOff = [timeOff(d, TimeOffType.flexID, seconds: H)] // the type is unknown here: neither flex nor tracked
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.kind, .weekend)
        XCTAssertEqual(r.deltaSeconds, W)
        XCTAssertEqual(r.timeOffSeconds, H)
        XCTAssertEqual(r.flexSpentSeconds, 0)
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day(d)), [])
        let sum = Ledger.summary(store: s, now: defaultNow)
        XCTAssertEqual(sum.balanceSeconds, W)
        XCTAssertEqual(sum.monthGrossExtraSeconds, W)
        XCTAssertEqual(sum.todayDeltaSeconds, 0)
        XCTAssertEqual(Ledger.gaps(store: s, day: day(d), now: defaultNow), [])
    }
}

// MARK: - Huge inputs

final class LargeInputTests: XCTestCase {
    func testTwentyThousandSessionsOverAThousandDaysStayLinear() {
        var s = Fixture.store(scheduleFrom: "2024-01-01")
        let cal = Fixture.calendar
        let first = day("2024-01-01")
        let days = 1000
        for i in 0..<days {
            let dayStart = first.adding(days: i, calendar: cal).start(in: cal)
            for k in 0..<20 { // twenty 10-minute visits 5 minutes apart from 07:00, geofence-flapping style
                let start = dayStart.addingTimeInterval(TimeInterval(7 * 3600 + k * 900))
                s.presence.append(PresenceSession(locationID: k % 7 == 3 ? Fixture.plantB : Fixture.plantA, enteredAt: start,
                                                  exitedAt: start.addingTimeInterval(600), followingGapIsWork: k % 2 == 0 ? nil : true))
            }
        }
        XCTAssertEqual(s.presence.count, 20_000)
        let last = first.adding(days: days - 1, calendar: cal)
        let now = last.end(in: cal).addingTimeInterval(3600)
        let started = Date()
        let all = Ledger.dayResults(store: s, from: first, through: last, now: now)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(all.count, days)
        XCTAssertLessThan(elapsed, 2.0, "20 000 sessions over \(days) days took \(elapsed)s")
        XCTAssertTrue(all.allSatisfy { $0.presenceSeconds == 20 * 600 })
        XCTAssertTrue(all.allSatisfy { $0.flags.contains(.gapUndecided) == ($0.scheduledWindow != nil) })
        let summaryStarted = Date()
        XCTAssertEqual(Ledger.summary(store: s, now: now).balanceSeconds, all.reduce(0) { $0 + $1.deltaSeconds })
        XCTAssertLessThan(Date().timeIntervalSince(summaryStarted), 2.0)
    }

    func testTwentyThousandSessionsOnOneDayStayLinear() {
        var s = Fixture.store()
        let start = t("2026-10-14", "00:00")
        for i in 0..<20_000 { // one-second visits one second apart at the same site: 11 h 6 min 40 s in all
            s.presence.append(PresenceSession(locationID: Fixture.plantA, enteredAt: start.addingTimeInterval(Double(2 * i)),
                                              exitedAt: start.addingTimeInterval(Double(2 * i + 1))))
        }
        let started = Date()
        let r = Ledger.dayResult(store: s, day: day("2026-10-14"), now: defaultNow)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0, "20 000 sessions on one day took \(elapsed)s")
        XCTAssertEqual(r.presenceSeconds, 20_000)
        XCTAssertEqual(r.firstIn, start)
        XCTAssertEqual(r.lastOut, start.addingTimeInterval(39_999))
        XCTAssertEqual(r.presenceInsideSeconds, 7400) // visits 12 600 … 19 999 lie inside 07:00–15:30
        XCTAssertEqual(r.gapsDeductedSeconds, W - 7400)
        XCTAssertEqual(r.earlyExitSeconds, W - 7400 - 7399)
        XCTAssertFalse(r.flags.contains(.overlappingLocations))
        XCTAssertEqual(Ledger.gaps(store: s, day: day("2026-10-14"), now: defaultNow).count, 7399)
    }
}

// MARK: - Summaries on January 1 and on the first day of the week, accrual anchored late (SPEC 4.6)

final class SummaryEdgeTests: XCTestCase {
    func testSummaryOnNewYearsDay() {
        var s = Fixture.store(scheduleFrom: "2025-01-01")
        s.settings.bankStartingAsOf = day("2025-12-01")
        s.presence = [presence("2025-12-31", "07:00", "16:00"), presence("2026-01-01", "07:00", "15:45")] // Wed +30 m, Thu +15 m
        let now = t("2026-01-01", "20:00")
        let sum = Ledger.summary(store: s, now: now)
        XCTAssertEqual(sum.balanceSeconds, 2700)
        XCTAssertEqual(sum.ytdDeltaSeconds, 900)
        XCTAssertEqual(sum.monthDeltaSeconds, 900)
        XCTAssertEqual(sum.monthGrossExtraSeconds, 900)
        XCTAssertEqual(sum.todayDeltaSeconds, 900)
        XCTAssertEqual(sum.weekDeltaSeconds, 2700) // Sunday 12-28 … Thursday 01-01 reaches into last year
        s.settings.weekStartsOn = .thursday // January 1 2026 is a Thursday: the week is just today
        XCTAssertEqual(Ledger.summary(store: s, now: now).weekDeltaSeconds, 900)
        XCTAssertEqual(Ledger.weekStart(containing: day("2026-01-01"), weekStartsOn: .thursday, calendar: Fixture.calendar), day("2026-01-01"))
        XCTAssertEqual(Ledger.weekStart(containing: day("2026-01-01"), weekStartsOn: .friday, calendar: Fixture.calendar), day("2025-12-26"))
    }

    func testSummaryOnAMondayDependsOnTheWeekStart() {
        var s = Fixture.store()
        s.presence = [presence("2026-10-11", "09:00", "12:00"), presence("2026-10-12", "07:00", "16:30")] // Sun +3 h, Mon +1 h
        let monday = t("2026-10-12", "20:00")
        XCTAssertEqual(Ledger.summary(store: s, now: monday).weekDeltaSeconds, 4 * H)
        s.settings.weekStartsOn = .monday
        let sum = Ledger.summary(store: s, now: monday)
        XCTAssertEqual(sum.weekDeltaSeconds, H)
        XCTAssertEqual(sum.todayDeltaSeconds, H)
        XCTAssertEqual(sum.balanceSeconds, 4 * H)
    }

    func testLeaveAccrualAnchoredAfterTheConfigDate() {
        var s = Fixture.store()
        s.upsert(LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 10 * H, asOf: day("2026-01-01"),
                                    accrual: AccrualRule(seconds: H, period: .weekly, anchor: day("2026-10-05"))))
        func pto(asOf iso: String) -> LeaveBalance? { Ledger.leaveBalances(store: s, asOf: day(iso)).first { $0.typeID == TimeOffType.ptoID } }
        XCTAssertEqual(pto(asOf: "2026-10-04")?.accruedSeconds, 0)
        XCTAssertEqual(pto(asOf: "2026-10-05")?.accruedSeconds, H) // the anchor itself grants
        XCTAssertEqual(pto(asOf: "2026-10-16")?.accruedSeconds, 2 * H)
        XCTAssertEqual(pto(asOf: "2026-10-16")?.remainingSeconds, 12 * H)
        // Config dated after the anchor: boundaries before the config date do not grant.
        s.upsert(LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 10 * H, asOf: day("2026-10-14"),
                                    accrual: AccrualRule(seconds: H, period: .weekly, anchor: day("2026-10-05"))))
        XCTAssertEqual(pto(asOf: "2026-10-16")?.accruedSeconds, 0) // 10-05 and 10-12 precede the config, 10-19 the query
        XCTAssertEqual(pto(asOf: "2026-10-19")?.accruedSeconds, H)
    }
}

// MARK: - Determinism and independence from `now`

final class DeterminismAndNowTests: XCTestCase {
    func testRepeatedCallsAndDifferentNowsAgreeOnClosedDays() {
        var s = Fixture.store()
        s.presence = [
            presence("2026-10-12", "06:50", "12:00", gapIsWork: true), presence("2026-10-12", "12:40", "15:28"),
            presence("2026-10-13", "07:00", "10:00"), presence("2026-10-13", "09:30", "11:00", at: Fixture.plantB),
            presence("2026-10-13", "13:00", "16:00"), presence(from: t("2026-10-14", "22:00"), to: t("2026-10-15", "01:00")),
        ]
        s.manual = [manualBlock("2026-10-13", "11:30", "12:00", countsAs: .regular), manualBlock("2026-10-14", "18:30", "19:30")]
        s.timeOff = [timeOff("2026-10-14", TimeOffType.ptoID, seconds: H), timeOff("2026-10-15", TimeOffType.flexID, seconds: 1800)]
        s.adjustments = [Adjustment(day: day("2026-10-12"), seconds: 300)]
        let a = range(s, "2026-10-12", "2026-10-16")
        XCTAssertEqual(a, range(s, "2026-10-12", "2026-10-16"))
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow), Ledger.summary(store: s, now: defaultNow))
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day("2026-10-16")), Ledger.leaveBalances(store: s, asOf: day("2026-10-16")))
        for x in a { XCTAssertEqual(Ledger.gaps(store: s, day: x.day, now: defaultNow), Ledger.gaps(store: s, day: x.day, now: defaultNow)) }
        XCTAssertTrue(a.contains { $0.flags.contains(.overlappingLocations) })
        XCTAssertTrue(a.contains { $0.gapsWorkSeconds > 0 })
        // Without open sessions a closed day does not depend on `now`: tomorrow, next week, next year, the far future.
        for now in [t("2026-10-17", "00:00"), t("2026-10-23", "20:00"), t("2027-10-16", "20:00"), Date.distantFuture] {
            XCTAssertEqual(range(s, "2026-10-12", "2026-10-15", now: now), Array(a[0...3]), "\(now)")
        }
    }
}

// MARK: - firstIn / lastOut and presence over merged intervals (SPEC 4.2)

final class FirstInLastOutTests: XCTestCase {
    let d = "2026-10-14"

    func testFirstInAndLastOutSpanPresenceAndRegularManualButNotExtra() {
        var s = Fixture.store()
        s.presence = [presence(d, "08:00", "12:00"), presence(d, "15:00", "16:00")]
        s.manual = [manualBlock(d, "05:00", "06:00", countsAs: .regular), manualBlock(d, "13:00", "14:00", countsAs: .regular),
                    manualBlock(d, "04:00", "04:30"), manualBlock(d, "17:00", "18:00")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.firstIn, t(d, "05:00"))
        XCTAssertEqual(r.lastOut, t(d, "16:00"))
        XCTAssertEqual(r.presenceSeconds, 7 * H) // 1 + 4 + 1 + 1: the gaps are not presence
        XCTAssertEqual(r.manualRegularSeconds, 2 * H)
        XCTAssertEqual(r.manualExtraSeconds, 5400)
        XCTAssertEqual(r.extraBeforeSeconds, H)
        XCTAssertEqual(r.presenceInsideSeconds, 5 * H + 1800)
        XCTAssertEqual(r.gapsDeductedSeconds, 3 * H) // 07–08, 12–13, 14–15
        XCTAssertEqual(r.gapsDeductedSeconds, W - r.presenceInsideSeconds)
        XCTAssertEqual(r.extraAfterSeconds, 1800)
        XCTAssertEqual(r.deltaSeconds, 1800 - 3 * H + 5400)
        let gaps = Ledger.gaps(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(gaps.map { $0.secondsInsideWindow }, [H, H, H])
        XCTAssertEqual(gaps.map { $0.interval.start }, [t(d, "06:00"), t(d, "12:00"), t(d, "14:00")])
    }

    func testLastOutFollowsTheOverlapCutAndAnOpenRegularTimer() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "15:30", at: Fixture.plantA), presence(d, "10:00", "11:00", at: Fixture.plantB)]
        XCTAssertEqual(Ledger.dayResult(store: s, day: day(d), now: defaultNow).lastOut, t(d, "11:00"))
        let now = t("2026-10-16", "21:00")
        var timer = ManualSession(category: "Home work", countsAs: .regular, createdAt: Fixture.created)
        timer.segments = [ManualSegment(start: t("2026-10-16", "18:00"), end: t("2026-10-16", "18:30")), ManualSegment(start: t("2026-10-16", "19:00"), end: nil)]
        s.presence = [presence("2026-10-16", "07:00", "15:30")]
        s.manual = [timer]
        let today = Ledger.dayResult(store: s, day: day("2026-10-16"), now: now)
        XCTAssertEqual(today.firstIn, t("2026-10-16", "07:00"))
        XCTAssertEqual(today.lastOut, now)
        XCTAssertEqual(today.presenceSeconds, W + 1800 + 2 * H)
        XCTAssertEqual(today.manualRegularSeconds, 1800 + 2 * H)
        XCTAssertEqual(today.extraAfterSeconds, 1800 + 2 * H)
        XCTAssertEqual(today.flags, [.inProgress]) // only presence sessions carry .openPresence; the gaps lie after E
    }
}

// MARK: - Absurd imported numbers

final class AbsurdNumbersTests: XCTestCase {
    let d = "2026-10-14"

    func testAbsurdTimeOffAndAdjustmentsSaturateInsteadOfTrapping() {
        var s = Fixture.store()
        s.presence = [presence(d, "07:00", "16:30"), presence("2026-10-15", "07:00", "16:30")] // +1 h each
        s.adjustments = [Adjustment(day: day(d), seconds: Int.max), Adjustment(day: day(d), seconds: Int.max)]
        s.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: Int.max), timeOff(d, TimeOffType.ptoID, seconds: Int.max),
                     timeOff("2026-10-15", TimeOffType.flexID, seconds: Int.max), timeOff("2026-10-15", TimeOffType.flexID, seconds: Int.max),
                     timeOff("2026-10-10", TimeOffType.flexID, seconds: Int.max)]
        s.adjustments.append(Adjustment(day: day("2026-10-10"), seconds: Int.max))
        let r = range(s, "2026-10-10", "2026-10-15")
        let sat = r[0], wed = r[4], thu = r[5]
        XCTAssertEqual(sat.deltaSeconds, 0) // Int.max − Int.max on a no-window day
        XCTAssertEqual(sat.grossExtraSeconds, Int.max)
        XCTAssertEqual(wed.adjustmentSeconds, Int.max)
        XCTAssertEqual(wed.timeOffSeconds, W)
        XCTAssertEqual(wed.deltaSeconds, Int.max)
        XCTAssertEqual(wed.grossExtraSeconds, Int.max)
        XCTAssertEqual(thu.flexSpentSeconds, Int.max)
        XCTAssertEqual(thu.timeOffSeconds, W)
        XCTAssertEqual(thu.deltaSeconds, H + W - Int.max)
        // −2 W for Mon/Tue, then Int.max, then H + W − Int.max, then −W for Friday: nothing saturates in that order.
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), H - 2 * W)
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow).monthGrossExtraSeconds, Int.max)
    }

    func testAbsurdBreakStartingBalanceAndUsageDoNotTrap() {
        var s = Fixture.store()
        s.setOverride(DayOverride(day: day(d), kind: .schedule(WeekdaySchedule(unpaidBreakMinutes: Int.max))))
        s.presence = [presence(d, "07:00", "16:30")]
        let r = Ledger.dayResult(store: s, day: day(d), now: defaultNow)
        XCTAssertEqual(r.expectedSeconds, 0)
        XCTAssertEqual(r.deltaSeconds, H)
        s.settings.bankStartingSeconds = Int.max
        XCTAssertEqual(Ledger.balance(store: s, asOf: day("2026-10-16"), now: defaultNow), Int.max - 2 * W)
        XCTAssertEqual(Ledger.summary(store: s, now: defaultNow).balanceSeconds, Int.max - 2 * W)
        s.timeOff = [timeOff(d, TimeOffType.ptoID, seconds: Int.max), timeOff(d, TimeOffType.ptoID, seconds: Int.max)]
        XCTAssertEqual(Ledger.leaveBalances(store: s, asOf: day(d)).first { $0.typeID == TimeOffType.ptoID }?.usedSeconds, Int.max)
    }
}
