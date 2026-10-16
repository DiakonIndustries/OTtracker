import Foundation
import OTModels

/// Pure ledger computations. See docs/SPEC.md section 4.
public enum Ledger {
    /// How the schedule resolves for one day (override → holiday → version).
    public struct DaySchedule: Hashable, Sendable {
        public var kind: DayKind
        public var window: Interval?
        public var weekdaySchedule: WeekdaySchedule?
        public init(kind: DayKind, window: Interval?, weekdaySchedule: WeekdaySchedule?) {
            self.kind = kind
            self.window = window
            self.weekdaySchedule = weekdaySchedule
        }
    }

    public static func daySchedule(store: Store, day: DayKey) -> DaySchedule {
        fatalError("OTLedger.daySchedule not implemented yet")
    }

    public static func dayResult(store: Store, day: DayKey, now: Date) -> DayResult {
        fatalError("OTLedger.dayResult not implemented yet")
    }

    public static func dayResults(store: Store, from: DayKey, through: DayKey, now: Date) -> [DayResult] {
        fatalError("OTLedger.dayResults not implemented yet")
    }

    /// Bank balance at the end of `day` (inclusive).
    public static func balance(store: Store, asOf day: DayKey, now: Date) -> Int {
        fatalError("OTLedger.balance not implemented yet")
    }

    public static func summary(store: Store, now: Date) -> LedgerSummary {
        fatalError("OTLedger.summary not implemented yet")
    }

    public static func leaveBalances(store: Store, asOf day: DayKey) -> [LeaveBalance] {
        fatalError("OTLedger.leaveBalances not implemented yet")
    }

    /// First day with any fact, or today; used to bound "all history" computations.
    public static func earliestDay(store: Store, now: Date) -> DayKey {
        fatalError("OTLedger.earliestDay not implemented yet")
    }
}
