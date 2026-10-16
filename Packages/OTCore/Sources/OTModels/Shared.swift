import Foundation

/// Identifiers shared by the app, the widget extension and the backup service.
public enum AppIdentifiers {
    public static let bundleID = "com.diakonindustries.ottracker"
    public static let appGroup = "group.com.diakonindustries.ottracker"
    public static let iCloudContainer = "iCloud.com.diakonindustries.ottracker"
    public static let refreshTaskID = "com.diakonindustries.ottracker.refresh"
    public static let urlScheme = "ottracker"
    public static let widgetKind = "OTtrackerBalanceWidget"
    public static let snapshotFilename = "widget-snapshot.json"
}

/// The small summary the app writes to the App Group container for the widget.
public struct WidgetSnapshot: Hashable, Codable, Sendable {
    public var generatedAt: Date
    public var balanceSeconds: Int
    public var monthGrossExtraSeconds: Int
    public var todayDeltaSeconds: Int
    public var timerRunning: Bool
    public var timerCategory: String?
    public var timerStartedAt: Date?
    public var timerAccumulatedSeconds: Int
    public var inboxCount: Int

    public init(generatedAt: Date, balanceSeconds: Int = 0, monthGrossExtraSeconds: Int = 0, todayDeltaSeconds: Int = 0,
                timerRunning: Bool = false, timerCategory: String? = nil, timerStartedAt: Date? = nil,
                timerAccumulatedSeconds: Int = 0, inboxCount: Int = 0) {
        self.generatedAt = generatedAt
        self.balanceSeconds = balanceSeconds
        self.monthGrossExtraSeconds = monthGrossExtraSeconds
        self.todayDeltaSeconds = todayDeltaSeconds
        self.timerRunning = timerRunning
        self.timerCategory = timerCategory
        self.timerStartedAt = timerStartedAt
        self.timerAccumulatedSeconds = timerAccumulatedSeconds
        self.inboxCount = inboxCount
    }

    public static let placeholder = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 0), balanceSeconds: 11 * 3600 + 20 * 60,
                                                   monthGrossExtraSeconds: 3 * 3600 + 15 * 60, todayDeltaSeconds: 2520)
}

/// Deep links the widgets and notifications use to open a screen.
public enum DeepLink: Hashable, Sendable {
    case home
    case timerStart
    case timerPause
    case timerResume
    case timerStop
    case inbox
    case log(DayKey)

    public var url: URL {
        let path: String
        switch self {
        case .home: path = "home"
        case .timerStart: path = "timer/start"
        case .timerPause: path = "timer/pause"
        case .timerResume: path = "timer/resume"
        case .timerStop: path = "timer/stop"
        case .inbox: path = "inbox"
        case .log(let day): path = "log/\(day.isoString)"
        }
        return URL(string: "\(AppIdentifiers.urlScheme)://\(path)")!
    }

    public init?(url: URL) {
        guard url.scheme == AppIdentifiers.urlScheme else { return nil }
        let host = url.host ?? ""
        let parts = [host] + url.pathComponents.filter { $0 != "/" }
        if parts == ["home"] { self = .home }
        else if parts == ["timer", "start"] { self = .timerStart }
        else if parts == ["timer", "pause"] { self = .timerPause }
        else if parts == ["timer", "resume"] { self = .timerResume }
        else if parts == ["timer", "stop"] { self = .timerStop }
        else if parts == ["inbox"] { self = .inbox }
        else if parts.count == 2, parts[0] == "log", let day = DayKey(iso: parts[1]) { self = .log(day) }
        else { return nil }
    }
}

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity for the running manual timer (shared by app and widget extension).
public struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Seconds already accumulated in closed segments.
        public var accumulatedSeconds: Int
        /// Start of the open segment, nil when paused.
        public var runningSince: Date?
        public var isPaused: Bool

        public init(accumulatedSeconds: Int, runningSince: Date?, isPaused: Bool) {
            self.accumulatedSeconds = accumulatedSeconds
            self.runningSince = runningSince
            self.isPaused = isPaused
        }
    }

    public var sessionID: UUID
    public var category: String

    public init(sessionID: UUID, category: String) {
        self.sessionID = sessionID
        self.category = category
    }
}
#endif
