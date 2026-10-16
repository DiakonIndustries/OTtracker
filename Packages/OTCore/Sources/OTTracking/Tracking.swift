import Foundation
import OTModels
import OTLedger

/// What a geofence event did to the store, so the app can notify.
public struct InterpretationOutcome: Hashable, Sendable {
    public var event: LocationEvent
    public var opened: PresenceSession?
    public var closed: PresenceSession?
    public var reopened: Bool
    public var orphanExit: Bool
    public var ignored: Bool

    public init(event: LocationEvent, opened: PresenceSession? = nil, closed: PresenceSession? = nil,
                reopened: Bool = false, orphanExit: Bool = false, ignored: Bool = false) {
        self.event = event
        self.opened = opened
        self.closed = closed
        self.reopened = reopened
        self.orphanExit = orphanExit
        self.ignored = ignored
    }
}

/// See docs/SPEC.md section 5.1.
public enum GeofenceInterpreter {
    @discardableResult
    public static func apply(_ event: LocationEvent, to store: inout Store) -> InterpretationOutcome {
        fatalError("OTTracking.GeofenceInterpreter not implemented yet")
    }
}

/// See docs/SPEC.md section 5.2. Only one active (running or paused) session at a time.
public enum ManualTimer {
    public enum TimerError: Error, Equatable { case alreadyActive, nothingActive, notRunning, notPaused }

    @discardableResult
    public static func start(store: inout Store, category: String, note: String = "", countsAs: ManualCountsAs = .extra, at: Date) throws -> ManualSession {
        fatalError("OTTracking.ManualTimer not implemented yet")
    }

    @discardableResult
    public static func pause(store: inout Store, at: Date) throws -> ManualSession {
        fatalError("OTTracking.ManualTimer not implemented yet")
    }

    @discardableResult
    public static func resume(store: inout Store, at: Date) throws -> ManualSession {
        fatalError("OTTracking.ManualTimer not implemented yet")
    }

    @discardableResult
    public static func stop(store: inout Store, at: Date) throws -> ManualSession {
        fatalError("OTTracking.ManualTimer not implemented yet")
    }
}

/// See docs/SPEC.md section 5.3.
public enum InboxEngine {
    /// `dayResults` should cover at least the last 60 days through today.
    /// `monthlyExports` lists `yyyy-MM` keys for export files that exist on disk.
    public static func items(store: Store, dayResults: [DayResult], now: Date, monthlyExports: [String] = []) -> [InboxItem] {
        fatalError("OTTracking.InboxEngine not implemented yet")
    }
}
