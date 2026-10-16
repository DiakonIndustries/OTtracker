import Foundation
import ActivityKit
import OTCore

/// Mirrors the active manual session into a Live Activity (lock screen / Dynamic Island).
@MainActor
final class LiveActivityService: LiveActivityServicing {
    private var currentSessionID: UUID?

    func sync(with session: ManualSession?, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let existing = Activity<TimerActivityAttributes>.activities
        guard let session, session.isActive else {
            for activity in existing {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            currentSessionID = nil
            return
        }
        let closed = session.segments.filter { !$0.isOpen }.reduce(0) { $0 + $1.interval(now: now).seconds }
        let state = TimerActivityAttributes.ContentState(accumulatedSeconds: closed,
                                                         runningSince: session.segments.last?.isOpen == true ? session.segments.last?.start : nil,
                                                         isPaused: session.state == .paused)
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = existing.first(where: { $0.attributes.sessionID == session.id }) {
            Task { await activity.update(content) }
            for other in existing where other.attributes.sessionID != session.id {
                Task { await other.end(nil, dismissalPolicy: .immediate) }
            }
        } else {
            for other in existing { Task { await other.end(nil, dismissalPolicy: .immediate) } }
            let attributes = TimerActivityAttributes(sessionID: session.id, category: session.category)
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                NSLog("Live Activity request failed: \(error.localizedDescription)")
            }
        }
        currentSessionID = session.id
    }
}

@MainActor
final class NoopLiveActivityService: LiveActivityServicing {
    func sync(with session: ManualSession?, now: Date) {}
}
