import XCTest
import OTModels
@testable import OTTracking

final class ManualTimerTests: XCTestCase {
    typealias F = Fixture

    // MARK: start

    func testStartCreatesRunningSession() throws {
        var store = F.store()
        let at = F.date("2026-10-14 19:00")
        let s = try ManualTimer.start(store: &store, category: "After hours", note: "emails", countsAs: .extra, at: at)

        XCTAssertEqual(store.manual, [s])
        XCTAssertEqual(s.category, "After hours")
        XCTAssertEqual(s.note, "emails")
        XCTAssertEqual(s.countsAs, .extra)
        XCTAssertEqual(s.segments, [ManualSegment(start: at, end: nil)])
        XCTAssertEqual(s.createdAt, at)
        XCTAssertFalse(s.isStopped)
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(store.activeManualSession?.id, s.id)
        XCTAssertEqual(s.activeSeconds(now: at.addingTimeInterval(90)), 90)
    }

    func testStartDefaultsAndRegular() throws {
        var store = F.store()
        let s = try ManualTimer.start(store: &store, category: "Home work", countsAs: .regular, at: F.date("2026-10-14 09:00"))
        XCTAssertEqual(s.note, "")
        XCTAssertEqual(s.countsAs, .regular)
    }

    func testStartWhileRunningThrowsAlreadyActive() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        assertThrows(.alreadyActive) { try ManualTimer.start(store: &store, category: "Travel", at: F.date("2026-10-14 19:05")) }
        XCTAssertEqual(store.manual.count, 1)
    }

    func testStartWhilePausedThrowsAlreadyActive() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        assertThrows(.alreadyActive) { try ManualTimer.start(store: &store, category: "Travel", at: F.date("2026-10-14 19:35")) }
    }

    func testStartAfterStopSucceeds() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.stop(store: &store, at: F.date("2026-10-14 20:00"))
        let second = try ManualTimer.start(store: &store, category: "Travel", at: F.date("2026-10-14 21:00"))
        XCTAssertEqual(store.manual.count, 2)
        XCTAssertEqual(store.activeManualSession?.id, second.id)
    }

    // MARK: pause

    func testPauseClosesOpenSegment() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        let s = try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        XCTAssertEqual(s.state, .paused)
        XCTAssertEqual(s.segments, [ManualSegment(start: F.date("2026-10-14 19:00"), end: F.date("2026-10-14 19:30"))])
        XCTAssertEqual(store.manual[0], s)
        XCTAssertNotNil(store.activeManualSession, "paused is still active")
    }

    func testPauseWhenPausedThrowsNotRunning() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        assertThrows(.notRunning) { try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:40")) }
        XCTAssertEqual(store.manual[0].segments.count, 1)
    }

    func testPauseWithNothingActiveThrowsNotRunning() {
        var store = F.store()
        assertThrows(.notRunning) { try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:40")) }
        store.manual = [ManualSession.block(category: "Travel", start: F.date("2026-10-13 08:00"), end: F.date("2026-10-13 09:00"), createdAt: F.date("2026-10-13 09:00"))]
        assertThrows(.notRunning) { try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:40")) }
    }

    func testPauseClampsToSegmentStart() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        let s = try ManualTimer.pause(store: &store, at: F.date("2026-10-14 18:00"))
        XCTAssertEqual(s.segments[0].end, F.date("2026-10-14 19:00"))
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-14 23:00")), 0)
    }

    // MARK: resume

    func testResumeAppendsOpenSegment() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        let s = try ManualTimer.resume(store: &store, at: F.date("2026-10-14 19:45"))
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(s.segments.count, 2)
        XCTAssertEqual(s.segments[1], ManualSegment(start: F.date("2026-10-14 19:45"), end: nil))
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-14 20:00")), 45 * 60)
    }

    func testResumeWhenRunningThrowsNotPaused() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        assertThrows(.notPaused) { try ManualTimer.resume(store: &store, at: F.date("2026-10-14 19:30")) }
        XCTAssertEqual(store.manual[0].segments.count, 1)
    }

    func testResumeWithNothingActiveThrowsNotPaused() {
        var store = F.store()
        assertThrows(.notPaused) { try ManualTimer.resume(store: &store, at: F.date("2026-10-14 19:30")) }
    }

    func testResumeClampsToPreviousSegmentEnd() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        let s = try ManualTimer.resume(store: &store, at: F.date("2026-10-14 19:10"))
        XCTAssertEqual(s.segments[1].start, F.date("2026-10-14 19:30"))
    }

    func testResumeOnSessionWithNoSegmentsStartsAtGivenInstant() throws {
        var store = F.store()
        store.manual = [ManualSession(category: "Other", segments: [], isStopped: false, createdAt: F.date("2026-10-14 19:00"))]
        XCTAssertEqual(store.manual[0].state, .paused)
        let s = try ManualTimer.resume(store: &store, at: F.date("2026-10-14 19:05"))
        XCTAssertEqual(s.segments, [ManualSegment(start: F.date("2026-10-14 19:05"), end: nil)])
    }

    // MARK: stop

    func testStopWhenRunningClosesSegmentAndStops() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        let s = try ManualTimer.stop(store: &store, at: F.date("2026-10-14 20:15"))
        XCTAssertTrue(s.isStopped)
        XCTAssertEqual(s.state, .stopped)
        XCTAssertEqual(s.segments, [ManualSegment(start: F.date("2026-10-14 19:00"), end: F.date("2026-10-14 20:15"))])
        XCTAssertEqual(s.endedAt, F.date("2026-10-14 20:15"))
        XCTAssertNil(store.activeManualSession)
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-15 09:00")), 75 * 60)
    }

    func testStopWhenPausedKeepsSegmentsAndStops() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        let s = try ManualTimer.stop(store: &store, at: F.date("2026-10-14 21:00"))
        XCTAssertTrue(s.isStopped)
        XCTAssertEqual(s.segments.count, 1)
        XCTAssertEqual(s.segments[0].end, F.date("2026-10-14 19:30"), "stop while paused does not extend the last segment")
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-15 09:00")), 30 * 60)
    }

    func testStopWithNothingActiveThrowsNothingActive() {
        var store = F.store()
        assertThrows(.nothingActive) { try ManualTimer.stop(store: &store, at: F.date("2026-10-14 21:00")) }
    }

    func testStopClampsToSegmentStart() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        let s = try ManualTimer.stop(store: &store, at: F.date("2026-10-14 18:30"))
        XCTAssertEqual(s.segments[0].end, F.date("2026-10-14 19:00"))
        XCTAssertTrue(s.isStopped)
    }

    func testStopOnlyAffectsTheActiveSession() throws {
        var store = F.store()
        let old = ManualSession.block(category: "Travel", start: F.date("2026-10-13 08:00"), end: F.date("2026-10-13 09:00"), createdAt: F.date("2026-10-13 09:00"))
        store.manual = [old]
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.stop(store: &store, at: F.date("2026-10-14 20:00"))
        XCTAssertEqual(store.manual[0], old)
        XCTAssertTrue(store.manual[1].isStopped)
    }

    // MARK: Full cycle

    func testPausedTimeNeverCounts() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        try ManualTimer.resume(store: &store, at: F.date("2026-10-14 20:30"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 20:45"))
        try ManualTimer.resume(store: &store, at: F.date("2026-10-14 21:00"))
        let s = try ManualTimer.stop(store: &store, at: F.date("2026-10-14 21:10"))
        XCTAssertEqual(s.segments.count, 3)
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-15 00:00")), (30 + 15 + 10) * 60)
    }

    func testTimerAcrossFallBackCountsRealSeconds() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "After hours", at: F.iso("2026-11-01T01:30:00-04:00"))
        let s = try ManualTimer.stop(store: &store, at: F.iso("2026-11-01T01:30:00-05:00"))
        XCTAssertEqual(s.activeSeconds(now: F.iso("2026-11-02T00:00:00-05:00")), 3600)
    }

    func testTimerAcrossSpringForwardCountsRealSeconds() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "After hours", at: F.iso("2026-03-08T01:45:00-05:00"))
        let s = try ManualTimer.stop(store: &store, at: F.iso("2026-03-08T03:15:00-04:00"))
        XCTAssertEqual(s.activeSeconds(now: F.iso("2026-03-09T00:00:00-04:00")), 1800)
    }

    func testTimerAcrossMidnight() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "After hours", at: F.date("2026-10-14 23:30"))
        let s = try ManualTimer.stop(store: &store, at: F.date("2026-10-15 00:30"))
        XCTAssertEqual(s.activeSeconds(now: F.date("2026-10-15 09:00")), 3600)
    }

    // MARK: discard

    func testDiscardRemovesActiveSession() throws {
        var store = F.store()
        let old = ManualSession.block(category: "Travel", start: F.date("2026-10-13 08:00"), end: F.date("2026-10-13 09:00"), createdAt: F.date("2026-10-13 09:00"))
        store.manual = [old]
        let running = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        let removed = try ManualTimer.discard(store: &store)
        XCTAssertEqual(removed.id, running.id)
        XCTAssertEqual(store.manual, [old])
        XCTAssertNil(store.activeManualSession)
    }

    func testDiscardPausedSession() throws {
        var store = F.store()
        try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        try ManualTimer.pause(store: &store, at: F.date("2026-10-14 19:30"))
        try ManualTimer.discard(store: &store)
        XCTAssertTrue(store.manual.isEmpty)
    }

    func testDiscardWithNothingActiveThrows() {
        var store = F.store()
        assertThrows(.nothingActive) { try ManualTimer.discard(store: &store) }
    }

    // MARK: addBlock

    func testAddBlockCreatesStoppedSession() {
        var store = F.store()
        let b = ManualTimer.addBlock(store: &store, category: "Home work", note: "slides", countsAs: .regular,
                                     start: F.date("2026-10-14 09:00"), end: F.date("2026-10-14 12:00"), createdAt: F.date("2026-10-14 21:00"))
        XCTAssertEqual(store.manual, [b])
        XCTAssertTrue(b.isStopped)
        XCTAssertEqual(b.state, .stopped)
        XCTAssertEqual(b.countsAs, .regular)
        XCTAssertEqual(b.note, "slides")
        XCTAssertEqual(b.createdAt, F.date("2026-10-14 21:00"))
        XCTAssertEqual(b.segments, [ManualSegment(start: F.date("2026-10-14 09:00"), end: F.date("2026-10-14 12:00"))])
        XCTAssertEqual(b.activeSeconds(now: F.date("2026-10-15 00:00")), 3 * 3600)
        XCTAssertNil(store.activeManualSession)
    }

    func testAddBlockClampsEndToStart() {
        var store = F.store()
        let b = ManualTimer.addBlock(store: &store, category: "Other", start: F.date("2026-10-14 12:00"), end: F.date("2026-10-14 09:00"), createdAt: F.date("2026-10-14 21:00"))
        XCTAssertEqual(b.segments[0].end, F.date("2026-10-14 12:00"))
        XCTAssertEqual(b.activeSeconds(now: F.date("2026-10-15 00:00")), 0)
    }

    func testAddBlockDoesNotDisturbRunningTimer() throws {
        var store = F.store()
        let running = try ManualTimer.start(store: &store, category: "Home work", at: F.date("2026-10-14 19:00"))
        ManualTimer.addBlock(store: &store, category: "Travel", start: F.date("2026-10-13 08:00"), end: F.date("2026-10-13 09:00"), createdAt: F.date("2026-10-14 19:30"))
        XCTAssertEqual(store.manual.count, 2)
        XCTAssertEqual(store.activeManualSession?.id, running.id)
        XCTAssertEqual(store.activeManualSession?.state, .running)
    }
}
