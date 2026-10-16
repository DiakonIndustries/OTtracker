import Foundation
import OTModels

/// See docs/SPEC.md section 5.3. Pure: the Inbox is derived from facts, day results and `now`.
public enum InboxEngine {
    /// Exit events older than this never raise `orphanExit` items.
    public static let orphanExitLookbackDays = 14
    /// An exit event within this many seconds of a session boundary is considered to have closed it.
    public static let orphanExitToleranceSeconds: TimeInterval = 60

    /// `dayResults` should cover at least the last 60 days through today.
    /// `monthlyExports` lists `yyyy-MM` keys for export files that exist on disk.
    public static func items(store: Store, dayResults: [DayResult], now: Date, monthlyExports: [String] = []) -> [InboxItem] {
        let ctx = Context(store: store, dayResults: dayResults, now: now)
        var items: [InboxItem] = []
        items += gapItems(ctx)
        items += noShowItems(ctx)
        items += exitItems(ctx)
        items += earlyArrivalItems(ctx)
        items += timerItems(ctx)
        items += staleItems(ctx)
        items += orphanExitItems(ctx)
        items += exportItems(ctx, monthlyExports: monthlyExports)
        return items
            .filter { !store.dismissedInboxKeys.contains($0.key) }
            .sorted { a, b in
                if a.occurredAt != b.occurredAt { return a.occurredAt > b.occurredAt }
                return a.key < b.key
            }
    }

    // MARK: Context

    /// Everything the rules share: lookups and formatting bound to the store's time zone.
    struct Context {
        let store: Store
        let now: Date
        let calendar: Calendar
        let today: DayKey
        let yesterday: DayKey
        let byDay: [DayKey: DayResult]

        init(store: Store, dayResults: [DayResult], now: Date) {
            self.store = store
            self.now = now
            calendar = store.calendar
            today = DayKey(now, calendar: calendar)
            yesterday = today.adding(days: -1, calendar: calendar)
            var map: [DayKey: DayResult] = [:]
            for r in dayResults { map[r.day] = r }
            byDay = map
        }

        func day(of date: Date) -> DayKey { DayKey(date, calendar: calendar) }
        func isTodayOrYesterday(_ day: DayKey) -> Bool { day == today || day == yesterday }
        func locationName(_ id: UUID) -> String { store.location(id: id)?.name ?? "work" }
        func time(_ date: Date) -> String { InboxFormat.time(date, calendar: calendar) }
        func dayLabel(_ day: DayKey) -> String { InboxFormat.day(day, calendar: calendar) }
    }

    // MARK: gap:<sessionID>

    /// Consecutive sessions (by `enteredAt`) whose gap falls inside one day's scheduled window
    /// and whose earlier session has no decision yet.
    static func gapItems(_ ctx: Context) -> [InboxItem] {
        let ordered = ctx.store.presence.sorted { a, b in
            if a.enteredAt != b.enteredAt { return a.enteredAt < b.enteredAt }
            return a.id.uuidString < b.id.uuidString
        }
        guard ordered.count >= 2 else { return [] }
        var items: [InboxItem] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            guard a.followingGapIsWork == nil, let exitedAt = a.exitedAt, b.enteredAt > exitedAt else { continue }
            let day = ctx.day(of: exitedAt)
            guard day == ctx.day(of: b.enteredAt),
                  let result = ctx.byDay[day], let window = result.scheduledWindow else { continue }
            let gap = Interval(start: exitedAt, end: b.enteredAt)
            guard gap.overlaps(window), let inside = gap.clipped(to: window) else { continue }
            let sameLocation = a.locationID == b.locationID
            let destination = sameLocation
                ? "returned to \(ctx.locationName(b.locationID))"
                : "arrived at \(ctx.locationName(b.locationID))"
            items.append(InboxItem(
                key: "gap:\(a.id.uuidString)",
                kind: .gap,
                day: day,
                occurredAt: exitedAt,
                title: "Away \(ctx.time(exitedAt)) – \(ctx.time(b.enteredAt))",
                detail: "Left \(ctx.locationName(a.locationID)), \(destination) · \(DurationFormat.hm(gap.seconds))",
                defaultApplied: sameLocation ? "Deducted \(DurationFormat.hm(inside.seconds))" : "Counted as work",
                actions: [.markGapWork, .markGapPersonal],
                subjectID: a.id))
        }
        return items
    }

    // MARK: noshow:<yyyy-MM-dd>

    /// One item per day result flagged `.noShow`; the deficit is what the day took from the bank.
    static func noShowItems(_ ctx: Context) -> [InboxItem] {
        ctx.byDay.values.filter { $0.flags.contains(.noShow) }.map { r in
            let deficit = max(0, -r.deltaSeconds)
            var detail = "No presence recorded"
            if let w = r.scheduledWindow {
                detail += " · scheduled \(ctx.time(w.start)) – \(ctx.time(w.end))"
            }
            detail += " · deficit \(DurationFormat.hm(deficit))"
            return InboxItem(
                key: "noshow:\(r.day.isoString)",
                kind: .noShow,
                day: r.day,
                occurredAt: r.scheduledWindow?.end ?? r.day.end(in: ctx.calendar),
                title: "No show \(ctx.dayLabel(r.day))",
                detail: detail,
                defaultApplied: "Deducted \(DurationFormat.hm(deficit))",
                actions: [.addTimeOff(kind: .pto), .addTimeOff(kind: .personal), .markRemoteDay,
                          .enterHours, .excuseDay, .keepDeficit],
                subjectID: nil)
        }
    }

    // MARK: exit:<sessionID>

    /// The last geofence exit of today or yesterday when it moved the delta (stayed late or left early).
    static func exitItems(_ ctx: Context) -> [InboxItem] {
        var items: [InboxItem] = []
        for s in ctx.store.presence {
            guard s.source == .geofence, let exitedAt = s.exitedAt else { continue }
            let day = ctx.day(of: exitedAt)
            guard ctx.isTodayOrYesterday(day), let result = ctx.byDay[day] else { continue }
            guard result.extraAfterSeconds > 0 || result.earlyExitSeconds > 0 else { continue }
            // Only the day's final departure moves the boundary; mid-day exits are gap items.
            let somethingFollows = ctx.store.presence.contains { other in
                other.id != s.id && other.enteredAt >= exitedAt && ctx.day(of: other.enteredAt) == day
            }
            guard !somethingFollows else { continue }
            let detail: String
            let applied: String
            if result.extraAfterSeconds > 0 {
                detail = "+" + DurationFormat.hm(result.extraAfterSeconds)
                applied = "Added \(DurationFormat.hm(result.extraAfterSeconds))"
            } else {
                detail = "\u{2212}" + DurationFormat.hm(result.earlyExitSeconds)
                applied = "Deducted \(DurationFormat.hm(result.earlyExitSeconds))"
            }
            items.append(InboxItem(
                key: "exit:\(s.id.uuidString)",
                kind: .exit,
                day: day,
                occurredAt: exitedAt,
                title: "Left \(ctx.locationName(s.locationID)) \(ctx.time(exitedAt))",
                detail: detail,
                defaultApplied: applied,
                actions: [.confirm, .adjustSession, .removeSession],
                subjectID: s.id))
        }
        return items
    }

    // MARK: early:<yyyy-MM-dd>

    /// Today's or yesterday's uncounted early arrival.
    static func earlyArrivalItems(_ ctx: Context) -> [InboxItem] {
        ctx.byDay.values
            .filter { $0.flags.contains(.earlyArrivalUncounted) && ctx.isTodayOrYesterday($0.day) }
            .map { r in
                var detail = "\(DurationFormat.hm(r.extraBeforeSeconds)) before the scheduled start"
                if let firstIn = r.firstIn, let start = r.scheduledWindow?.start {
                    detail = "In at \(ctx.time(firstIn)) · \(DurationFormat.hm(r.extraBeforeSeconds)) before \(ctx.time(start))"
                }
                return InboxItem(
                    key: "early:\(r.day.isoString)",
                    kind: .earlyArrival,
                    day: r.day,
                    occurredAt: r.firstIn ?? r.scheduledWindow?.start ?? r.day.start(in: ctx.calendar),
                    title: "Arrived early \(ctx.dayLabel(r.day))",
                    detail: detail,
                    defaultApplied: "Not counted",
                    actions: [.countEarlyArrival, .dontCountEarlyArrival],
                    subjectID: nil)
            }
    }

    // MARK: timer:<manualID>:<n>

    /// The running timer once it has been active for `n` whole nudge periods (`n >= 1`).
    static func timerItems(_ ctx: Context) -> [InboxItem] {
        let nudgeSeconds = ctx.store.settings.timerNudgeMinutes * 60
        guard nudgeSeconds > 0, let m = ctx.store.activeManualSession, m.state == .running else { return [] }
        let active = m.activeSeconds(now: ctx.now)
        let n = active / nudgeSeconds
        guard n >= 1 else { return [] }
        var detail = m.category
        if let started = m.startedAt { detail += " · started \(ctx.time(started))" }
        if !m.note.isEmpty { detail += " · \(m.note)" }
        return [InboxItem(
            key: "timer:\(m.id.uuidString):\(n)",
            kind: .timer,
            day: ctx.today,
            occurredAt: ctx.now,
            title: "Timer still running (\(DurationFormat.hm(active)))",
            detail: detail,
            defaultApplied: nil,
            actions: [.stillWorking, .stopTimerNow, .setTimerStop],
            subjectID: m.id)]
    }

    // MARK: stale:<sessionID>

    /// Open presence sessions older than `staleOpenSessionHours`.
    static func staleItems(_ ctx: Context) -> [InboxItem] {
        let limit = TimeInterval(ctx.store.settings.staleOpenSessionHours * 3600)
        return ctx.store.presence
            .filter { $0.isOpen && ctx.now.timeIntervalSince($0.enteredAt) > limit }
            .map { s in
                let openFor = Int(ctx.now.timeIntervalSince(s.enteredAt).rounded())
                let day = ctx.day(of: s.enteredAt)
                return InboxItem(
                    key: "stale:\(s.id.uuidString)",
                    kind: .staleOpen,
                    day: day,
                    occurredAt: s.enteredAt,
                    title: "Still at \(ctx.locationName(s.locationID))?",
                    detail: "Arrived \(ctx.dayLabel(day)) \(ctx.time(s.enteredAt)) · no exit for \(DurationFormat.hm(openFor))",
                    defaultApplied: nil,
                    actions: [.setExitTime, .deleteSession],
                    subjectID: s.id)
            }
    }

    // MARK: orphanExit:<eventID>

    /// Recent geofence exits that no session accounts for (none was open at that instant, within tolerance).
    static func orphanExitItems(_ ctx: Context) -> [InboxItem] {
        let horizon = ctx.now.addingTimeInterval(-TimeInterval(orphanExitLookbackDays) * 86_400)
        let known = Set(ctx.store.locations.map(\.id))
        return ctx.store.locationEvents
            .filter { e in
                e.kind == .exit && e.source == .geofence && e.at >= horizon && known.contains(e.locationID)
                    && !isAccountedFor(e.at, in: ctx)
            }
            .map { e in
                let day = ctx.day(of: e.at)
                return InboxItem(
                    key: "orphanExit:\(e.id.uuidString)",
                    kind: .orphanExit,
                    day: day,
                    occurredAt: e.at,
                    title: "Left \(ctx.locationName(e.locationID)) \(ctx.time(e.at)) with no arrival",
                    detail: "No open session on \(ctx.dayLabel(day)) · set the arrival time to record the day",
                    defaultApplied: "Nothing recorded",
                    actions: [.setArrivalTime, .ignore],
                    subjectID: e.id)
            }
    }

    /// True when some presence session covers `instant` (open sessions run to `now`), within tolerance.
    static func isAccountedFor(_ instant: Date, in ctx: Context) -> Bool {
        let tol = orphanExitToleranceSeconds
        return ctx.store.presence.contains { s in
            let end = s.exitedAt ?? max(ctx.now, s.enteredAt)
            return instant >= s.enteredAt.addingTimeInterval(-tol) && instant <= end.addingTimeInterval(tol)
        }
    }

    // MARK: export:<yyyy-MM>

    /// One item per monthly export file that exists.
    static func exportItems(_ ctx: Context, monthlyExports: [String]) -> [InboxItem] {
        var seen: Set<String> = []
        var items: [InboxItem] = []
        for raw in monthlyExports {
            let month = raw.trimmingCharacters(in: .whitespaces)
            guard !month.isEmpty, !seen.contains(month) else { continue }
            seen.insert(month)
            let firstDay = InboxFormat.firstDay(ofMonth: month) ?? ctx.today
            let label = InboxFormat.monthName(firstDay, calendar: ctx.calendar)
            // The file appears once the month has ended, so order it at that moment.
            let monthEnd = ctx.calendar.date(byAdding: .month, value: 1, to: firstDay.start(in: ctx.calendar)) ?? firstDay.end(in: ctx.calendar)
            items.append(InboxItem(
                key: "export:\(month)",
                kind: .monthlyExport,
                day: firstDay,
                occurredAt: monthEnd,
                title: "\(label) export ready",
                detail: "Monthly Excel file for \(label) · email or share it",
                defaultApplied: nil,
                actions: [.emailExport, .shareExport, .dismiss],
                subjectID: nil))
        }
        return items
    }
}

/// Deterministic text for Inbox items: fixed POSIX locale, the store's time zone.
enum InboxFormat {
    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    /// `5:42 PM`
    static func time(_ date: Date, calendar: Calendar) -> String {
        formatter("h:mm a", calendar: calendar).string(from: date)
    }

    /// `Tue Oct 14`
    static func day(_ day: DayKey, calendar: Calendar) -> String {
        let noon = day.start(in: calendar).addingTimeInterval(12 * 3600)
        return formatter("EEE MMM d", calendar: calendar).string(from: noon)
    }

    /// `October 2026`
    static func monthName(_ day: DayKey, calendar: Calendar) -> String {
        let noon = day.start(in: calendar).addingTimeInterval(12 * 3600)
        return formatter("MMMM yyyy", calendar: calendar).string(from: noon)
    }

    /// Parses `yyyy-MM` into the first day of that month.
    static func firstDay(ofMonth key: String) -> DayKey? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        return DayKey(year: y, month: m, day: 1)
    }
}
