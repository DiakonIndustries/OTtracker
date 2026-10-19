import SwiftUI
import WidgetKit
import ActivityKit
import OTCore

/// Lock-screen / Dynamic Island view of the running manual timer.
/// The app drives it through `LiveActivityService`; every button here is a deep link back into the app.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            TimerLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(Color.white)
                .widgetURL(DeepLink.home.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text(context.attributes.category)
                            .lineLimit(1)
                    }
                    .font(.headline)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        if context.state.isPaused {
                            Text("Paused")
                                .font(.caption)
                                .foregroundStyle(WidgetsPalette.dim)
                        }
                        TimerLiveActivityElapsedText(state: context.state)
                            .font(.headline)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TimerLiveActivityButtons(isPaused: context.state.isPaused)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                TimerLiveActivityElapsedText(state: context.state)
                    .font(.caption)
                    .minimumScaleFactor(0.7)
                    .frame(width: 60)
            } minimal: {
                Image(systemName: "timer")
            }
            .widgetURL(DeepLink.home.url)
            .keylineTint(Color.white)
        }
    }
}

// MARK: - Elapsed time

/// Live count-up while running; frozen `h:mm:ss` of the accumulated time while paused.
struct TimerLiveActivityElapsedText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if !state.isPaused, let since = state.runningSince {
            Text(timerInterval: countUpStart(from: since)...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text(DurationFormat.clockWithSeconds(state.accumulatedSeconds))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// Shift the open segment's start back by the closed segments so the timer reads total active time.
    private func countUpStart(from since: Date) -> Date {
        since.addingTimeInterval(-Double(state.accumulatedSeconds))
    }
}

// MARK: - Buttons

/// Pause / Resume and Stop as deep links, side by side.
struct TimerLiveActivityButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Link(destination: isPaused ? DeepLink.timerResume.url : DeepLink.timerPause.url) {
                WidgetsCapsuleLabel(title: isPaused ? "Resume" : "Pause",
                                    systemImage: isPaused ? "play.fill" : "pause.fill",
                                    tint: WidgetsPalette.pill)
            }
            Link(destination: DeepLink.timerStop.url) {
                WidgetsCapsuleLabel(title: "Stop", systemImage: "stop.fill", tint: WidgetsPalette.stop)
            }
        }
    }
}

/// Round icon-only link used on the lock screen where space is tight.
struct TimerLiveActivityIconLink: View {
    let destination: URL
    let systemImage: String
    var tint: Color = WidgetsPalette.pill

    var body: some View {
        Link(destination: destination) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(tint, in: Circle())
                .foregroundStyle(WidgetsPalette.text)
        }
    }
}

// MARK: - Lock screen

struct TimerLiveActivityLockScreenView: View {
    let context: ActivityViewContext<TimerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.category)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    TimerLiveActivityElapsedText(state: context.state)
                        .font(.title3.weight(.semibold))
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.caption)
                            .foregroundStyle(WidgetsPalette.dim)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                TimerLiveActivityIconLink(destination: context.state.isPaused ? DeepLink.timerResume.url : DeepLink.timerPause.url,
                                          systemImage: context.state.isPaused ? "play.fill" : "pause.fill")
                TimerLiveActivityIconLink(destination: DeepLink.timerStop.url,
                                          systemImage: "stop.fill",
                                          tint: WidgetsPalette.stop)
            }
        }
        .padding()
        .foregroundStyle(WidgetsPalette.text)
    }
}

// MARK: - Previews

#Preview("Lock screen", as: .content, using: TimerActivityAttributes(sessionID: UUID(), category: "Home work")) {
    TimerLiveActivity()
} contentStates: {
    TimerActivityAttributes.ContentState(accumulatedSeconds: 10 * 60, runningSince: Date().addingTimeInterval(-5 * 60), isPaused: false)
    TimerActivityAttributes.ContentState(accumulatedSeconds: 35 * 60 + 12, runningSince: nil, isPaused: true)
}
