import XCTest
import OTModels
@testable import OTTracking

final class GeofenceInterpreterTests: XCTestCase {
    typealias F = Fixture

    // MARK: Table rows

    func testEnterWithNothingOpenOpensSessionAndLogsEvent() {
        var store = F.store()
        let e = F.enter(F.plantA, "2026-10-14 07:02")
        let out = GeofenceInterpreter.apply(e, to: &store)

        XCTAssertEqual(store.locationEvents, [e])
        XCTAssertEqual(store.presence.count, 1)
        let s = store.presence[0]
        XCTAssertEqual(s.locationID, F.plantA)
        XCTAssertEqual(s.enteredAt, F.date("2026-10-14 07:02"))
        XCTAssertNil(s.exitedAt)
        XCTAssertEqual(s.source, .geofence)
        XCTAssertNil(s.followingGapIsWork)
        XCTAssertEqual(out.opened, s)
        XCTAssertNil(out.closed)
        XCTAssertFalse(out.reopened)
        XCTAssertFalse(out.orphanExit)
        XCTAssertFalse(out.ignored)
        XCTAssertTrue(out.changedPresence)
        XCTAssertEqual(out.event, e)
    }

    func testOpenedSessionCarriesEventSource() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02", source: .manual), to: &store)
        XCTAssertEqual(store.presence[0].source, .manual)

        var imported = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantB, "2026-10-14 07:02", source: .imported), to: &imported)
        XCTAssertEqual(imported.presence[0].source, .imported)
    }

    func testEnterWhileOpenAtSameLocationIsIgnoredButLogged() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        let before = store.presence
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 09:00"), to: &store)

        XCTAssertTrue(out.ignored)
        XCTAssertNil(out.opened)
        XCTAssertNil(out.closed)
        XCTAssertFalse(out.changedPresence)
        XCTAssertEqual(store.presence, before)
        XCTAssertEqual(store.locationEvents.count, 2)
    }

    func testEnterWhileOpenElsewhereClosesThatAndOpensNew() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantB, "2026-10-14 10:15"), to: &store)

        XCTAssertEqual(store.presence.count, 2)
        XCTAssertEqual(store.presence[0].locationID, F.plantA)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 10:15"))
        XCTAssertEqual(store.presence[1].locationID, F.plantB)
        XCTAssertEqual(store.presence[1].enteredAt, F.date("2026-10-14 10:15"))
        XCTAssertNil(store.presence[1].exitedAt)
        XCTAssertEqual(out.closed, store.presence[0])
        XCTAssertEqual(out.opened, store.presence[1])
        XCTAssertFalse(out.ignored)
        XCTAssertFalse(out.reopened)
    }

    func testExitWhileOpenAtSameLocationCloses() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:42"), to: &store)

        XCTAssertEqual(store.presence.count, 1)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 17:42"))
        XCTAssertEqual(out.closed, store.presence[0])
        XCTAssertNil(out.opened)
        XCTAssertFalse(out.orphanExit)
        XCTAssertNil(store.openPresenceSession)
    }

    func testExitWhileOpenElsewhereClosesThatSession() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        let out = GeofenceInterpreter.apply(F.exit(F.plantB, "2026-10-14 12:00"), to: &store)

        XCTAssertEqual(store.presence.count, 1)
        XCTAssertEqual(store.presence[0].locationID, F.plantA)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 12:00"))
        XCTAssertEqual(out.closed?.id, store.presence[0].id)
        XCTAssertFalse(out.orphanExit)
        XCTAssertFalse(out.ignored)
    }

    func testExitWithNothingOpenIsOrphanButLogged() {
        var store = F.store()
        let e = F.exit(F.plantA, "2026-10-14 17:42")
        let out = GeofenceInterpreter.apply(e, to: &store)

        XCTAssertTrue(out.orphanExit)
        XCTAssertFalse(out.ignored)
        XCTAssertNil(out.closed)
        XCTAssertNil(out.opened)
        XCTAssertTrue(store.presence.isEmpty)
        XCTAssertEqual(store.locationEvents, [e])
    }

    func testExitAfterCloseIsOrphan() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:42"), to: &store)
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:50"), to: &store)
        XCTAssertTrue(out.orphanExit)
        XCTAssertEqual(store.presence.count, 1)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 17:42"))
    }

    func testUnknownLocationIsIgnoredButLogged() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        let before = store.presence

        let enter = F.enter(F.unknownLocation, "2026-10-14 08:00")
        let out1 = GeofenceInterpreter.apply(enter, to: &store)
        XCTAssertTrue(out1.ignored)
        XCTAssertFalse(out1.orphanExit)
        XCTAssertEqual(store.presence, before, "an unknown location must not close the open session")

        let exit = F.exit(F.unknownLocation, "2026-10-14 09:00")
        let out2 = GeofenceInterpreter.apply(exit, to: &store)
        XCTAssertTrue(out2.ignored)
        XCTAssertFalse(out2.orphanExit)
        XCTAssertEqual(store.presence, before)
        XCTAssertEqual(store.locationEvents.map(\.id), [store.locationEvents[0].id, enter.id, exit.id])
    }

    func testEmptyStoreUnknownLocationExitIsIgnoredNotOrphan() {
        var store = Store(settings: F.settings)
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 17:42"), to: &store)
        XCTAssertTrue(out.ignored)
        XCTAssertFalse(out.orphanExit)
        XCTAssertEqual(store.locationEvents.count, 1)
    }

    // MARK: Flap filter

    func testFlapReopensRecentlyClosedSession() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 12:00:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:02:59"), to: &store)

        XCTAssertTrue(out.reopened)
        XCTAssertEqual(store.presence.count, 1)
        XCTAssertNil(store.presence[0].exitedAt)
        XCTAssertEqual(store.presence[0].enteredAt, F.date("2026-10-14 07:02"))
        XCTAssertEqual(out.opened, store.presence[0])
        XCTAssertNil(out.closed)
        XCTAssertFalse(out.ignored)
        XCTAssertEqual(store.locationEvents.count, 3)
    }

    func testFlapBoundaryExactlyAtMergeMinutesOpensNewSession() {
        var store = F.store()
        XCTAssertEqual(store.settings.flapMergeMinutes, 3)
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 12:00:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:03:00"), to: &store)

        XCTAssertFalse(out.reopened)
        XCTAssertEqual(store.presence.count, 2)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 12:00:00"))
        XCTAssertEqual(store.presence[1].enteredAt, F.date("2026-10-14 12:03:00"))
        XCTAssertNil(store.presence[1].exitedAt)
    }

    func testFlapUsesMostRecentClosedSessionAtThatLocation() {
        var store = F.store()
        let old = F.session(F.plantA, "2026-10-13 07:00", "2026-10-13 15:30")
        let recent = F.session(F.plantA, "2026-10-14 07:00", "2026-10-14 12:00")
        store.presence = [recent, old]   // deliberately unordered
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:01"), to: &store)

        XCTAssertTrue(out.reopened)
        XCTAssertEqual(out.opened?.id, recent.id)
        XCTAssertNil(store.presenceSession(id: recent.id)?.exitedAt)
        XCTAssertEqual(store.presenceSession(id: old.id)?.exitedAt, old.exitedAt)
        XCTAssertEqual(store.presence.count, 2)
    }

    func testFlapDoesNotApplyToOtherLocation() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 12:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantB, "2026-10-14 12:01"), to: &store)

        XCTAssertFalse(out.reopened)
        XCTAssertEqual(store.presence.count, 2)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 12:00"))
        XCTAssertEqual(store.presence[1].locationID, F.plantB)
    }

    func testFlapIgnoresEventsOlderThanTheExit() {
        var store = F.store()
        store.presence = [F.session(F.plantA, "2026-10-13 07:00", "2026-10-13 17:42")]
        // A hand-entered arrival from before the recorded exit must not reopen yesterday.
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-13 17:41", source: .manual), to: &store)
        XCTAssertFalse(out.reopened)
        XCTAssertEqual(store.presence.count, 2)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-13 17:42"))
    }

    func testFlapDisabledWhenMergeMinutesIsZero() {
        var store = F.store()
        store.settings.flapMergeMinutes = 0
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 12:00:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:00:01"), to: &store)
        XCTAssertFalse(out.reopened)
        XCTAssertEqual(store.presence.count, 2)
    }

    func testFlapNotUsedWhenAnotherSessionIsOpen() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 12:00"), to: &store)
        GeofenceInterpreter.apply(F.enter(F.plantB, "2026-10-14 12:00:30"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:01"), to: &store)

        XCTAssertFalse(out.reopened)
        XCTAssertEqual(out.closed?.locationID, F.plantB)
        XCTAssertEqual(out.closed?.exitedAt, F.date("2026-10-14 12:01"))
        XCTAssertEqual(store.presence.count, 3)
        XCTAssertEqual(store.presence[2].locationID, F.plantA)
        XCTAssertEqual(store.presence[2].enteredAt, F.date("2026-10-14 12:01"))
    }

    // MARK: Clamping

    func testExitOlderThanEntryIsClampedToEntry() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 06:50"), to: &store)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 07:00"))
        XCTAssertEqual(out.closed?.exitedAt, F.date("2026-10-14 07:00"))
        XCTAssertEqual(store.presence[0].seconds(now: F.date("2026-10-14 18:00")), 0)
    }

    func testEnterElsewhereWithOlderEventClampsTheClosedSession() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.enter(F.plantB, "2026-10-14 06:50"), to: &store)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 07:00"))
        XCTAssertEqual(store.presence[1].enteredAt, F.date("2026-10-14 06:50"))
        XCTAssertEqual(out.closed?.exitedAt, F.date("2026-10-14 07:00"))
    }

    func testExitElsewhereWithOlderEventClamps() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:00"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantB, "2026-10-14 06:00"), to: &store)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 07:00"))
    }

    func testMultipleOpenSessionsClosesTheLatest() {
        var store = F.store()
        let older = F.session(F.plantA, "2026-10-13 07:00", nil)
        let newer = F.session(F.plantB, "2026-10-14 07:00", nil)
        store.presence = [older, newer]
        let out = GeofenceInterpreter.apply(F.exit(F.plantB, "2026-10-14 15:30"), to: &store)
        XCTAssertEqual(out.closed?.id, newer.id)
        XCTAssertEqual(store.presenceSession(id: newer.id)?.exitedAt, F.date("2026-10-14 15:30"))
        XCTAssertNil(store.presenceSession(id: older.id)?.exitedAt)
    }

    // MARK: DST and midnight

    func testSpringForwardSessionIsOneHourOfWallClockSkip() {
        // 2026-03-08: 01:30 EST → 03:30 EDT is one real hour.
        var store = F.store()
        GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .enter, at: F.iso("2026-03-08T01:30:00-05:00")), to: &store)
        GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .exit, at: F.iso("2026-03-08T03:30:00-04:00")), to: &store)
        XCTAssertEqual(store.presence[0].seconds(now: F.iso("2026-03-09T00:00:00-04:00")), 3600)
        XCTAssertEqual(DayKey(store.presence[0].enteredAt, calendar: F.calendar), F.day("2026-03-08"))
    }

    func testFallBackSessionAcrossRepeatedHour() {
        // 2026-11-01: 01:30 EDT → 01:30 EST is one real hour even though the clock shows the same time.
        var store = F.store()
        GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .enter, at: F.iso("2026-11-01T01:30:00-04:00")), to: &store)
        let out = GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .exit, at: F.iso("2026-11-01T01:30:00-05:00")), to: &store)
        XCTAssertEqual(out.closed?.exitedAt, F.iso("2026-11-01T01:30:00-05:00"))
        XCTAssertEqual(store.presence[0].seconds(now: F.iso("2026-11-02T00:00:00-05:00")), 3600)
        // Flap: an enter 2 minutes after the (EST) exit reopens; the EDT instant is an hour earlier and must not count as "after".
        let reopen = GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .enter, at: F.iso("2026-11-01T01:32:00-05:00")), to: &store)
        XCTAssertTrue(reopen.reopened)
    }

    func testFallBackFlapDoesNotTreatEarlierInstantAsAfterExit() {
        var store = F.store()
        store.presence = [PresenceSession(locationID: F.plantA, enteredAt: F.iso("2026-10-31T22:00:00-04:00"), exitedAt: F.iso("2026-11-01T01:30:00-05:00"))]
        // Same wall clock "01:29" but on the EDT side: 59 minutes BEFORE the exit instant.
        let out = GeofenceInterpreter.apply(LocationEvent(locationID: F.plantA, kind: .enter, at: F.iso("2026-11-01T01:29:00-04:00"), source: .manual), to: &store)
        XCTAssertFalse(out.reopened)
        XCTAssertEqual(store.presence.count, 2)
    }

    func testMidnightCrossingSessionIsKeptWhole() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 22:00"), to: &store)
        let out = GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-15 02:00"), to: &store)
        XCTAssertEqual(store.presence.count, 1)
        XCTAssertEqual(out.closed?.seconds(now: F.date("2026-10-15 12:00")), 4 * 3600)
        XCTAssertEqual(DayKey(store.presence[0].enteredAt, calendar: F.calendar), F.day("2026-10-14"))
        XCTAssertEqual(DayKey(store.presence[0].exitedAt ?? .distantPast, calendar: F.calendar), F.day("2026-10-15"))
    }

    func testFullDayWithLunchFlapProducesOneSession() {
        var store = F.store()
        let events = [
            F.enter(F.plantA, "2026-10-14 07:02"),
            F.exit(F.plantA, "2026-10-14 11:30:00"),
            F.enter(F.plantA, "2026-10-14 11:31:30"),   // geofence flap at the lot edge
            F.exit(F.plantA, "2026-10-14 17:42"),
        ]
        let outcomes = events.map { GeofenceInterpreter.apply($0, to: &store) }
        XCTAssertEqual(store.locationEvents, events)
        XCTAssertEqual(store.presence.count, 1)
        XCTAssertEqual(store.presence[0].enteredAt, F.date("2026-10-14 07:02"))
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 17:42"))
        XCTAssertEqual(outcomes.map(\.reopened), [false, false, true, false])
        XCTAssertEqual(outcomes.map { $0.closed != nil }, [false, true, false, true])
    }

    func testRealLunchBreakProducesTwoSessions() {
        var store = F.store()
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 07:02"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 11:30"), to: &store)
        GeofenceInterpreter.apply(F.enter(F.plantA, "2026-10-14 12:40"), to: &store)
        GeofenceInterpreter.apply(F.exit(F.plantA, "2026-10-14 15:30"), to: &store)
        XCTAssertEqual(store.presence.count, 2)
        XCTAssertEqual(store.presence[0].exitedAt, F.date("2026-10-14 11:30"))
        XCTAssertEqual(store.presence[1].enteredAt, F.date("2026-10-14 12:40"))
        XCTAssertEqual(store.presence[1].exitedAt, F.date("2026-10-14 15:30"))
        XCTAssertNil(store.presence[0].followingGapIsWork)
    }
}
