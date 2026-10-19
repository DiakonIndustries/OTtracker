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

#if DEBUG
/// Screenshot / demo mode: launch with `-OTDemo <scene>` (scenes: home, timer, log, day, inbox, timeoff, settings).
/// Uses an in-memory store and no device services, so nothing touches real data or asks for permissions.
@MainActor
enum DemoMode {
    static var scene: String? { UserDefaults.standard.string(forKey: "OTDemo") }

    /// A time zone in which "now" is mid-morning, so the demo always shows a working day in progress.
    static func midMorningZone(now: Date) -> TimeZone {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents([.hour, .minute], from: now)
        let utcMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var offset = 10 * 60 + 25 - utcMinutes          // aim for 10:25 local
        if offset > 14 * 60 { offset -= 24 * 60 }
        if offset < -12 * 60 { offset += 24 * 60 }
        return TimeZone(secondsFromGMT: offset * 60) ?? .current
    }

    static func makeModel(scene: String) -> AppModel {
        let now = Date()
        let zone = midMorningZone(now: now)
        var s = SampleData.store(now: now, timeZone: zone)
        let cal = s.calendar
        let today = DayKey(now, calendar: cal)
        let plant = s.locations[0]

        // At work right now (unless the demo is about the manual timer).
        if scene != "timer" {
            s.presence.append(PresenceSession(locationID: plant.id, enteredAt: now.addingTimeInterval(-(3 * 3600 + 23 * 60)), exitedAt: nil))
        } else {
            let start = now.addingTimeInterval(-(65 * 60 + 12))
            s.manual.append(ManualSession(category: "Home work", note: "Quarterly report", countsAs: .extra,
                                          segments: [ManualSegment(start: start)], createdAt: start))
        }
        // A lunch run two working days ago that the Inbox asks about, and an early start yesterday.
        var back = 1
        var workdays: [DayKey] = []
        while workdays.count < 2 && back < 10 {
            let d = today.adding(days: -back, calendar: cal)
            if d.weekday(in: cal) != .saturday && d.weekday(in: cal) != .sunday { workdays.append(d) }
            back += 1
        }
        if workdays.count == 2 {
            let gapDay = workdays[1]
            s.presence.removeAll { DayKey($0.enteredAt, calendar: cal) == gapDay }
            s.presence.append(PresenceSession(locationID: plant.id, enteredAt: TimeOfDay(hour: 6, minute: 58).date(on: gapDay, calendar: cal),
                                              exitedAt: TimeOfDay(hour: 11, minute: 50).date(on: gapDay, calendar: cal)))
            s.presence.append(PresenceSession(locationID: plant.id, enteredAt: TimeOfDay(hour: 12, minute: 41).date(on: gapDay, calendar: cal),
                                              exitedAt: TimeOfDay(hour: 16, minute: 12).date(on: gapDay, calendar: cal)))
            let early = workdays[0]
            s.presence.removeAll { DayKey($0.enteredAt, calendar: cal) == early }
            s.presence.append(PresenceSession(locationID: plant.id, enteredAt: TimeOfDay(hour: 6, minute: 31).date(on: early, calendar: cal),
                                              exitedAt: TimeOfDay(hour: 16, minute: 4).date(on: early, calendar: cal)))
        }
        let model = AppModel.preview(s)
        switch scene {
        case "log": model.selectedTab = .log
        case "day": model.selectedTab = .log; model.pendingRoute = .day(workdays.first ?? today)
        case "inbox": model.selectedTab = .inbox
        case "timeoff": model.selectedTab = .timeOff
        case "settings": model.openSettings()
        default: model.selectedTab = .home
        }
        return model
    }
}
#endif
