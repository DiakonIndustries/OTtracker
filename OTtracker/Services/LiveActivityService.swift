import Foundation
import ActivityKit
import OTCore

/// Mirrors the active manual session into a Live Activity (lock screen / Dynamic Island).
@MainActor
final class LiveActivityService: LiveActivityServicing {
    /// Session whose Live Activity was successfully requested; if it later vanishes from `activities`, the person removed it.
    private var requestedSessionID: UUID?
    /// What was last pushed to ActivityKit, so identical recomputes (every keystroke elsewhere) send nothing.
    private var lastSynced: (sessionID: UUID, state: TimerActivityAttributes.ContentState)?

    func sync(with session: ManualSession?, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let existing = Activity<TimerActivityAttributes>.activities
        guard let session, session.isActive else {
            for activity in existing { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            requestedSessionID = nil
            lastSynced = nil
            return
        }
        let closed = session.segments.filter { !$0.isOpen }.reduce(0) { $0 + $1.interval(now: now).seconds }
        let state = TimerActivityAttributes.ContentState(accumulatedSeconds: closed,
                                                         runningSince: session.segments.last?.isOpen == true ? session.segments.last?.start : nil,
                                                         isPaused: session.state == .paused)
        if let last = lastSynced, last.sessionID == session.id, last.state == state { return }
        let content = ActivityContent(state: state, staleDate: nil)
        for other in existing where other.attributes.sessionID != session.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        if let activity = existing.first(where: { $0.attributes.sessionID == session.id }) {
            Task { await activity.update(content) }
        } else if requestedSessionID != session.id {
            // Not created yet for this session (or the previous request threw): request it. Fails in the background by design.
            do {
                _ = try Activity.request(attributes: TimerActivityAttributes(sessionID: session.id, category: session.category),
                                         content: content, pushType: nil)
                requestedSessionID = session.id
            } catch {
                NSLog("Live Activity request failed: \(error.localizedDescription)")
                return // leave lastSynced unset so the next foreground recompute retries
            }
        }
        // else: created earlier and now gone -> the person removed it; do not bring it back.
        lastSynced = (session.id, state)
    }
}

@MainActor
final class NoopLiveActivityService: LiveActivityServicing {
    func sync(with session: ManualSession?, now: Date) {}
}
