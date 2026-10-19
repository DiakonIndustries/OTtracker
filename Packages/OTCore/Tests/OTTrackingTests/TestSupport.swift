import XCTest
import OTModels
@testable import OTTracking

/// Fixed time zone, fixed locations, fixed schedule: every test is deterministic.
enum Fixture {
    static let tz = TimeZone(identifier: "America/New_York")!
    static var settings: Settings { Settings(timeZone: tz) }
    static var calendar: Calendar { settings.calendar }

    static let plantA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let plantB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let unknownLocation = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    /// Store with Plant A / Plant B and a Mon–Fri 07:00–15:30 schedule from 2026-01-04.
    static func store() -> Store {
        var s = Store(settings: settings)
        s.locations = [
            WorkLocation(id: plantA, name: "Plant A", latitude: 40.0, longitude: -74.0, createdAt: date("2026-01-01 00:00")),
            WorkLocation(id: plantB, name: "Plant B", latitude: 41.0, longitude: -75.0, createdAt: date("2026-01-01 00:00")),
        ]
        s.schedules = [ScheduleVersion.standardWeek(effectiveFrom: DayKey(year: 2026, month: 1, day: 4))]
        return s
    }

    /// `yyyy-MM-dd HH:mm` or `yyyy-MM-dd HH:mm:ss`, New York wall-clock time.
    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = s.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        guard let d = f.date(from: s) else { fatalError("bad fixture date \(s)") }
        return d
    }

    /// ISO 8601 with an explicit offset, for instants that are ambiguous on DST days.
    static func iso(_ s: String) -> Date {
        guard let d = ISO8601.plain.date(from: s) else { fatalError("bad fixture iso \(s)") }
        return d
    }

    static func day(_ s: String) -> DayKey {
        guard let k = DayKey(iso: s) else { fatalError("bad fixture day \(s)") }
        return k
    }

    /// The 07:00–15:30 window on `day`.
    static func window(_ day: String, start: TimeOfDay = TimeOfDay(hour: 7), end: TimeOfDay = TimeOfDay(hour: 15, minute: 30)) -> Interval {
        let k = Fixture.day(day)
        return Interval(start: start.date(on: k, calendar: calendar), end: end.date(on: k, calendar: calendar))
    }

    /// A workday result with the standard window; `configure` fills in the components under test.
    static func workday(_ day: String, _ configure: (inout DayResult) -> Void = { _ in }) -> DayResult {
        var r = DayResult(day: Fixture.day(day), kind: .workday, scheduledWindow: window(day), expectedSeconds: 30_600)
        configure(&r)
        return r
    }

    /// A day with no window (weekend).
    static func offDay(_ day: String) -> DayResult {
        DayResult(day: Fixture.day(day), kind: .weekend, scheduledWindow: nil, expectedSeconds: 0)
    }

    static func enter(_ location: UUID = plantA, _ at: String, source: EventSource = .geofence, id: UUID = UUID()) -> LocationEvent {
        LocationEvent(id: id, locationID: location, kind: .enter, at: date(at), source: source)
    }

    static func exit(_ location: UUID = plantA, _ at: String, source: EventSource = .geofence, id: UUID = UUID()) -> LocationEvent {
        LocationEvent(id: id, locationID: location, kind: .exit, at: date(at), source: source)
    }

    static func session(_ location: UUID = plantA, _ from: String, _ to: String?, source: EventSource = .geofence,
                        gapIsWork: Bool? = nil, id: UUID = UUID()) -> PresenceSession {
        PresenceSession(id: id, locationID: location, enteredAt: date(from), exitedAt: to.map { date($0) },
                        source: source, followingGapIsWork: gapIsWork)
    }
}

/// Asserts that `body` throws exactly `expected`.
func assertThrows(_ expected: ManualTimer.TimerError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("expected \(expected) to be thrown", file: file, line: line)
    } catch let e as ManualTimer.TimerError {
        XCTAssertEqual(e, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
