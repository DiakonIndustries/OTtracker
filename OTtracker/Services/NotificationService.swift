import Foundation
import UserNotifications
import OTCore

@MainActor
final class NotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var isAuthorized = false
    var onResponse: ((NotificationResponse) -> Void)?

    enum Category: String { case exit = "EXIT", early = "EARLY", orphan = "ORPHAN", timer = "TIMER", export = "EXPORT", generic = "GENERIC" }
    enum ActionID: String {
        case confirmExit = "CONFIRM_EXIT", adjustExit = "ADJUST_EXIT"
        case countEarly = "COUNT_EARLY"
        case stopTimer = "STOP_TIMER", stillWorking = "STILL_WORKING"
        case emailExport = "EMAIL_EXPORT", shareExport = "SHARE_EXPORT"
    }

    static let timerNudgeIdentifier = "timer-nudge"
    /// Stable per-session id so a later exit for the same session replaces the delivered card and a flap reopen can remove it.
    static func exitIdentifier(_ sessionID: UUID) -> String { "exit-\(sessionID.uuidString)" }

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
        Task { await refreshAuthorization() }
    }

    private func registerCategories() {
        let exit = UNNotificationCategory(identifier: Category.exit.rawValue, actions: [
            UNNotificationAction(identifier: ActionID.confirmExit.rawValue, title: "Confirm", options: []),
            UNNotificationAction(identifier: ActionID.adjustExit.rawValue, title: "Adjust", options: [.foreground]),
        ], intentIdentifiers: [], options: [])
        let early = UNNotificationCategory(identifier: Category.early.rawValue, actions: [
            UNNotificationAction(identifier: ActionID.countEarly.rawValue, title: "Count it", options: []),
        ], intentIdentifiers: [], options: [])
        let timer = UNNotificationCategory(identifier: Category.timer.rawValue, actions: [
            UNNotificationAction(identifier: ActionID.stopTimer.rawValue, title: "Stop now", options: []),
            UNNotificationAction(identifier: ActionID.stillWorking.rawValue, title: "Still working", options: []),
        ], intentIdentifiers: [], options: [])
        let export = UNNotificationCategory(identifier: Category.export.rawValue, actions: [
            UNNotificationAction(identifier: ActionID.emailExport.rawValue, title: "Email", options: [.foreground]),
            UNNotificationAction(identifier: ActionID.shareExport.rawValue, title: "Share", options: [.foreground]),
        ], intentIdentifiers: [], options: [])
        let orphan = UNNotificationCategory(identifier: Category.orphan.rawValue, actions: [], intentIdentifiers: [], options: [])
        let generic = UNNotificationCategory(identifier: Category.generic.rawValue, actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([exit, early, timer, export, orphan, generic])
    }

    private func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func authorizationStatus() async -> Bool {
        await refreshAuthorization()
        return isAuthorized
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    func post(_ notification: AppNotification) {
        let content = UNMutableNotificationContent()
        var identifier = UUID().uuidString
        var trigger: UNNotificationTrigger? = nil
        switch notification {
        case .exitPosted(let sessionID, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.exit.rawValue
            content.userInfo = ["sessionID": sessionID.uuidString]
            content.threadIdentifier = "exits"
            identifier = NotificationService.exitIdentifier(sessionID)
        case .earlyArrival(let day, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.early.rawValue
            content.userInfo = ["day": day.isoString]
            identifier = "early-\(day.isoString)"
        case .orphanExit(let eventID, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.orphan.rawValue
            content.userInfo = ["eventID": eventID.uuidString, "link": DeepLink.inbox.url.absoluteString]
        case .timerNudge(let sessionID, let fireAt, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.timer.rawValue
            content.userInfo = ["sessionID": sessionID.uuidString]
            identifier = NotificationService.timerNudgeIdentifier
            let delay = max(1, fireAt.timeIntervalSinceNow)
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        case .monthlyExport(let month, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.export.rawValue
            content.userInfo = ["month": month]
            identifier = "export-\(month)"
        case .generic(let id, let title, let body):
            content.title = title; content.body = body
            content.categoryIdentifier = Category.generic.rawValue
            identifier = id
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error { NSLog("Notification failed: \(error.localizedDescription)") }
        }
    }

    func cancelTimerNudge() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationService.timerNudgeIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [NotificationService.timerNudgeIdentifier])
    }

    func cancelExitNotification(sessionID: UUID) {
        let id = NotificationService.exitIdentifier(sessionID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let sessionID = (info["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        let day = (info["day"] as? String).flatMap(DayKey.init(iso:))
        let month = info["month"] as? String

        var result: NotificationResponse? = nil
        switch (category, action) {
        case (_, ActionID.confirmExit.rawValue): if let sessionID { result = .confirmExit(sessionID: sessionID) }
        case (_, ActionID.adjustExit.rawValue): if let sessionID { result = .adjustExit(sessionID: sessionID) }
        case (_, ActionID.countEarly.rawValue): if let day { result = .countEarlyArrival(day: day) }
        case (_, ActionID.stopTimer.rawValue): if let sessionID { result = .stopTimer(sessionID: sessionID) }
        case (_, ActionID.stillWorking.rawValue): if let sessionID { result = .timerStillWorking(sessionID: sessionID) }
        case (_, ActionID.emailExport.rawValue): if let month { result = .emailExport(month: month) }
        case (_, ActionID.shareExport.rawValue): if let month { result = .shareExport(month: month) }
        case (Category.exit.rawValue, UNNotificationDefaultActionIdentifier): if let sessionID { result = .adjustExit(sessionID: sessionID) }
        case (Category.timer.rawValue, UNNotificationDefaultActionIdentifier): result = .open(.home)
        case (Category.export.rawValue, UNNotificationDefaultActionIdentifier): result = .open(.inbox)
        case (Category.early.rawValue, UNNotificationDefaultActionIdentifier): result = .open(.inbox)
        case (Category.orphan.rawValue, UNNotificationDefaultActionIdentifier): result = .open(.inbox)
        case (_, UNNotificationDefaultActionIdentifier): result = .open(.home)
        default: break
        }
        if let result {
            await MainActor.run { self.onResponse?(result) }
        }
    }
}

@MainActor
final class NoopNotificationService: NotificationServicing {
    var isAuthorized = false
    var onResponse: ((NotificationResponse) -> Void)?
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> Bool { false }
    func post(_ notification: AppNotification) {}
    func cancelTimerNudge() {}
    func cancelExitNotification(sessionID: UUID) {}
}
