import XCTest
@testable import OTModels

final class PrimitivesTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func testDayKeyRoundTripAndOrdering() {
        let k = DayKey(iso: "2026-10-14")!
        XCTAssertEqual(k.isoString, "2026-10-14")
        XCTAssertEqual(k.weekday(in: cal), .wednesday)
        XCTAssertLessThan(k, k.adding(days: 1, calendar: cal))
        XCTAssertEqual(k.adding(days: 20, calendar: cal).isoString, "2026-11-03")
        XCTAssertEqual(k.daysUntil(k.adding(days: 20, calendar: cal), calendar: cal), 20)
        XCTAssertEqual(DayKey.days(from: k, through: k.adding(days: 2, calendar: cal), calendar: cal).count, 3)
    }

    func testDayKeyAcrossDST() {
        // US DST ends 2026-11-01 02:00 in New York.
        let k = DayKey(iso: "2026-10-31")!
        let next = k.adding(days: 1, calendar: cal)
        XCTAssertEqual(next.isoString, "2026-11-01")
        XCTAssertEqual(next.interval(in: cal).seconds, 25 * 3600)
        XCTAssertEqual(next.adding(days: 1, calendar: cal).isoString, "2026-11-02")
    }

    func testDayKeyCodable() throws {
        let k = DayKey(year: 2026, month: 1, day: 5)
        let data = try JSONEncoder().encode([k])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"2026-01-05\"]")
        XCTAssertEqual(try JSONDecoder().decode([DayKey].self, from: data), [k])
    }

    func testTimeOfDayParsing() {
        XCTAssertEqual(TimeOfDay(hhmm: "7:30")?.minutesFromMidnight, 450)
        XCTAssertEqual(TimeOfDay(hhmm: "07:30")?.minutesFromMidnight, 450)
        XCTAssertEqual(TimeOfDay(hhmm: "5pm")?.minutesFromMidnight, 17 * 60)
        XCTAssertEqual(TimeOfDay(hhmm: "12:15 am")?.minutesFromMidnight, 15)
        XCTAssertEqual(TimeOfDay(hhmm: "12 pm")?.minutesFromMidnight, 12 * 60)
        XCTAssertNil(TimeOfDay(hhmm: "25:00"))
        XCTAssertNil(TimeOfDay(hhmm: "abc"))
        XCTAssertEqual(TimeOfDay(hour: 15, minute: 5).hhmm, "15:05")
    }

    func testTimeOfDayOnDay() {
        let d = TimeOfDay(hour: 7, minute: 30).date(on: DayKey(iso: "2026-10-14")!, calendar: cal)
        let c = cal.dateComponents([.hour, .minute], from: d)
        XCTAssertEqual(c.hour, 7)
        XCTAssertEqual(c.minute, 30)
    }

    func testIntervalMergeAndClip() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = Interval(start: t0, end: t0.addingTimeInterval(3600))
        let b = Interval(start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(5400))
        let c = Interval(start: t0.addingTimeInterval(7200), end: t0.addingTimeInterval(7260))
        let merged = Interval.merged([c, b, a])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].seconds, 5400)
        XCTAssertEqual(Interval.totalSeconds([a, b, c]), 5460)
        let window = Interval(start: t0.addingTimeInterval(900), end: t0.addingTimeInterval(4500))
        XCTAssertEqual(Interval.seconds(of: [a, b], inside: window), 3600)
        XCTAssertNil(c.clipped(to: window))
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.hm(4320), "1h 12m")
        XCTAssertEqual(DurationFormat.hm(-2520), "-42m")
        XCTAssertEqual(DurationFormat.hm(0), "0m")
        XCTAssertEqual(DurationFormat.hm(3600, signed: true), "+1h")
        XCTAssertEqual(DurationFormat.clock(-2520), "-0:42")
        XCTAssertEqual(DurationFormat.clock(3900, signed: true), "+1:05")
        XCTAssertEqual(DurationFormat.clockWithSeconds(3661), "1:01:01")
        XCTAssertEqual(DurationFormat.hours(5400), 1.5)
    }

    func testStoreCodecRoundTripWithDefaults() throws {
        var s = Store()
        s.schedules = [ScheduleVersion.standardWeek(effectiveFrom: DayKey(iso: "2026-01-04")!)]
        s.locations = [WorkLocation(name: "Plant A", latitude: 1, longitude: 2, createdAt: Date(timeIntervalSince1970: 1_700_000_000))]
        s.presence = [PresenceSession(locationID: s.locations[0].id, enteredAt: Date(timeIntervalSince1970: 1_700_000_000), exitedAt: nil)]
        let data = try StoreCodec.encode(s)
        let back = try StoreCodec.decode(data)
        XCTAssertEqual(back, s)
        // Old JSON missing new keys still decodes.
        let minimal = try StoreCodec.decode(Data("{}".utf8))
        XCTAssertEqual(minimal.timeOffTypes.count, 3)
        XCTAssertEqual(minimal.settings.graceMinutes, 5)
    }

    func testScheduleLookup() {
        var s = Store()
        let v1 = ScheduleVersion.standardWeek(effectiveFrom: DayKey(iso: "2026-01-01")!)
        var v2 = ScheduleVersion.standardWeek(effectiveFrom: DayKey(iso: "2026-06-01")!, start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 16))
        v2.note = "summer"
        s.schedules = [v2, v1]
        XCTAssertEqual(s.scheduleVersion(for: DayKey(iso: "2026-03-01")!)?.id, v1.id)
        XCTAssertEqual(s.scheduleVersion(for: DayKey(iso: "2026-06-01")!)?.id, v2.id)
        XCTAssertNil(s.scheduleVersion(for: DayKey(iso: "2025-12-31")!))
        XCTAssertEqual(v1[.monday].expectedSeconds, 8 * 3600 + 1800)
        XCTAssertEqual(v1[.sunday].expectedSeconds, 0)
    }

    func testManualSessionState() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var m = ManualSession(category: "Home work", segments: [ManualSegment(start: t0)])
        XCTAssertEqual(m.state, .running)
        XCTAssertEqual(m.activeSeconds(now: t0.addingTimeInterval(600)), 600)
        m.segments[0].end = t0.addingTimeInterval(600)
        XCTAssertEqual(m.state, .paused)
        m.isStopped = true
        XCTAssertEqual(m.state, .stopped)
        XCTAssertEqual(m.activeSeconds(now: t0.addingTimeInterval(9999)), 600)
    }
}
