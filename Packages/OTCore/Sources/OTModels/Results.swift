import Foundation

public enum DayKind: String, Codable, Sendable, CaseIterable {
    case workday, weekend, holiday, dayOff, excused

    public var label: String {
        switch self {
        case .workday: return "Workday"
        case .weekend: return "Off"
        case .holiday: return "Holiday"
        case .dayOff: return "Day off"
        case .excused: return "Excused"
        }
    }
}

public enum DayFlag: String, Codable, Sendable, CaseIterable {
    /// Scheduled workday in the past with no presence or regular time, not covered by time off.
    case noShow
    /// A presence session on this day has no exit yet.
    case openPresence
    /// Arrived before the scheduled start (beyond grace) and it was not counted.
    case earlyArrivalUncounted
    /// A mid-day gap has no decision yet; the default was applied.
    case gapUndecided
    /// Grace absorbed a boundary deviation.
    case graceApplied
    /// Sessions at two locations overlapped in time.
    case overlappingLocations
    /// The day is after `now`.
    case future
    /// The day is today and still in progress.
    case inProgress
}

/// Everything the ledger knows about one day. All seconds are integers, deltas signed.
public struct DayResult: Identifiable, Hashable, Codable, Sendable {
    public var day: DayKey
    public var kind: DayKind
    public var scheduledWindow: Interval?
    public var expectedSeconds: Int

    public var firstIn: Date?
    public var lastOut: Date?
    public var presenceSeconds: Int
    public var presenceInsideSeconds: Int

    public var extraAfterSeconds: Int
    public var extraBeforeSeconds: Int
    public var extraBeforeCounted: Bool
    public var gapsDeductedSeconds: Int
    public var gapsWorkSeconds: Int
    public var lateArrivalSeconds: Int
    public var earlyExitSeconds: Int

    public var manualExtraSeconds: Int
    public var manualRegularSeconds: Int
    public var timeOffSeconds: Int
    public var flexSpentSeconds: Int
    public var adjustmentSeconds: Int

    public var deltaSeconds: Int
    public var grossExtraSeconds: Int
    public var flags: [DayFlag]

    public var id: DayKey { day }

    public init(day: DayKey, kind: DayKind = .weekend, scheduledWindow: Interval? = nil, expectedSeconds: Int = 0,
                firstIn: Date? = nil, lastOut: Date? = nil, presenceSeconds: Int = 0, presenceInsideSeconds: Int = 0,
                extraAfterSeconds: Int = 0, extraBeforeSeconds: Int = 0, extraBeforeCounted: Bool = false,
                gapsDeductedSeconds: Int = 0, gapsWorkSeconds: Int = 0, lateArrivalSeconds: Int = 0, earlyExitSeconds: Int = 0,
                manualExtraSeconds: Int = 0, manualRegularSeconds: Int = 0, timeOffSeconds: Int = 0, flexSpentSeconds: Int = 0,
                adjustmentSeconds: Int = 0, deltaSeconds: Int = 0, grossExtraSeconds: Int = 0, flags: [DayFlag] = []) {
        self.day = day
        self.kind = kind
        self.scheduledWindow = scheduledWindow
        self.expectedSeconds = expectedSeconds
        self.firstIn = firstIn
        self.lastOut = lastOut
        self.presenceSeconds = presenceSeconds
        self.presenceInsideSeconds = presenceInsideSeconds
        self.extraAfterSeconds = extraAfterSeconds
        self.extraBeforeSeconds = extraBeforeSeconds
        self.extraBeforeCounted = extraBeforeCounted
        self.gapsDeductedSeconds = gapsDeductedSeconds
        self.gapsWorkSeconds = gapsWorkSeconds
        self.lateArrivalSeconds = lateArrivalSeconds
        self.earlyExitSeconds = earlyExitSeconds
        self.manualExtraSeconds = manualExtraSeconds
        self.manualRegularSeconds = manualRegularSeconds
        self.timeOffSeconds = timeOffSeconds
        self.flexSpentSeconds = flexSpentSeconds
        self.adjustmentSeconds = adjustmentSeconds
        self.deltaSeconds = deltaSeconds
        self.grossExtraSeconds = grossExtraSeconds
        self.flags = flags
    }

    public var hasWindow: Bool { scheduledWindow != nil }
    public var isNoShow: Bool { flags.contains(.noShow) }
}

public struct LedgerSummary: Hashable, Codable, Sendable {
    public var balanceSeconds: Int
    public var monthGrossExtraSeconds: Int
    public var monthDeltaSeconds: Int
    public var weekDeltaSeconds: Int
    public var ytdDeltaSeconds: Int
    public var todayDeltaSeconds: Int

    public init(balanceSeconds: Int = 0, monthGrossExtraSeconds: Int = 0, monthDeltaSeconds: Int = 0,
                weekDeltaSeconds: Int = 0, ytdDeltaSeconds: Int = 0, todayDeltaSeconds: Int = 0) {
        self.balanceSeconds = balanceSeconds
        self.monthGrossExtraSeconds = monthGrossExtraSeconds
        self.monthDeltaSeconds = monthDeltaSeconds
        self.weekDeltaSeconds = weekDeltaSeconds
        self.ytdDeltaSeconds = ytdDeltaSeconds
        self.todayDeltaSeconds = todayDeltaSeconds
    }
}

public struct LeaveBalance: Identifiable, Hashable, Codable, Sendable {
    public var typeID: UUID
    public var startingSeconds: Int
    public var accruedSeconds: Int
    public var usedSeconds: Int

    public var id: UUID { typeID }
    public var remainingSeconds: Int { startingSeconds + accruedSeconds - usedSeconds }

    public init(typeID: UUID, startingSeconds: Int, accruedSeconds: Int, usedSeconds: Int) {
        self.typeID = typeID
        self.startingSeconds = startingSeconds
        self.accruedSeconds = accruedSeconds
        self.usedSeconds = usedSeconds
    }
}
