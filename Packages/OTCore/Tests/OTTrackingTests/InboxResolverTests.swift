import XCTest
import OTModels
@testable import OTTracking

final class InboxResolverTests: XCTestCase {
    typealias F = Fixture

    let now = Fixture.date("2026-10-14 18:00")
    let day = Fixture.day("2026-10-14")

    func item(_ key: String, kind: InboxKind = .gap, day: DayKey? = nil, subject: UUID? = nil, actions: [InboxAction] = []) -> InboxItem {
        InboxItem(key: key, kind: kind, day: day ?? self.day, occurredAt: now, title: "", detail: "", actions: actions, subjectID: subject)
    }

    // MARK: Gap decisions

    func testMarkGapWorkAndPersonalSetDecisionOnSubject() {
        var store = F.store()
        let a = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")
        let b = F.session(F.plantA, "2026-10-14 12:40", "2026-10-14 15:30")
        store.presence = [a, b]
        let gap = item("gap:\(a.id.uuidString)", subject: a.id)

        XCTAssertEqual(InboxResolver.apply(.markGapWork, item: gap, store: &store, now: now), .applied)
        XCTAssertEqual(store.presenceSession(id: a.id)?.followingGapIsWork, true)
        XCTAssertNil(store.presenceSession(id: b.id)?.followingGapIsWork)
        XCTAssertEqual(InboxEngine.items(store: store, dayResults: [F.workday("2026-10-14")], now: now), [], "resolved items disappear")

        XCTAssertEqual(InboxResolver.apply(.markGapPersonal, item: gap, store: &store, now: now), .applied)
        XCTAssertEqual(store.presenceSession(id: a.id)?.followingGapIsWork, false)
        XCTAssertTrue(store.dismissedInboxKeys.isEmpty, "a fact changed, no dismissal needed")
    }

    func testGapDecisionWithoutSubjectIsNotApplicable() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 11:30")]
        let before = store
        XCTAssertEqual(InboxResolver.apply(.markGapWork, item: item("gap:x"), store: &store, now: now), .notApplicable)
        XCTAssertEqual(InboxResolver.apply(.markGapPersonal, item: item("gap:x", subject: UUID()), store: &store, now: now), .notApplicable)
        XCTAssertEqual(store, before)
    }

    // MARK: Dismissals

    func testEveryDismissalActionOnlyRecordsTheKey() {
        let dismissals: [InboxAction] = [.keepDeficit, .confirm, .dontCountEarlyArrival, .stillWorking, .ignore, .dismiss]
        for (i, action) in dismissals.enumerated() {
            var store = F.store()
            store.presence = [F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42")]
            let before = store
            XCTAssertTrue(action.isDismissal)
            let key = "k\(i)"
            XCTAssertEqual(InboxResolver.apply(action, item: item(key, subject: store.presence[0].id), store: &store, now: now), .applied, "\(action)")
            XCTAssertEqual(store.dismissedInboxKeys, [key], "\(action)")
            store.dismissedInboxKeys = []
            XCTAssertEqual(store, before, "\(action) must not change facts")
        }
    }

    func testConfirmHidesExitItem() {
        var store = F.store()
        let s = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42")
        store.presence = [s]
        let results = [F.workday("2026-10-14") { r in r.extraAfterSeconds = 2520 }]
        let listed = InboxEngine.items(store: store, dayResults: results, now: now)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(InboxResolver.apply(.confirm, item: listed[0], store: &store, now: now), .applied)
        XCTAssertEqual(InboxEngine.items(store: store, dayResults: results, now: now), [])
    }

    // MARK: Day overrides

    func testExcuseDayCreatesOverride() {
        var store = F.store()
        XCTAssertEqual(InboxResolver.apply(.excuseDay, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now), .applied)
        XCTAssertEqual(store.overrides.count, 1)
        XCTAssertEqual(store.override(for: day)?.excused, true)
        XCTAssertEqual(store.override(for: day)?.countEarlyArrival, false)
        XCTAssertEqual(store.override(for: day)?.kind, DayOverrideKind.none)
        XCTAssertTrue(store.dismissedInboxKeys.isEmpty)
    }

    func testExcuseDayKeepsExistingOverrideFields() {
        var store = F.store()
        let custom = WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))
        store.setOverride(DayOverride(day: day, kind: .schedule(custom), note: "late start"))
        XCTAssertEqual(InboxResolver.apply(.excuseDay, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now), .applied)
        XCTAssertEqual(store.overrides.count, 1)
        XCTAssertEqual(store.override(for: day)?.kind, .schedule(custom))
        XCTAssertEqual(store.override(for: day)?.note, "late start")
        XCTAssertEqual(store.override(for: day)?.excused, true)
    }

    func testCountEarlyArrivalSetsOverrideAndDismisses() {
        var store = F.store()
        let early = item("early:2026-10-14", kind: .earlyArrival)
        XCTAssertEqual(InboxResolver.apply(.countEarlyArrival, item: early, store: &store, now: now), .applied)
        XCTAssertEqual(store.override(for: day)?.countEarlyArrival, true)
        XCTAssertEqual(store.override(for: day)?.excused, false)
        XCTAssertEqual(store.dismissedInboxKeys, ["early:2026-10-14"])
    }

    // MARK: Remote day

    func testMarkRemoteDayNeedsWindow() {
        var store = F.store()
        let before = store
        XCTAssertEqual(InboxResolver.apply(.markRemoteDay, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now), .needsInput(.manualForm))
        let empty = Interval(start: F.date("2026-10-14 07:00"), end: F.date("2026-10-14 07:00"))
        XCTAssertEqual(InboxResolver.apply(.markRemoteDay, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now, window: empty), .needsInput(.manualForm))
        XCTAssertEqual(store, before)
    }

    func testMarkRemoteDayCreatesRegularBlock() {
        var store = F.store()
        let window = F.window("2026-10-14")
        XCTAssertEqual(InboxResolver.apply(.markRemoteDay, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now, window: window), .applied)
        XCTAssertEqual(store.manual.count, 1)
        let m = store.manual[0]
        XCTAssertEqual(m.category, "Remote day")
        XCTAssertEqual(m.countsAs, .regular)
        XCTAssertTrue(m.isStopped)
        XCTAssertEqual(m.segments, [ManualSegment(start: window.start, end: window.end)])
        XCTAssertEqual(m.createdAt, now)
        XCTAssertNil(store.activeManualSession)
    }

    // MARK: Timer

    func testStopTimerNowStopsAtNow() throws {
        var store = F.store()
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        let timer = item("timer:\(m.id.uuidString):2", kind: .timer, subject: m.id)
        XCTAssertEqual(InboxResolver.apply(.stopTimerNow, item: timer, store: &store, now: now), .applied)
        XCTAssertTrue(store.manual[0].isStopped)
        XCTAssertEqual(store.manual[0].segments[0].end, now)
        XCTAssertEqual(InboxEngine.items(store: store, dayResults: [], now: now), [])
    }

    func testStopTimerNowWithoutActiveOrWrongSubjectIsNotApplicable() throws {
        var store = F.store()
        XCTAssertEqual(InboxResolver.apply(.stopTimerNow, item: item("timer:x:1", kind: .timer), store: &store, now: now), .notApplicable)
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        XCTAssertEqual(InboxResolver.apply(.stopTimerNow, item: item("timer:y:1", kind: .timer, subject: UUID()), store: &store, now: now), .notApplicable)
        XCTAssertFalse(store.manual[0].isStopped)
        XCTAssertEqual(InboxResolver.apply(.stopTimerNow, item: item("timer:\(m.id.uuidString):1", kind: .timer), store: &store, now: now), .applied, "no subject means the active one")
        XCTAssertTrue(store.manual[0].isStopped)
    }

    func testSetTimerStopNeedsDateThenStopsThere() throws {
        var store = F.store()
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        let timer = item("timer:\(m.id.uuidString):1", kind: .timer, subject: m.id)
        XCTAssertEqual(InboxResolver.apply(.setTimerStop, item: timer, store: &store, now: now), .needsInput(.dateTime))
        XCTAssertFalse(store.manual[0].isStopped)
        XCTAssertEqual(InboxResolver.apply(.setTimerStop, item: timer, store: &store, now: now, date: F.date("2026-10-14 13:00")), .applied)
        XCTAssertTrue(store.manual[0].isStopped)
        XCTAssertEqual(store.manual[0].segments[0].end, F.date("2026-10-14 13:00"))
    }

    func testSetTimerStopClampsToSegmentStart() throws {
        var store = F.store()
        let m = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 09:00"))
        let timer = item("timer:\(m.id.uuidString):1", kind: .timer, subject: m.id)
        XCTAssertEqual(InboxResolver.apply(.setTimerStop, item: timer, store: &store, now: now, date: F.date("2026-10-14 08:00")), .applied)
        XCTAssertEqual(store.manual[0].segments[0].end, F.date("2026-10-14 09:00"))
    }

    // MARK: Presence edits

    func testSetExitTimeNeedsDateThenSetsIt() {
        var store = F.store()
        let s = F.session(F.plantA, "2026-10-13 07:00", nil)
        store.presence = [s]
        let stale = item("stale:\(s.id.uuidString)", kind: .staleOpen, subject: s.id)
        XCTAssertEqual(InboxResolver.apply(.setExitTime, item: stale, store: &store, now: now), .needsInput(.dateTime))
        XCTAssertNil(store.presence[0].exitedAt)
        XCTAssertEqual(InboxResolver.apply(.setExitTime, item: stale, store: &store, now: now, date: F.date("2026-10-13 15:30")), .applied)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-13 15:30"))
        XCTAssertEqual(InboxEngine.items(store: store, dayResults: [], now: now), [])
    }

    func testSetExitTimeClampsAndChecksSubject() {
        var store = F.store()
        let s = F.session(F.plantA, "2026-10-13 07:00", nil)
        store.presence = [s]
        XCTAssertEqual(InboxResolver.apply(.setExitTime, item: item("stale:\(s.id.uuidString)", kind: .staleOpen, subject: s.id), store: &store, now: now, date: F.date("2026-10-13 06:00")), .applied)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-13 07:00"))
        XCTAssertEqual(InboxResolver.apply(.setExitTime, item: item("stale:x", kind: .staleOpen, subject: UUID()), store: &store, now: now, date: now), .notApplicable)
        XCTAssertEqual(InboxResolver.apply(.setExitTime, item: item("stale:x", kind: .staleOpen), store: &store, now: now, date: now), .notApplicable)
    }

    func testRemoveAndDeleteSessionRemoveTheSubject() {
        for action in [InboxAction.removeSession, .deleteSession] {
            var store = F.store()
            let keep = F.session(F.plantB, "2026-10-13 07:00", "2026-10-13 15:30")
            let s = F.session(F.plantA, "2026-10-14 07:02", "2026-10-14 17:42")
            store.presence = [keep, s]
            XCTAssertTrue(action.isDestructive)
            XCTAssertEqual(InboxResolver.apply(action, item: item("exit:\(s.id.uuidString)", kind: .exit, subject: s.id), store: &store, now: now), .applied)
            XCTAssertEqual(store.presence, [keep])
            XCTAssertEqual(InboxResolver.apply(action, item: item("exit:\(s.id.uuidString)", kind: .exit, subject: s.id), store: &store, now: now), .notApplicable, "already gone")
            XCTAssertEqual(InboxResolver.apply(action, item: item("exit:x", kind: .exit), store: &store, now: now), .notApplicable)
            XCTAssertEqual(store.presence, [keep])
        }
    }

    // MARK: Orphan exit

    func testSetArrivalTimeNeedsDateThenCreatesSessionAndDismisses() {
        var store = F.store()
        let e = F.exit(F.plantB, "2026-10-14 17:42")
        store.locationEvents = [e]
        let orphan = InboxEngine.items(store: store, dayResults: [], now: now)
        XCTAssertEqual(orphan.count, 1)
        XCTAssertEqual(InboxResolver.apply(.setArrivalTime, item: orphan[0], store: &store, now: now), .needsInput(.dateTime))
        XCTAssertTrue(store.presence.isEmpty)

        XCTAssertEqual(InboxResolver.apply(.setArrivalTime, item: orphan[0], store: &store, now: now, date: F.date("2026-10-14 07:05")), .applied)
        XCTAssertEqual(store.presence.count, 1)
        let s = store.presence[0]
        XCTAssertEqual(s.locationID, F.plantB)
        XCTAssertEqual(s.enteredAt, F.date("2026-10-14 07:05"))
        XCTAssertEqual(s.exitedAt, F.date("2026-10-14 17:42"))
        XCTAssertEqual(s.source, .manual)
        XCTAssertEqual(s.note, "Added from missed arrival")
        XCTAssertNil(s.followingGapIsWork)
        XCTAssertEqual(store.dismissedInboxKeys, [orphan[0].key])
        XCTAssertEqual(store.locationEvents, [e], "the audit log is not touched")
        XCTAssertEqual(InboxEngine.items(store: store, dayResults: [], now: now), [])
    }

    func testSetArrivalTimeClampsArrivalToTheExit() {
        var store = F.store()
        let e = F.exit(F.plantA, "2026-10-14 17:42")
        store.locationEvents = [e]
        let orphan = item("orphanExit:\(e.id.uuidString)", kind: .orphanExit, subject: e.id)
        XCTAssertEqual(InboxResolver.apply(.setArrivalTime, item: orphan, store: &store, now: now, date: F.date("2026-10-14 18:00")), .applied)
        XCTAssertEqual(store.presence[0].enteredAt, F.date("2026-10-14 17:42"))
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 17:42"))
    }

    func testSetArrivalTimeWithoutEventIsNotApplicable() {
        var store = F.store()
        XCTAssertEqual(InboxResolver.apply(.setArrivalTime, item: item("orphanExit:x", kind: .orphanExit, subject: UUID()), store: &store, now: now, date: now), .notApplicable)
        XCTAssertEqual(InboxResolver.apply(.setArrivalTime, item: item("orphanExit:x", kind: .orphanExit), store: &store, now: now, date: now), .notApplicable)
        XCTAssertTrue(store.presence.isEmpty)
        XCTAssertTrue(store.dismissedInboxKeys.isEmpty)
    }

    // MARK: Time off

    func testAddTimeOffNeedsSecondsThenCreatesEntry() {
        var store = F.store()
        let noShow = item("noshow:2026-10-13", kind: .noShow, day: F.day("2026-10-13"))
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .pto), item: noShow, store: &store, now: now), .needsInput(.timeOffForm(.pto)))
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .personal), item: noShow, store: &store, now: now, seconds: 0), .needsInput(.timeOffForm(.personal)))
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .flex), item: noShow, store: &store, now: now, seconds: -5), .needsInput(.timeOffForm(.flex)))
        XCTAssertTrue(store.timeOff.isEmpty)

        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .pto), item: noShow, store: &store, now: now, seconds: 30_600), .applied)
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .personal), item: noShow, store: &store, now: now, seconds: 3600), .applied)
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .flex), item: noShow, store: &store, now: now, seconds: 1800), .applied)
        XCTAssertEqual(store.timeOff.count, 3)
        XCTAssertEqual(store.timeOff.map(\.typeID), [TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID])
        XCTAssertEqual(store.timeOff.map(\.seconds), [30_600, 3600, 1800])
        XCTAssertTrue(store.timeOff.allSatisfy { $0.day == F.day("2026-10-13") })
        XCTAssertTrue(store.dismissedInboxKeys.isEmpty)
    }

    func testAddOtherTimeOffAlwaysNeedsTheForm() {
        var store = F.store()
        let noShow = item("noshow:2026-10-13", kind: .noShow, day: F.day("2026-10-13"))
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .other), item: noShow, store: &store, now: now, seconds: 3600), .needsInput(.timeOffForm(.other)))
        XCTAssertTrue(store.timeOff.isEmpty)
    }

    func testAddTimeOffRestoresMissingBuiltInType() {
        var store = F.store()
        store.timeOffTypes.removeAll { $0.id == TimeOffType.personalID }
        XCTAssertNil(store.timeOffType(id: TimeOffType.personalID))
        XCTAssertEqual(InboxResolver.apply(.addTimeOff(kind: .personal), item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now, seconds: 3600), .applied)
        XCTAssertEqual(store.timeOffType(id: TimeOffType.personalID), TimeOffType.personal)
        XCTAssertEqual(store.timeOff.count, 1)
    }

    // MARK: UI-only and export actions

    func testActionsThatNeedTheUIReportTheirInput() {
        var store = F.store()
        let before = store
        XCTAssertEqual(InboxResolver.apply(.enterHours, item: item("noshow:2026-10-14", kind: .noShow), store: &store, now: now), .needsInput(.manualForm))
        XCTAssertEqual(InboxResolver.apply(.adjustSession, item: item("exit:x", kind: .exit, subject: UUID()), store: &store, now: now), .needsInput(.sessionEditor))
        XCTAssertEqual(InboxResolver.apply(.emailExport, item: item("export:2026-09", kind: .monthlyExport), store: &store, now: now), .notApplicable)
        XCTAssertEqual(InboxResolver.apply(.shareExport, item: item("export:2026-09", kind: .monthlyExport), store: &store, now: now), .notApplicable)
        XCTAssertEqual(store, before)
    }

    func testInputKindAndOutcomeEquality() {
        XCTAssertEqual(ResolutionOutcome.needsInput(.timeOffForm(.pto)), .needsInput(.timeOffForm(.pto)))
        XCTAssertNotEqual(ResolutionOutcome.needsInput(.timeOffForm(.pto)), .needsInput(.timeOffForm(.flex)))
        XCTAssertNotEqual(ResolutionOutcome.applied, .notApplicable)
        XCTAssertNotEqual(InputKind.dateTime, .duration)
    }
}
