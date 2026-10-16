import Foundation
import OTCore

/// A believable store for previews and the simulator.
enum SampleData {
    static func store(now: Date = Date(), timeZone: TimeZone = .current) -> Store {
        var s = Store(settings: Settings(timeZone: timeZone))
        let cal = s.calendar
        let today = DayKey(now, calendar: cal)
        s.settings.onboardingCompleted = true
        s.settings.bankStartingSeconds = 6 * 3600
        s.settings.bankStartingAsOf = today.adding(days: -60, calendar: cal)
        s.schedules = [ScheduleVersion.standardWeek(effectiveFrom: today.adding(days: -365, calendar: cal),
                                                    start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30))]
        let plant = WorkLocation(name: "Plant A", latitude: 41.8781, longitude: -87.6298, radiusMeters: 250, createdAt: now)
        s.locations = [plant]
        s.leaveBalances = [
            LeaveBalanceConfig(typeID: TimeOffType.ptoID, startingSeconds: 80 * 3600, asOf: DayKey(year: today.year, month: 1, day: 1),
                               accrual: AccrualRule(seconds: 6 * 3600 + 40 * 60, period: .monthly, anchor: DayKey(year: today.year, month: 1, day: 1))),
            LeaveBalanceConfig(typeID: TimeOffType.personalID, startingSeconds: 24 * 3600, asOf: DayKey(year: today.year, month: 1, day: 1)),
        ]
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for offset in stride(from: 30, through: 1, by: -1) {
            let day = today.adding(days: -offset, calendar: cal)
            let wd = day.weekday(in: cal)
            guard wd != .saturday && wd != .sunday else { continue }
            let inMin = rnd(11) - 5
            let outMin = [0, 0, 0, 12, 25, 42, -8, 65][rnd(8)]
            let enter = TimeOfDay(hour: 7, minute: 0).date(on: day, calendar: cal).addingTimeInterval(TimeInterval(inMin * 60))
            let exit = TimeOfDay(hour: 15, minute: 30).date(on: day, calendar: cal).addingTimeInterval(TimeInterval(outMin * 60))
            s.presence.append(PresenceSession(locationID: plant.id, enteredAt: enter, exitedAt: exit))
            if rnd(6) == 0 {
                let start = TimeOfDay(hour: 19, minute: 30).date(on: day, calendar: cal)
                s.manual.append(ManualSession.block(category: "After hours", note: "Emails", start: start, end: start.addingTimeInterval(2700), createdAt: start))
            }
        }
        s.timeOff.append(TimeOffEntry(day: today.adding(days: -9, calendar: cal), typeID: TimeOffType.ptoID, seconds: 8 * 3600 + 1800, note: "Long weekend"))
        s.presence.removeAll { DayKey($0.enteredAt, calendar: cal) == today.adding(days: -9, calendar: cal) }
        s.holidays.append(Holiday(day: DayKey(year: today.year, month: 11, day: 26), name: "Thanksgiving"))
        s.holidays.append(Holiday(day: DayKey(year: today.year, month: 12, day: 25), name: "Christmas"))
        return s
    }
}
