import Foundation
import CoreLocation
import OTCore

/// A geofence crossing reported by the device.
struct RegionCrossing: Hashable {
    var locationID: UUID
    var kind: LocationEventKind
    var at: Date
    /// True when this comes from a `didDetermineState` callback rather than `didEnterRegion` / `didExitRegion`.
    /// CoreLocation delivers that callback after `requestState` *and* on every boundary transition (right
    /// before the matching enter/exit), so `at` is only the moment the state was observed, never a crossing time.
    var inferredFromState: Bool
}

@MainActor
protocol LocationServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    var onCrossing: ((RegionCrossing) -> Void)? { get set }
    func requestWhenInUse()
    func requestAlways()
    /// Makes the monitored regions match `locations` (active ones only, max 20).
    func syncRegions(_ locations: [WorkLocation])
    /// Asks the system whether we are currently inside each region.
    func refreshCurrentState()
}

/// What the app can notify about. Each case maps to a notification category.
enum AppNotification: Hashable {
    case exitPosted(sessionID: UUID, title: String, body: String)
    case earlyArrival(day: DayKey, title: String, body: String)
    case orphanExit(eventID: UUID, title: String, body: String)
    case timerNudge(sessionID: UUID, fireAt: Date, title: String, body: String)
    case monthlyExport(month: String, title: String, body: String)
    case generic(id: String, title: String, body: String)
}

/// Taps on notification actions, delivered back to the model.
enum NotificationResponse: Hashable {
    case open(DeepLink)
    case confirmExit(sessionID: UUID)
    case adjustExit(sessionID: UUID)
    case countEarlyArrival(day: DayKey)
    case stopTimer(sessionID: UUID)
    case timerStillWorking(sessionID: UUID)
    case emailExport(month: String)
    case shareExport(month: String)
}

@MainActor
protocol NotificationServicing: AnyObject {
    /// Last known authorization; refreshed asynchronously, so prefer `authorizationStatus()` for a fresh answer.
    var isAuthorized: Bool { get }
    var onResponse: ((NotificationResponse) -> Void)? { get set }
    func requestAuthorization() async -> Bool
    /// Asks the system for the current authorization and returns whether notifications may be shown.
    func authorizationStatus() async -> Bool
    func post(_ notification: AppNotification)
    func cancelTimerNudge()
    /// Removes the exit notification for `sessionID` (pending or delivered); used when a flap reopen undoes an exit.
    func cancelExitNotification(sessionID: UUID)
}

@MainActor
protocol LiveActivityServicing: AnyObject {
    /// Starts, updates or ends the Live Activity to mirror the active manual session.
    func sync(with session: ManualSession?, now: Date)
}

struct BackupInfo: Identifiable, Hashable {
    var url: URL
    var modified: Date
    var sizeBytes: Int
    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

protocol BackupServicing: AnyObject {
    /// False when iCloud Drive is unavailable (not signed in, or entitlement missing).
    func isAvailable() async -> Bool
    func write(_ data: Data, now: Date) async throws -> URL
    func list() async throws -> [BackupInfo]
    func read(_ info: BackupInfo) async throws -> Data
}

@MainActor
protocol WidgetBridging: AnyObject {
    func publish(_ snapshot: WidgetSnapshot)
}
