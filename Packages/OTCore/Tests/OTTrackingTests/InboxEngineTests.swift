import XCTest
import OTModels
@testable import OTTracking

final class InboxEngineTests: XCTestCase {
    typealias F = Fixture

    /// Wednesday 2026-10-14, 6 PM New York.
    let now = Fixture.date("2026-10-14 18:00")

    func items(_ store: Store, _ results: [DayResult] = [], now: Date? = nil, exports: [String] = []) -> [InboxItem] {
        InboxEngine.items(store: store, dayResults: results, now: now ?? self.now, monthlyExports: exports)
    }

    func only(_ kind: InboxKind, in list: [InboxItem]) -> [InboxItem] { list.filter { $0.kind == kind } }

    // MARK: Empty

    func testEmptyStoreHasNoItems() {
        XCTAssertEqual(items(Store(settings: F.settings)), [])
        XCTAssertEqual(items(F.store(), [F.workday("2026-10-14")]), [])
    }

    // MARK: gap

    func testGapAtSameLocationIsDeducted() {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        let b = F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30")
        store.presence = [b, a]   // order in the store must not matter
        let list = items(store, [F.workday("2026-10-14")])

        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "gap:\(a.id.uuidString)")
        XCTAssertEqual(item.kind, .gap)
        XCTAssertEqual(item.day, F.day("2026-10-14"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-14 11:30"))
        XCTAssertEqual(item.title, "Away 11:30 AM – 12:40 PM")
        XCTAssertEqual(item.detail, "Left Plant A, returned to Plant A · 1h 10m")
        XCTAssertEqual(item.defaultApplied, "Deducted 1h 10m")
        XCTAssertEqual(item.actions, [.markGapWork, .markGapPersonal])
        XCTAssertEqual(item.subjectID, a.id)
    }

    func testGapToDifferentLocationCountsAsWork() {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        let b = F.session(F.plantB, "2026-10-14 12:40", "2026-10-14 15:30")
        store.presence = [a, b]
        let list = only(.gap, in: items(store, [F.workday("2026-10-14")]))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].defaultApplied, "Counted as work")
        XCTAssertEqual(list[0].detail, "Left Plant A, arrived at Plant B · 1h 10m")
        XCTAssertEqual(list[0].subjectID, a.id)
    }

    func testGapWithDecisionIsNotRaised() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30", gapIsWork: false),
            F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30"),
        ]
        XCTAssertEqual(items(store, [F.workday("2026-10-14")]), [])
        store.presence[0].followingGapIsWork = true
        XCTAssertEqual(items(store, [F.workday("2026-10-14")]), [])
    }

    func testGapOutsideWindowIsNotRaised() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 15:30"),
            F.session(F.plantA, "2026-10-14 18:00", "2026-10-14 19:00"),   // evening return, after the window
        ]
        XCTAssertEqual(only(.gap, in: items(store, [F.workday("2026-10-14")])), [])
        store.presence = [
            F.session(F.plantA, "2026-10-14 05:00", "2026-10-14 06:00"),   // pre-dawn visit, before the window
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 15:30"),
        ]
        XCTAssertEqual(only(.gap, in: items(store, [F.workday("2026-10-14")])), [])
    }

    func testGapPartlyInsideWindowDeductsOnlyTheInsidePart() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 15:00"),
            F.session(F.plantA, "2026-10-14 16:00", "2026-10-14 17:00"),
        ]
        let list = only(.gap, in: items(store, [F.workday("2026-10-14")]))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].defaultApplied, "Deducted 30m")
        XCTAssertEqual(list[0].detail, "Left Plant A, returned to Plant A · 1h")
    }

    func testGapWithoutDayResultOrWindowIsNotRaised() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30"),
            F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30"),
        ]
        XCTAssertEqual(items(store, []), [])
        XCTAssertEqual(items(store, [F.offDay("2026-10-14")]), [])
    }

    func testGapBeforeAnOpenSessionIsRaised() {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        store.presence = [a, F.session(F.plantA, "2026-10-14 12:40", nil)]
        let list = only(.gap, in: items(store, [F.workday("2026-10-14")]))
        XCTAssertEqual(list.map(\.key), ["gap:\(a.id.uuidString)"])
    }

    func testGapAcrossMidnightIsNotRaised() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 23:00"),
            F.session(F.plantA, "2026-10-15 01:00", "2026-10-15 02:00"),
        ]
        XCTAssertEqual(only(.gap, in: items(store, [F.workday("2026-10-14"), F.workday("2026-10-15")])), [])
    }

    func testOverlappingSessionsProduceNoGap() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 12:00"),
            F.session(F.plantB, "2026-10-14 11:00", "2026-10-14 15:30"),
        ]
        XCTAssertEqual(only(.gap, in: items(store, [F.workday("2026-10-14")])), [])
    }

    func testGapsOnSeveralDaysAreAllRaised() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-13 07:00", "2026-10-13 11:00"),
            F.session(F.plantA, "2026-10-13 12:00", "2026-10-13 15:30"),
            F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 11:30"),
            F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30"),
        ]
        let list = only(.gap, in: items(store, [F.workday("2026-10-13"), F.workday("2026-10-14")]))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.day), [F.day("2026-10-14"), F.day("2026-10-13")], "newest first")
        XCTAssertEqual(list[1].defaultApplied, "Deducted 1h")
    }

    func testSingleSessionProducesNoGap() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 15:30")]
        XCTAssertEqual(items(store, [F.workday("2026-10-14")]), [])
    }

    // MARK: noshow

    func testNoShowItem() {
        let result = F.workday("2026-10-13") { r in
            r.flags = [.noShow]
            r.gapsDeductedSeconds = 30_600
            r.deltaSeconds = -30_600
        }
        let list = items(F.store(), [result, F.workday("2026-10-14")])
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "noshow:2026-10-13")
        XCTAssertEqual(item.kind, .noShow)
        XCTAssertEqual(item.day, F.day("2026-10-13"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-13 15:30"))
        XCTAssertEqual(item.title, "No show Tue Oct 13")
        XCTAssertEqual(item.detail, "No presence recorded · scheduled 7:00 AM – 3:30 PM · deficit 8h 30m")
        XCTAssertEqual(item.defaultApplied, "Deducted 8h 30m")
        XCTAssertEqual(item.actions, [.addTimeOff(kind: .pto), .addTimeOff(kind: .personal), .markRemoteDay,
                                      .enterHours, .excuseDay, .keepDeficit])
        XCTAssertNil(item.subjectID)
    }

    func testNoShowDeficitReflectsPartialTimeOff() {
        let result = F.workday("2026-10-13") { r in
            r.flags = [.noShow]
            r.timeOffSeconds = 4 * 3600
            r.deltaSeconds = -(30_600 - 4 * 3600)
        }
        let list = items(F.store(), [result])
        XCTAssertTrue(list[0].detail.hasSuffix("deficit 4h 30m"))
    }

    func testDayWithoutNoShowFlagIsNotRaised() {
        let result = F.workday("2026-10-13") { r in r.flags = [.graceApplied] }
        XCTAssertEqual(items(F.store(), [result]), [])
    }

    // MARK: exit

    func testExitItemForStayingLate() {
        var store = F.store()
        let s = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42")
        store.presence = [s]
        let result = F.workday("2026-10-14") { r in r.extraAfterSeconds = 2520; r.lastOut = s.exitedAt }
        let list = items(store, [result])
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "exit:\(s.id.uuidString)")
        XCTAssertEqual(item.kind, .exit)
        XCTAssertEqual(item.title, "Left Plant A 5:42 PM")
        XCTAssertEqual(item.detail, "+42m")
        XCTAssertEqual(item.defaultApplied, "Added 42m")
        XCTAssertEqual(item.actions, [.confirm, .adjustSession, .removeSession])
        XCTAssertEqual(item.subjectID, s.id)
        XCTAssertEqual(item.day, F.day("2026-10-14"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-14 17:42"))
    }

    func testExitItemForLeavingEarlyUsesMinusSign() {
        var store = F.store()
        let s = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 15:12")
        store.presence = [s]
        let result = F.workday("2026-10-14") { r in r.earlyExitSeconds = 1080 }
        let list = items(store, [result])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "Left Plant A 3:12 PM")
        XCTAssertEqual(list[0].detail, "\u{2212}18m")
        XCTAssertEqual(list[0].defaultApplied, "Deducted 18m")
    }

    func testExitItemOnlyForTodayOrYesterday() {
        var store = F.store()
        let yesterday = F.session(F.plantA, "2026-10-13 07:02", "2026-10-13 17:42")
        let older = F.session(F.plantA, "2026-10-12 07:02", "2026-10-12 17:42")
        store.presence = [yesterday, older]
        let results = [
            F.workday("2026-10-13") { r in r.extraAfterSeconds = 2520 },
            F.workday("2026-10-12") { r in r.extraAfterSeconds = 2520 },
        ]
        let list = only(.exit, in: items(store, results))
        XCTAssertEqual(list.map(\.subjectID), [yesterday.id])
    }

    func testExitItemSkipsManualAndImportedSessions() {
        var store = F.store()
        store.presence = [
            F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42", source: .manual),
            F.session(F.plantB, "2026-10-13 07:02", "2026-10-13 17:42", source: .imported),
        ]
        let results = [
            F.workday("2026-10-14") { r in r.extraAfterSeconds = 2520 },
            F.workday("2026-10-13") { r in r.extraAfterSeconds = 2520 },
        ]
        XCTAssertEqual(only(.exit, in: items(store, results)), [])
    }

    func testExitItemSkipsMidDayExitAndOpenSessions() {
        var store = F.store()
        let lunch = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30", gapIsWork: false)
        let last = F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 17:42")
        store.presence = [lunch, last]
        let result = F.workday("2026-10-14") { r in r.extraAfterSeconds = 2520 }
        XCTAssertEqual(only(.exit, in: items(store, [result])).map(\.subjectID), [last.id])

        // When the user came back and is still there, the earlier exit is not the day's departure.
        store.presence = [lunch, F.session(F.plantA, "2026-10-14 12:40", nil)]
        XCTAssertEqual(only(.exit, in: items(store, [result])), [])
    }

    func testExitItemSkipsWhenDayDidNotMove() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 15:30")]
        XCTAssertEqual(items(store, [F.workday("2026-10-14")]), [])
    }

    func testExitItemUsesTheSessionsExitDay() {
        var store = F.store()
        let nightShift = F.session(F.plantA, "2026-10-13 22:00", "2026-10-14 02:00")
        store.presence = [nightShift]
        let results = [
            F.workday("2026-10-13"),
            F.workday("2026-10-14") { r in r.extraAfterSeconds = 600 },
        ]
        let list = only(.exit, in: items(store, results))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].day, F.day("2026-10-14"))
        XCTAssertEqual(list[0].title, "Left Plant A 2:00 AM")
    }

    // MARK: early

    func testEarlyArrivalItem() {
        let result = F.workday("2026-10-14") { r in
            r.flags = [.earlyArrivalUncounted]
            r.extraBeforeSeconds = 1500
            r.firstIn = F.date("2026-10-14 06:35")
        }
        let list = items(F.store(), [result])
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "early:2026-10-14")
        XCTAssertEqual(item.kind, .earlyArrival)
        XCTAssertEqual(item.title, "Arrived early Wed Oct 14")
        XCTAssertEqual(item.detail, "In at 6:35 AM · 25m before 7:00 AM")
        XCTAssertEqual(item.defaultApplied, "Not counted")
        XCTAssertEqual(item.actions, [.countEarlyArrival, .dontCountEarlyArrival])
        XCTAssertEqual(item.occurredAt, F.date("2026-10-14 06:35"))
        XCTAssertEqual(item.day, F.day("2026-10-14"))
        XCTAssertNil(item.subjectID)
    }

    func testEarlyArrivalOnlyTodayOrYesterday() {
        let results = [
            F.workday("2026-10-13") { r in r.flags = [.earlyArrivalUncounted]; r.extraBeforeSeconds = 600 },
            F.workday("2026-10-12") { r in r.flags = [.earlyArrivalUncounted]; r.extraBeforeSeconds = 600 },
        ]
        XCTAssertEqual(items(F.store(), results).map(\.key), ["early:2026-10-13"])
    }

    // MARK: timer

    func testTimerItemAppearsExactlyAtNudgeBoundary() throws {
        var store = F.store()
        XCTAssertEqual(store.settings.timerNudgeMinutes, 240)
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))

        XCTAssertEqual(items(store, now: F.date("2026-10-14 12:59:59")), [])
        let list = items(store, now: F.date("2026-10-14 13:00:00"))
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "timer:\(m.id.uuidString):1")
        XCTAssertEqual(item.kind, .timer)
        XCTAssertEqual(item.title, "Timer still running (4h)")
        XCTAssertEqual(item.detail, "Home work · started 9:00 AM")
        XCTAssertEqual(item.actions, [.stillWorking, .stopTimerNow, .setTimerStop])
        XCTAssertEqual(item.subjectID, m.id)
        XCTAssertEqual(item.day, F.day("2026-10-14"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-14 13:00:00"))
        XCTAssertNil(item.defaultApplied)
    }

    func testTimerItemCountsPeriodsAndHonoursDismissal() throws {
        var store = F.store()
        let m = try ManualTimer.start(store: &store, category: "Home work", note: "slides", at: F.date("2026-10-14 09:00"))
        XCTAssertEqual(items(store, now: F.date("2026-10-14 17:00")).map(\.key), ["timer:\(m.id.uuidString):2"])
        XCTAssertEqual(items(store, now: F.date("2026-10-14 17:00"))[0].detail, "Home work · started 9:00 AM · slides")

        store.dismissInbox("timer:\(m.id.uuidString):1")
        XCTAssertEqual(items(store, now: F.date("2026-10-14 14:00")), [], "still working at 5h hides period 1")
        XCTAssertEqual(items(store, now: F.date("2026-10-14 17:00")).map(\.key), ["timer:\(m.id.uuidString):2"], "period 2 is a fresh item")
    }

    func testTimerItemIgnoresPausedSessionAndPausedTime() throws {
        var store = F.store()
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 10:00"))
        XCTAssertEqual(items(store, now: F.date("2026-10-14 18:00")), [], "a paused timer never nudges")

        try ManualTimer.resume(store: &store, at: F.date("2026-10-14 11:00"))
        XCTAssertEqual(items(store, now: F.date("2026-10-14 13:59")), [], "1h + 2h59m active")
        XCTAssertEqual(items(store, now: F.date("2026-10-14 14:00")).map(\.key), ["timer:\(m.id.uuidString):1"])
    }

    func testTimerItemIgnoresStoppedSessionsAndZeroNudge() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        try ManualTimer.stop(store: &store, at: F.date("2026-10-14 15:00"))
        XCTAssertEqual(items(store, now: F.date("2026-10-14 18:00")), [])

        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        store.settings.timerNudgeMinutes = 0
        XCTAssertEqual(items(store, now: F.date("2026-10-14 18:00")), [])
    }

    // MARK: stale

    func testStaleOpenSession() {
        var store = F.store()
        XCTAssertEqual(store.settings.staleOpenSessionHours, 16)
        let s = F.session(F.plantA, "2026-10-13 07:00", nil)
        store.presence = [s]
        let list = items(store, now: F.date("2026-10-14 00:00"))
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "stale:\(s.id.uuidString)")
        XCTAssertEqual(item.kind, .staleOpen)
        XCTAssertEqual(item.title, "Still at Plant A?")
        XCTAssertEqual(item.detail, "Arrived Tue Oct 13 7:00 AM · no exit for 17h")
        XCTAssertEqual(item.actions, [.setExitTime, .deleteSession])
        XCTAssertEqual(item.subjectID, s.id)
        XCTAssertEqual(item.day, F.day("2026-10-13"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-13 07:00"))
    }

    func testStaleBoundaryIsStrict() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-13 08:00", nil)]
        XCTAssertEqual(items(store, now: F.date("2026-10-14 00:00:00")), [], "exactly 16h is not yet stale")
        XCTAssertEqual(items(store, now: F.date("2026-10-14 00:00:01")).count, 1)
        store.presence = [F.session(F.plantA, "2026-10-13 09:00", nil)]
        XCTAssertEqual(items(store, now: F.date("2026-10-14 00:00")), [])
    }

    func testClosedSessionsAreNeverStale() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-01 07:00", "2026-10-01 15:30")]
        XCTAssertEqual(items(store, [F.workday("2026-10-01")]), [])
    }

    func testStaleAcrossFallBackUsesRealElapsedTime() {
        var store = F.store()
        let s = PresenceSession(locationID: F.plantB, enteredAt: F.iso("2026-10-31T20:00:00-04:00"))
        store.presence = [s]
        // Wall clock says 16h, real time is 17h.
        let list = items(store, now: F.iso("2026-11-01T12:00:00-05:00"))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].detail, "Arrived Sat Oct 31 8:00 PM · no exit for 17h")
    }

    // MARK: orphanExit

    func testOrphanExitItem() {
        var store = F.store()
        let e = F.exit(F.plantA, "2026-10-14 17:42")
        store.locationEvents = [e]
        let list = items(store)
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.key, "orphanExit:\(e.id.uuidString)")
        XCTAssertEqual(item.kind, .orphanExit)
        XCTAssertEqual(item.title, "Left Plant A 5:42 PM with no arrival")
        XCTAssertEqual(item.detail, "No open session on Wed Oct 14 · set the arrival time to record the day")
        XCTAssertEqual(item.actions, [.setArrivalTime, .ignore])
        XCTAssertEqual(item.subjectID, e.id)
        XCTAssertEqual(item.day, F.day("2026-10-14"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-14 17:42"))
    }

    func testOrphanExitViaInterpreterThenResolvedBySession() {
        var store = F.store()
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:42"), to: &store)
        XCTAssertTrue(out.orphanExit)
        XCTAssertEqual(only(.orphanExit, in: items(store)).count, 1)
        // A hand-entered session covering the exit answers the question.
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 17:42", source: .manual)]
        XCTAssertEqual(only(.orphanExit, in: items(store)), [])
    }

    func testExitThatClosedASessionIsNotOrphan() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:42"), to: &store)
        XCTAssertEqual(only(.orphanExit, in: items(store)), [])

        // Exit for B while open at A closes A at that instant: accounted for.
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-15 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantB, "2026-10-15 12:00"), to: &store)
        XCTAssertEqual(only(.orphanExit, in: items(store, now: F.date("2026-10-15 18:00"))), [])
    }

    func testOrphanExitToleranceIsSixtySeconds() {
        var store = F.store()
        let e = F.exit(F.plantA, "2026-10-14 17:42:00")
        store.locationEvents = [e]
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 17:41:00")]
        XCTAssertEqual(only(.orphanExit, in: items(store)), [], "within 60 s of the exit")
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 17:40:59")]
        XCTAssertEqual(only(.orphanExit, in: items(store)).count, 1)
    }

    func testOrphanExitLookbackIsFourteenDays() {
        var store = F.store()
        let recent = F.exit(F.plantA, "2026-10-01 17:42")       // 13 days ago
        let old = F.exit(F.plantA, "2026-09-29 17:42")          // 15 days ago
        let edge = LocationEvent(locationID: F.plantA, kind: .exit, at: now.addingTimeInterval(-14 * 86_400))
        store.locationEvents = [recent, old, edge]
        let list = only(.orphanExit, in: items(store))
        XCTAssertEqual(Set(list.map(\.subjectID)), [recent.id, edge.id])
    }

    func testOrphanExitSkipsNonGeofenceEntersAndUnknownLocations() {
        var store = F.store()
        store.locationEvents = [
            F.exit(F.plantA, "2026-10-14 17:42", source: .manual),
            F.exit(F.plantA, "2026-10-14 17:43", source: .imported),
            F.enter(F.plantA, "2026-10-14 17:44"),
            F.exit(F.unknownLocation, "2026-10-14 17:45"),
        ]
        XCTAssertEqual(only(.orphanExit, in: items(store)), [])
    }

    func testOrphanExitCoveredByOpenSession() {
        var store = F.store()
        store.locationEvents = [F.exit(F.plantB, "2026-10-14 12:00")]
        store.presence = [F.session(F.plantA, "2026-10-14 07:00", nil)]
        XCTAssertEqual(only(.orphanExit, in: items(store)), [], "an open session running to now covers the exit")
    }

    // MARK: export

    func testExportItems() {
        let list = items(F.store(), exports: ["2026-09", "2026-08"])
        XCTAssertEqual(list.map(\.key), ["export:2026-09", "export:2026-08"])
        let item = list[0]
        XCTAssertEqual(item.kind, .monthlyExport)
        XCTAssertEqual(item.title, "September 2026 export ready")
        XCTAssertEqual(item.detail, "Monthly Excel file for September 2026 · email or share it")
        XCTAssertEqual(item.actions, [.emailExport, .shareExport, .dismiss])
        XCTAssertEqual(item.day, F.day("2026-09-01"))
        XCTAssertEqual(item.occurredAt, F.date("2026-10-01 00:00"))
        XCTAssertNil(item.subjectID)
        XCTAssertEqual(list[1].occurredAt, F.date("2026-09-01 00:00"))
    }

    func testExportItemsDedupeAndTolerateBadKeys() {
        let list = items(F.store(), exports: ["2026-09", " 2026-09", "bogus", ""])
        XCTAssertEqual(list.map(\.key), ["export:bogus", "export:2026-09"])
        XCTAssertEqual(list[0].day, F.day("2026-10-14"), "unparsable month falls back to today")
    }

    // MARK: dismissal, sorting, formatting

    func testDismissedKeysAreHidden() {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        store.presence = [a, F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30")]
        let result = F.workday("2026-10-14") { r in r.flags = [.earlyArrivalUncounted]; r.extraBeforeSeconds = 600 }
        XCTAssertEqual(items(store, [result], exports: ["2026-09"]).count, 3)

        store.dismissInbox("export:2026-09")
        store.dismissInbox("early:2026-10-14")
        XCTAssertEqual(items(store, [result], exports: ["2026-09"]).map(\.key), ["gap:\(a.id.uuidString)"])
        store.dismissInbox("gap:\(a.id.uuidString)")
        XCTAssertEqual(items(store, [result], exports: ["2026-09"]), [])
    }

    func testItemsAreSortedNewestFirst() throws {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        let last = F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 17:42")
        store.presence = [a, last]
        let stale = F.session(F.plantB, "2026-10-12 07:00", nil)
        store.presence.append(stale)
        let timer = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 13:00"))
        let results = [
            F.workday("2026-10-14") { r in r.extraAfterSeconds = 2520 },
            F.workday("2026-10-13") { r in r.flags = [.noShow]; r.deltaSeconds = -30_600 },
        ]
        let list = items(store, results, exports: ["2026-09"])
        XCTAssertEqual(list.map(\.key), [
            "timer:\(timer.id.uuidString):1",   // now (18:00)
            "exit:\(last.id.uuidString)",       // 17:42
            "gap:\(a.id.uuidString)",           // 11:30
            "noshow:2026-10-13",                // 10-13 15:30
            "stale:\(stale.id.uuidString)",     // 10-12 07:00
            "export:2026-09",                   // 10-01 00:00
        ])
        XCTAssertEqual(list.map(\.occurredAt), list.map(\.occurredAt).sorted(by: >))
    }

    func testTiesAreOrderedByKeyForDeterminism() {
        var store = F.store()
        let e1 = F.exit(F.plantA, "2026-10-14 17:42", id: UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000000")!)
        let e2 = F.exit(F.plantB, "2026-10-14 17:42", id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000000")!)
        store.locationEvents = [e2, e1]
        XCTAssertEqual(items(store).map(\.subjectID), [e1.id, e2.id])
    }

    func testFormattingUsesTheStoreTimeZone() {
        var store = F.store()
        store.settings.timeZoneIdentifier = "America/Los_Angeles"
        let s = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42")   // instants fixed in New York time
        store.presence = [s]
        let result = DayResult(day: F.day("2026-10-14"), kind: .workday, extraAfterSeconds: 2520)
        let list = items(store, [result], now: F.date("2026-10-14 18:00"))
        XCTAssertEqual(list.map(\.title), ["Left Plant A 2:42 PM"])
        XCTAssertEqual(list[0].day, F.day("2026-10-14"))
    }

    func testUnknownLocationNameFallsBack() {
        var store = F.store()
        let s = PresenceSession(locationID: F.unknownLocation, enteredAt: F.date("2026-10-14 07:02"), exitedAt: F.date("2026-10-14 17:42"))
        store.presence = [s]
        let list = items(store, [F.workday("2026-10-14") { r in r.extraAfterSeconds = 60 }])
        XCTAssertEqual(list.map(\.title), ["Left work 5:42 PM"])
    }

    // MARK: DST days

    func testTodayOrYesterdayAcrossFallBack() {
        var store = F.store()
        let secondOneThirty = PresenceSession(locationID: F.plantA, enteredAt: F.iso("2026-10-31T22:00:00-04:00"), exitedAt: F.iso("2026-11-01T01:30:00-05:00"))
        let saturday = PresenceSession(locationID: F.plantB, enteredAt: F.iso("2026-10-31T07:00:00-04:00"), exitedAt: F.iso("2026-10-31T17:00:00-04:00"))
        store.presence = [secondOneThirty, saturday]
        let results = [
            DayResult(day: F.day("2026-11-01"), kind: .workday, scheduledWindow: F.window("2026-11-01"), extraAfterSeconds: 600),
            DayResult(day: F.day("2026-10-31"), kind: .workday, scheduledWindow: F.window("2026-10-31"), extraAfterSeconds: 600),
        ]
        // Monday morning: Sunday is yesterday, Saturday is not.
        let list = only(.exit, in: items(store, results, now: F.iso("2026-11-02T10:00:00-05:00")))
        XCTAssertEqual(list.map(\.subjectID), [secondOneThirty.id])
        XCTAssertEqual(list[0].day, F.day("2026-11-01"))
        XCTAssertEqual(list[0].title, "Left Plant A 1:30 AM")
    }

    func testGapOnFallBackDayUsesRealSeconds() {
        var store = F.store()
        // Away from 01:00 EDT to 01:30 EST: the clock shows 30 minutes, 1h 30m really passed.
        let a = PresenceSession(locationID: F.plantA, enteredAt: F.iso("2026-10-31T22:00:00-04:00"), exitedAt: F.iso("2026-11-01T01:00:00-04:00"))
        let b = PresenceSession(locationID: F.plantA, enteredAt: F.iso("2026-11-01T01:30:00-05:00"), exitedAt: F.iso("2026-11-01T06:00:00-05:00"))
        store.presence = [a, b]
        let nightWindow = Interval(start: F.iso("2026-10-31T22:00:00-04:00").addingTimeInterval(3600), end: F.iso("2026-11-01T06:00:00-05:00"))
        let result = DayResult(day: F.day("2026-11-01"), kind: .workday, scheduledWindow: nightWindow)
        let list = only(.gap, in: items(store, [result], now: F.iso("2026-11-01T12:00:00-05:00")))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].defaultApplied, "Deducted 1h 30m")
        XCTAssertEqual(list[0].title, "Away 1:00 AM – 1:30 AM")
        XCTAssertEqual(list[0].day, F.day("2026-11-01"))
    }

    func testTodayOrYesterdayAcrossSpringForward() {
        var store = F.store()
        let s = PresenceSession(locationID: F.plantA, enteredAt: F.iso("2026-03-08T01:30:00-05:00"), exitedAt: F.iso("2026-03-08T03:30:00-04:00"))
        store.presence = [s]
        let result = DayResult(day: F.day("2026-03-08"), kind: .workday, scheduledWindow: F.window("2026-03-08"), extraAfterSeconds: 600)
        let list = only(.exit, in: items(store, [result], now: F.iso("2026-03-09T10:00:00-04:00")))
        XCTAssertEqual(list.map(\.title), ["Left Plant A 3:30 AM"])
        XCTAssertEqual(only(.exit, in: items(store, [result], now: F.iso("2026-03-10T10:00:00-04:00"))), [])
    }

    func testEarlyItemOnSpringForwardDay() {
        var result = DayResult(day: F.day("2026-03-08"), kind: .workday, scheduledWindow: F.window("2026-03-08"))
        result.flags = [.earlyArrivalUncounted]
        result.extraBeforeSeconds = 1800
        result.firstIn = F.iso("2026-03-08T06:30:00-04:00")
        let list = items(F.store(), [result], now: F.iso("2026-03-08T18:00:00-04:00"))
        XCTAssertEqual(list.map(\.key), ["early:2026-03-08"])
        XCTAssertEqual(list[0].title, "Arrived early Sun Mar 8")
        XCTAssertEqual(list[0].detail, "In at 6:30 AM · 30m before 7:00 AM")
    }
}
