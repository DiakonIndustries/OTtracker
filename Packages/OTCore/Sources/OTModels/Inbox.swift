import Foundation

public enum InboxKind: String, Codable, Sendable, CaseIterable {
    case gap, noShow, exit, earlyArrival, timer, staleOpen, orphanExit, monthlyExport
}

/// What the user can do with an Inbox item. The app maps each to UI.
public enum InboxAction: Hashable, Codable, Sendable {
    case markGapWork
    case markGapPersonal
    case addTimeOff(kind: TimeOffKind)
    case markRemoteDay
    case enterHours
    case excuseDay
    case keepDeficit
    case confirm
    case adjustSession
    case removeSession
    case countEarlyArrival
    case dontCountEarlyArrival
    case stillWorking
    case stopTimerNow
    case setTimerStop
    case setExitTime
    case deleteSession
    case setArrivalTime
    case ignore
    case emailExport
    case shareExport
    case dismiss

    public var title: String {
        switch self {
        case .markGapWork: return "Work trip"
        case .markGapPersonal: return "Personal"
        case .addTimeOff(let kind):
            switch kind {
            case .pto: return "Add PTO"
            case .personal: return "Add personal time"
            case .flex: return "Use flex time"
            case .other: return "Add time off"
            }
        case .markRemoteDay: return "Remote day"
        case .enterHours: return "Enter hours"
        case .excuseDay: return "Excuse"
        case .keepDeficit: return "Keep deficit"
        case .confirm: return "Confirm"
        case .adjustSession: return "Adjust"
        case .removeSession: return "Remove"
        case .countEarlyArrival: return "Count it"
        case .dontCountEarlyArrival: return "Don't count"
        case .stillWorking: return "Still working"
        case .stopTimerNow: return "Stop now"
        case .setTimerStop: return "Set stop time"
        case .setExitTime: return "Set exit time"
        case .deleteSession: return "Delete"
        case .setArrivalTime: return "Set arrival time"
        case .ignore: return "Ignore"
        case .emailExport: return "Email"
        case .shareExport: return "Share"
        case .dismiss: return "Dismiss"
        }
    }

    /// Actions that only hide the item (added to `dismissedInboxKeys`).
    public var isDismissal: Bool {
        switch self {
        case .keepDeficit, .confirm, .dontCountEarlyArrival, .stillWorking, .ignore, .dismiss: return true
        default: return false
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .removeSession, .deleteSession: return true
        default: return false
        }
    }
}

public struct InboxItem: Identifiable, Hashable, Codable, Sendable {
    /// Stable key, e.g. `gap:<sessionID>`, `noshow:2026-10-14`.
    public var key: String
    public var kind: InboxKind
    public var day: DayKey
    /// Instant used for ordering (newest first).
    public var occurredAt: Date
    public var title: String
    public var detail: String
    /// What the app already did, e.g. "Deducted 1h 10m".
    public var defaultApplied: String?
    public var actions: [InboxAction]
    /// Session / manual / event / location the item is about.
    public var subjectID: UUID?

    public var id: String { key }

    public init(key: String, kind: InboxKind, day: DayKey, occurredAt: Date, title: String, detail: String,
                defaultApplied: String? = nil, actions: [InboxAction], subjectID: UUID? = nil) {
        self.key = key
        self.kind = kind
        self.day = day
        self.occurredAt = occurredAt
        self.title = title
        self.detail = detail
        self.defaultApplied = defaultApplied
        self.actions = actions
        self.subjectID = subjectID
    }
}
