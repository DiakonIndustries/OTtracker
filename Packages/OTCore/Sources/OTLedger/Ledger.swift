import Foundation
import OTModels

/// Pure ledger computations. See docs/SPEC.md section 4.
///
/// Everything here is a function of `(Store, days, now)`. Day boundaries, weekdays and
/// scheduled windows are resolved with `store.calendar` (the user's time zone); `now` is
/// always a parameter so results are reproducible.
public enum Ledger {

    // MARK: - Types

    /// How the schedule resolves for one day (override → holiday → version).
    public struct DaySchedule: Hashable, Sendable {
        /// Ledger kind of the day (`.excused` wins over everything else).
        public var kind: DayKind
        /// Scheduled presence window `[S, E]` on that day, nil when nothing is expected.
        public var window: Interval?
        /// The weekday schedule the window came from (version or override), nil for day off / holiday / none.
        public var weekdaySchedule: WeekdaySchedule?
        /// Memberwise initializer.
        public init(kind: DayKind, window: Interval?, weekdaySchedule: WeekdaySchedule?) {
            self.kind = kind
            self.window = window
            self.weekdaySchedule = weekdaySchedule
        }
    }

    /// One mid-day absence between two consecutive merged presence intervals that falls
    /// (at least partly) inside the scheduled window, with the decision the ledger applied.
    public struct DayGap: Hashable, Sendable {
        /// The presence session that ended the earlier interval; nil when it ended with a regular manual segment.
        public var sessionID: UUID?
        /// Location the earlier interval ended at; nil for a regular manual segment.
        public var fromLocationID: UUID?
        /// Location the later interval started at; nil for a regular manual segment.
        public var toLocationID: UUID?
        /// The whole absence, from the earlier interval's end to the later one's start (not clipped to the window).
        public var interval: Interval
        /// Seconds of the absence inside the scheduled window: what was deducted or added back.
        public var secondsInsideWindow: Int
        /// The stored `followingGapIsWork`; nil when undecided and the default applied.
        public var decision: Bool?
        /// Whether the ledger treated the gap as work (decision, or the default when undecided).
        public var countsAsWork: Bool

        /// Memberwise initializer.
        public init(sessionID: UUID?, fromLocationID: UUID?, toLocationID: UUID?, interval: Interval,
                    secondsInsideWindow: Int, decision: Bool?, countsAsWork: Bool) {
            self.sessionID = sessionID
            self.fromLocationID = fromLocationID
            self.toLocationID = toLocationID
            self.interval = interval
            self.secondsInsideWindow = secondsInsideWindow
            self.decision = decision
            self.countsAsWork = countsAsWork
        }

        /// True when no decision is stored and the default was applied.
        public var isUndecided: Bool { decision == nil }
    }

    // MARK: - Schedule resolution (SPEC 4.1)

    /// Resolves the schedule for `day`: dayOff override → schedule override → holiday → schedule version → none.
    /// An excused override turns `kind` into `.excused` but keeps the window so components can still be shown.
    public static func daySchedule(store: Store, day: DayKey) -> DaySchedule {
        let cal = store.calendar
        return resolveSchedule(store: store, day: day, weekday: day.weekday(in: cal),
                               override: store.override(for: day), holiday: store.holiday(on: day), calendar: cal)
    }

    static func resolveSchedule(store: Store, day: DayKey, weekday: Weekday, override: DayOverride?,
                                holiday: Holiday?, calendar: Calendar) -> DaySchedule {
        var resolved: DaySchedule
        switch override?.kind {
        case .dayOff?:
            resolved = DaySchedule(kind: .dayOff, window: nil, weekdaySchedule: nil)
        case .schedule(let s)?:
            resolved = schedule(from: s, day: day, calendar: calendar)
        default:
            if holiday != nil {
                resolved = DaySchedule(kind: .holiday, window: nil, weekdaySchedule: nil)
            } else if let version = store.scheduleVersion(for: day) {
                resolved = schedule(from: version[weekday], day: day, calendar: calendar)
            } else {
                resolved = DaySchedule(kind: .weekend, window: nil, weekdaySchedule: nil)
            }
        }
        if override?.excused == true { resolved.kind = .excused }
        return resolved
    }

    /// A workday with a valid, non-empty window is `.workday`; anything else reads as `.weekend`.
    private static func schedule(from s: WeekdaySchedule, day: DayKey, calendar: Calendar) -> DaySchedule {
        if let w = s.window(on: day, calendar: calendar), !w.isEmpty {
            return DaySchedule(kind: .workday, window: w, weekdaySchedule: s)
        }
        return DaySchedule(kind: .weekend, window: nil, weekdaySchedule: s)
    }

    // MARK: - Day results (SPEC 4.2 – 4.5)

    /// The ledger for one day. Equivalent to `dayResults(store:from:day, through:day, now:)[0]`.
    ///
    /// Field semantics of the `DayResult` produced here:
    /// - `presenceSeconds` / `firstIn` / `lastOut`: merged presence on the day, which includes regular
    ///   manual segments (`countsAs == .regular`) and open sessions running to `now`.
    /// - `presenceInsideSeconds`: presence inside the window `[S, E]` (actual, grace never changes it).
    /// - `extraAfterSeconds` / `extraBeforeSeconds`: presence after `E` / before `S` after grace.
    ///   `extraBeforeSeconds` is always filled, even when it is not counted (`extraBeforeCounted`),
    ///   so the Inbox can offer it; `.earlyArrivalUncounted` is flagged when it is > 0 and not counted.
    /// - `lateArrivalSeconds` / `earlyExitSeconds`: the boundary parts of the deficit after grace.
    /// - `gapsDeductedSeconds`: ALL deducted seconds inside the window (late arrival + early exit +
    ///   personal mid-day gaps); on a day with no presence at all it is the whole window.
    /// - `gapsWorkSeconds`: mid-day gap seconds inside the window that were NOT deducted because they
    ///   were decided or defaulted to work.
    /// - `timeOffSeconds`: Σ time-off entries of every type, capped at the window length on window
    ///   days, uncapped (informational) on days without a window.
    /// - `flexSpentSeconds`: Σ entries whose type `deductsFromBank`, never capped.
    /// - On window days the identity
    ///   `deltaSeconds == extraAfterSeconds + (extraBeforeCounted ? extraBeforeSeconds : 0) − gapsDeductedSeconds
    ///    + timeOffSeconds − flexSpentSeconds + manualExtraSeconds + adjustmentSeconds`
    ///   holds exactly, and `grossExtraSeconds == extraAfter + earlyCounted + manualExtra + max(0, adjustments)`.
    /// - Without a window: `delta == presence + manualExtra + adjustments − flexSpent` and
    ///   `grossExtra == presence + manualExtra + max(0, adjustments)`.
    /// - Excused days keep every component but force `deltaSeconds` and `grossExtraSeconds` to 0.
    /// - Days after today carry only kind/window/expected and the `.future` flag; today is `.inProgress`.
    public static func dayResult(store: Store, day: DayKey, now: Date) -> DayResult {
        computeRange(store: store, from: day, through: day, now: now).first?.result ?? DayResult(day: day)
    }

    /// Ledger results for every day in `from...through` (inclusive), in order. Facts are indexed by
    /// day once, so a multi-year range costs O(facts + days).
    public static func dayResults(store: Store, from: DayKey, through: DayKey, now: Date) -> [DayResult] {
        computeRange(store: store, from: from, through: through, now: now).map { $0.result }
    }

    /// The mid-day gaps inside `day`'s window and how each was decided; empty when the day has no
    /// window, no gap, or is in the future.
    public static func gaps(store: Store, day: DayKey, now: Date) -> [DayGap] {
        computeRange(store: store, from: day, through: day, now: now).first?.gaps ?? []
    }

    // MARK: - Summaries (SPEC 4.6)

    /// Earliest day touched by presence, manual, time off, or adjustments; today when the store has no facts.
    public static func earliestDay(store: Store, now: Date) -> DayKey {
        let cal = store.calendar
        var earliestDate: Date? = nil
        func considerDate(_ d: Date) {
            if let e = earliestDate, e <= d { return }
            earliestDate = d
        }
        for s in store.presence { considerDate(s.enteredAt) }
        for m in store.manual {
            for seg in m.segments { considerDate(seg.start) }
        }
        var best: DayKey? = earliestDate.map { DayKey($0, calendar: cal) }
        func consider(_ d: DayKey) {
            if let b = best, b <= d { return }
            best = d
        }
        for t in store.timeOff { consider(t.day) }
        for a in store.adjustments { consider(a.day) }
        return best ?? DayKey(now, calendar: cal)
    }

    /// First day the bank counts: the later of `settings.bankStartingAsOf` and `earliestDay`.
    public static func trackingStart(store: Store, now: Date) -> DayKey {
        max(store.settings.bankStartingAsOf, earliestDay(store: store, now: now))
    }

    /// Bank balance at the end of `day` (inclusive):
    /// `bankStartingSeconds + Σ delta` over `[trackingStart, day]`. Days after today add nothing.
    public static func balance(store: Store, asOf day: DayKey, now: Date) -> Int {
        let cal = store.calendar
        let today = DayKey(now, calendar: cal)
        let start = trackingStart(store: store, now: now)
        let end = min(day, today)
        var total = store.settings.bankStartingSeconds
        guard start <= end else { return total }
        for r in dayResults(store: store, from: start, through: end, now: now) { total += r.deltaSeconds }
        return total
    }

    /// First day of the week that contains `day`, weeks starting on `weekStartsOn`.
    public static func weekStart(containing day: DayKey, weekStartsOn: Weekday, calendar: Calendar) -> DayKey {
        let back = (day.weekday(in: calendar).rawValue - weekStartsOn.rawValue + 7) % 7
        return day.adding(days: -back, calendar: calendar)
    }

    /// Balance through today, this month's gross extra and delta, this week's delta (weeks start on
    /// `settings.weekStartsOn`), year-to-date delta and today's delta. Every sum starts no earlier than
    /// `trackingStart` so they agree with the balance.
    public static func summary(store: Store, now: Date) -> LedgerSummary {
        let cal = store.calendar
        let today = DayKey(now, calendar: cal)
        let start = trackingStart(store: store, now: now)
        let results = start <= today ? dayResults(store: store, from: start, through: today, now: now) : []
        let monthStart = DayKey(year: today.year, month: today.month, day: 1)
        let weekFirst = weekStart(containing: today, weekStartsOn: store.settings.weekStartsOn, calendar: cal)
        let yearStart = DayKey(year: today.year, month: 1, day: 1)
        var s = LedgerSummary(balanceSeconds: store.settings.bankStartingSeconds)
        var sawToday = false
        for r in results {
            s.balanceSeconds += r.deltaSeconds
            if r.day >= monthStart {
                s.monthGrossExtraSeconds += r.grossExtraSeconds
                s.monthDeltaSeconds += r.deltaSeconds
            }
            if r.day >= weekFirst { s.weekDeltaSeconds += r.deltaSeconds }
            if r.day >= yearStart { s.ytdDeltaSeconds += r.deltaSeconds }
            if r.day == today {
                s.todayDeltaSeconds = r.deltaSeconds
                sawToday = true
            }
        }
        if !sawToday {
            // Tracking starts after today (bank dated in the future); today is still informational.
            s.todayDeltaSeconds = dayResult(store: store, day: today, now: now).deltaSeconds
        }
        return s
    }

    /// Leave balance per configured type as of `day`: starting + accrued − used. Types that track a
    /// balance but have no config get a zero config. Accrual grants on the anchor and on every period
    /// boundary after it (weekly +7 d, biweekly +14 d, monthly/yearly by calendar month/year from the
    /// anchor) with `config.asOf <= boundary <= day`; usage counts entries with `config.asOf <= entry.day <= day`.
    public static func leaveBalances(store: Store, asOf day: DayKey) -> [LeaveBalance] {
        let cal = store.calendar
        var configs = store.leaveBalances
        var seen = Set(configs.map { $0.typeID })
        for t in store.timeOffTypes where t.tracksBalance && !seen.contains(t.id) {
            configs.append(LeaveBalanceConfig(typeID: t.id))
            seen.insert(t.id)
        }
        return configs.map { c in
            let accrued = accruedSeconds(rule: c.accrual, from: c.asOf, through: day, calendar: cal)
            var used = 0
            for e in store.timeOff where e.typeID == c.typeID && e.day >= c.asOf && e.day <= day { used += e.seconds }
            return LeaveBalance(typeID: c.typeID, startingSeconds: c.startingSeconds, accruedSeconds: accrued, usedSeconds: used)
        }
    }

    /// Seconds granted by `rule` on boundaries `b` (anchor + k periods, k ≥ 0) with `from <= b <= through`.
    public static func accruedSeconds(rule: AccrualRule?, from: DayKey, through: DayKey, calendar: Calendar) -> Int {
        guard let rule, rule.seconds != 0, rule.anchor <= through else { return 0 }
        let anchorNoon = rule.anchor.start(in: calendar).addingTimeInterval(12 * 3600)
        var grants = 0
        var previous: DayKey? = nil
        var k = 0
        while k < 20_000 {
            let boundary: DayKey
            switch rule.period {
            case .weekly:
                boundary = rule.anchor.adding(days: 7 * k, calendar: calendar)
            case .biweekly:
                boundary = rule.anchor.adding(days: 14 * k, calendar: calendar)
            case .monthly:
                let d = calendar.date(byAdding: .month, value: k, to: anchorNoon) ?? anchorNoon
                boundary = DayKey(d, calendar: calendar)
            case .yearly:
                let d = calendar.date(byAdding: .year, value: k, to: anchorNoon) ?? anchorNoon
                boundary = DayKey(d, calendar: calendar)
            }
            if boundary > through { break }
            if let p = previous, boundary <= p { break } // calendar did not advance; never expected
            if boundary >= from { grants += 1 }
            previous = boundary
            k += 1
        }
        return grants * rule.seconds
    }

    // MARK: - Internals

    /// One clipped piece of presence on a day: a presence session or a regular manual segment.
    private struct Piece {
        var interval: Interval
        /// Original start, used to decide which of two overlapping locations is "later".
        var enteredAt: Date
        /// Index into `store.presence`; nil for a regular manual segment.
        var presenceIndex: Int?
        var locationID: UUID?
    }

    /// A merged (union) presence interval that remembers where it started and which piece it ends with.
    private struct Block {
        var start: Date
        var end: Date
        var startLocationID: UUID?
        var endPiece: Piece
        var interval: Interval { Interval(start: start, end: end) }
    }

    struct DayComputation {
        var result: DayResult
        var gaps: [DayGap]
    }

    /// Facts bucketed by day position in `from...through`, built once per range.
    private struct Index {
        let days: [DayKey]
        /// `days.count + 1` entries: the start of each day, then the end of the last one.
        let starts: [Date]
        var presenceByDay: [[Int]]
        var manualByDay: [[Int]]
        var timeOffByDay: [DayKey: [TimeOffEntry]] = [:]
        var adjustmentsByDay: [DayKey: [Adjustment]] = [:]
        var overrideByDay: [DayKey: DayOverride] = [:]
        var holidayByDay: [DayKey: Holiday] = [:]
        var typeByID: [UUID: TimeOffType] = [:]

        init(store: Store, from: DayKey, through: DayKey, now: Date, calendar: Calendar) {
            var days: [DayKey] = []
            var starts: [Date] = []
            var day = from
            var dayStart = day.start(in: calendar)
            while day <= through {
                days.append(day)
                starts.append(dayStart)
                let next = day.adding(days: 1, calendar: calendar)
                dayStart = next.start(in: calendar)
                day = next
            }
            starts.append(dayStart)
            self.days = days
            self.starts = starts
            presenceByDay = Array(repeating: [], count: days.count)
            manualByDay = Array(repeating: [], count: days.count)

            for (i, s) in store.presence.enumerated() {
                for d in dayRange(of: s.interval(now: now)) { presenceByDay[d].append(i) }
            }
            for (i, m) in store.manual.enumerated() {
                var touched = Set<Int>()
                for seg in m.segments { touched.formUnion(dayRange(of: seg.interval(now: now))) }
                for d in touched.sorted() { manualByDay[d].append(i) }
            }
            for t in store.timeOff where t.day >= from && t.day <= through { timeOffByDay[t.day, default: []].append(t) }
            for a in store.adjustments where a.day >= from && a.day <= through { adjustmentsByDay[a.day, default: []].append(a) }
            for o in store.overrides where overrideByDay[o.day] == nil { overrideByDay[o.day] = o }
            for h in store.holidays where holidayByDay[h.day] == nil { holidayByDay[h.day] = h }
            for t in store.timeOffTypes where typeByID[t.id] == nil { typeByID[t.id] = t }
        }

        /// Positions of the days `iv` touches, clamped to the range (empty when outside).
        func dayRange(of iv: Interval) -> Range<Int> {
            let count = days.count
            guard count > 0, let rangeEnd = starts.last, iv.end >= starts[0], iv.start < rangeEnd else { return 0..<0 }
            let first = max(0, position(of: iv.start))
            let last = min(count - 1, position(of: iv.end))
            guard first <= last else { return 0..<0 }
            return first..<(last + 1)
        }

        /// Index of the last day whose start is `<= date` (−1 before the range).
        private func position(of date: Date) -> Int {
            var lo = 0
            var hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= date { lo = mid + 1 } else { hi = mid }
            }
            return lo - 1
        }
    }

    private static func seconds(from a: Date, to b: Date) -> Int {
        Int(b.timeIntervalSince(a).rounded())
    }

    private static func computeRange(store: Store, from: DayKey, through: DayKey, now: Date) -> [DayComputation] {
        guard from <= through else { return [] }
        let cal = store.calendar
        let index = Index(store: store, from: from, through: through, now: now, calendar: cal)
        let today = DayKey(now, calendar: cal)
        let firstWeekday = from.weekday(in: cal).rawValue
        var out: [DayComputation] = []
        out.reserveCapacity(index.days.count)
        for (i, day) in index.days.enumerated() {
            let weekday = Weekday(rawValue: (firstWeekday - 1 + i) % 7 + 1) ?? .sunday
            out.append(compute(day: day, position: i, weekday: weekday, store: store, index: index, now: now, today: today))
        }
        return out
    }

    private static func compute(day: DayKey, position: Int, weekday: Weekday, store: Store, index: Index,
                                now: Date, today: DayKey) -> DayComputation {
        let cal = store.calendar
        let dayStart = index.starts[position]
        let dayEnd = index.starts[position + 1]
        let dayInterval = Interval(start: dayStart, end: dayEnd)
        let override = index.overrideByDay[day]
        let sched = resolveSchedule(store: store, day: day, weekday: weekday, override: override,
                                    holiday: index.holidayByDay[day], calendar: cal)
        let windowSeconds = sched.window?.seconds ?? 0
        let breakSeconds = (sched.weekdaySchedule?.unpaidBreakMinutes ?? 0) * 60
        var result = DayResult(day: day, kind: sched.kind, scheduledWindow: sched.window,
                               expectedSeconds: sched.window == nil ? 0 : max(0, windowSeconds - breakSeconds))

        if day > today {
            result.flags = [.future]
            return DayComputation(result: result, gaps: [])
        }
        var flags: [DayFlag] = []
        if day == today { flags.append(.inProgress) }

        // Presence sessions clipped to the day (SPEC 4.2).
        var pieces: [Piece] = []
        var openPresence = false
        for i in index.presenceByDay[position] {
            let s = store.presence[i]
            let clipped = s.interval(now: now).clipped(to: dayInterval)
            if s.isOpen, clipped != nil || (s.enteredAt >= dayStart && s.enteredAt < dayEnd) { openPresence = true }
            if let c = clipped {
                pieces.append(Piece(interval: c, enteredAt: s.enteredAt, presenceIndex: i, locationID: s.locationID))
            }
        }
        if openPresence { flags.append(.openPresence) }

        // Overlapping locations: the later `enteredAt` wins from its start (SPEC 4.7).
        pieces.sort { ($0.enteredAt, $0.interval.start, $0.presenceIndex ?? -1) < ($1.enteredAt, $1.interval.start, $1.presenceIndex ?? -1) }
        var overlapping = false
        if pieces.count > 1 {
            for i in 0..<(pieces.count - 1) {
                for j in (i + 1)..<pieces.count where pieces[j].locationID != pieces[i].locationID {
                    if pieces[j].interval.start < pieces[i].interval.end {
                        pieces[i].interval = Interval(start: pieces[i].interval.start, end: pieces[j].interval.start)
                        overlapping = true
                    }
                    break // later pieces start no earlier than this one
                }
            }
            pieces.removeAll { $0.interval.isEmpty }
        }
        if overlapping { flags.append(.overlappingLocations) }

        // Manual sessions: regular segments join presence, extra segments add on top.
        var regular: [Interval] = []
        var extra: [Interval] = []
        for i in index.manualByDay[position] {
            let m = store.manual[i]
            for seg in m.segments {
                guard let c = seg.interval(now: now).clipped(to: dayInterval) else { continue }
                if m.countsAs == .regular {
                    regular.append(c)
                    pieces.append(Piece(interval: c, enteredAt: c.start, presenceIndex: nil, locationID: nil))
                } else {
                    extra.append(c)
                }
            }
        }
        let manualRegular = Interval.totalSeconds(regular)
        let manualExtra = Interval.totalSeconds(extra)

        // Merge into blocks (union), remembering start location and the piece each block ends with.
        pieces.sort { ($0.interval.start, $0.enteredAt, $0.presenceIndex ?? -1) < ($1.interval.start, $1.enteredAt, $1.presenceIndex ?? -1) }
        var blocks: [Block] = []
        for p in pieces {
            if var last = blocks.last, p.interval.start <= last.end {
                let later = p.interval.end > last.end
                let tieWinsAsPresence = p.interval.end == last.end && p.presenceIndex != nil
                    && (last.endPiece.presenceIndex == nil || p.enteredAt >= last.endPiece.enteredAt)
                if later || tieWinsAsPresence {
                    last.end = p.interval.end
                    last.endPiece = p
                }
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(start: p.interval.start, end: p.interval.end, startLocationID: p.locationID, endPiece: p))
            }
        }
        let merged = blocks.map { $0.interval }
        result.presenceSeconds = merged.reduce(0) { $0 + $1.seconds }
        result.firstIn = blocks.first?.start
        result.lastOut = blocks.last?.end
        result.manualRegularSeconds = manualRegular
        result.manualExtraSeconds = manualExtra

        // Time off and adjustments.
        let entries = index.timeOffByDay[day] ?? []
        var timeOffRaw = 0
        var flexSpent = 0
        for e in entries {
            timeOffRaw += e.seconds
            if index.typeByID[e.typeID]?.deductsFromBank == true { flexSpent += e.seconds }
        }
        var adjustments = 0
        for a in index.adjustmentsByDay[day] ?? [] { adjustments += a.seconds }
        result.flexSpentSeconds = flexSpent
        result.adjustmentSeconds = adjustments
        let excused = sched.kind == .excused

        var gaps: [DayGap] = []
        if let window = sched.window {
            // SPEC 4.3
            let S = window.start
            let E = window.end
            let g = store.settings.graceSeconds
            let inside = merged.compactMap { $0.clipped(to: window) }.reduce(0) { $0 + $1.seconds }
            var before = merged.compactMap { $0.clipped(to: Interval(start: dayStart, end: S)) }.reduce(0) { $0 + $1.seconds }
            var after = merged.compactMap { $0.clipped(to: Interval(start: E, end: dayEnd)) }.reduce(0) { $0 + $1.seconds }
            var late = 0
            var early = 0
            var personal = 0
            var work = 0
            var grace = false
            var undecided = false

            if let firstIn = result.firstIn, let lastOut = result.lastOut {
                let lateOffset = seconds(from: S, to: firstIn)       // > 0 when the first entry is after S
                let earlyOffset = seconds(from: lastOut, to: E)      // > 0 when the last exit is before E
                if lateOffset > 0 && lateOffset <= g {
                    grace = true
                } else {
                    late = max(0, min(windowSeconds, lateOffset))
                }
                if earlyOffset > 0 && earlyOffset <= g {
                    grace = true
                } else {
                    early = max(0, min(windowSeconds, earlyOffset))
                }
                let overrun = seconds(from: E, to: lastOut)          // > 0 when the last exit is after E
                if overrun > 0 && overrun <= g {
                    after = 0
                    grace = true
                }
                let underrun = seconds(from: firstIn, to: S)         // > 0 when the first entry is before S
                if underrun > 0 && underrun <= g {
                    before = 0
                    grace = true
                }

                if blocks.count > 1 {
                    for k in 0..<(blocks.count - 1) {
                        let a = blocks[k]
                        let b = blocks[k + 1]
                        let secs = seconds(from: max(a.end, S), to: min(b.start, E))
                        guard secs > 0 else { continue }
                        let session = a.endPiece.presenceIndex.map { store.presence[$0] }
                        let decision = session?.followingGapIsWork
                        let fromLoc = a.endPiece.locationID
                        let toLoc = b.startLocationID
                        let defaultIsWork = fromLoc != nil && toLoc != nil && fromLoc != toLoc
                        let isWork = decision ?? defaultIsWork
                        if decision == nil { undecided = true }
                        if isWork { work += secs } else { personal += secs }
                        gaps.append(DayGap(sessionID: session?.id, fromLocationID: fromLoc, toLocationID: toLoc,
                                           interval: Interval(start: a.end, end: b.start), secondsInsideWindow: secs,
                                           decision: decision, countsAsWork: isWork))
                    }
                }
            }

            let gapsDeducted = blocks.isEmpty ? windowSeconds : late + early + personal
            let timeOff = min(timeOffRaw, windowSeconds)
            let counted = override?.countEarlyArrival ?? false
            let earlyCounted = counted ? before : 0

            result.presenceInsideSeconds = inside
            result.extraAfterSeconds = after
            result.extraBeforeSeconds = before
            result.extraBeforeCounted = counted
            result.lateArrivalSeconds = late
            result.earlyExitSeconds = early
            result.gapsDeductedSeconds = gapsDeducted
            result.gapsWorkSeconds = work
            result.timeOffSeconds = timeOff

            if grace { flags.append(.graceApplied) }
            if before > 0 && !counted { flags.append(.earlyArrivalUncounted) }
            if undecided { flags.append(.gapUndecided) }

            let delta = after + earlyCounted - gapsDeducted + timeOff - flexSpent + manualExtra + adjustments
            let gross = after + earlyCounted + manualExtra + max(0, adjustments)
            result.deltaSeconds = excused ? 0 : delta
            result.grossExtraSeconds = excused ? 0 : gross

            // SPEC 4.5
            if E <= now && inside == 0 && manualRegular == 0 && timeOff < windowSeconds && !excused {
                flags.append(.noShow)
            }
        } else {
            // SPEC 4.4
            result.timeOffSeconds = timeOffRaw
            let presence = result.presenceSeconds
            result.deltaSeconds = excused ? 0 : presence + manualExtra + adjustments - flexSpent
            result.grossExtraSeconds = excused ? 0 : presence + manualExtra + max(0, adjustments)
        }

        result.flags = flags
        return DayComputation(result: result, gaps: gaps)
    }
}
