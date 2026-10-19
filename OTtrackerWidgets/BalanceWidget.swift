import SwiftUI
import WidgetKit
import OTCore

// MARK: - Timeline

struct BalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), snapshot: WidgetSnapshotStore.loadOrPlaceholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        let snapshot = context.isPreview ? WidgetSnapshotStore.loadOrPlaceholder() : WidgetSnapshotStore.load()
        completion(BalanceEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let now = Date()
        let entry = BalanceEntry(date: now, snapshot: WidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Widget

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentifiers.widgetKind, provider: BalanceProvider()) { entry in
            BalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Overtime balance")
        .description("Your current bank balance, this month's extra time and a start-timer button.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Shared helpers

/// Colours used on the dark widget background.
enum WidgetsPalette {
    static let text = Color.white
    static let dim = Color.white.opacity(0.7)
    static let faint = Color.white.opacity(0.25)
    static let start = Color.accentColor
    static let stop = Color.red.opacity(0.85)
    static let pill = Color.white.opacity(0.2)
}

/// What the snapshot says about the manual timer, resolved once per render.
struct WidgetsTimerStatus {
    enum Mode { case idle, running, paused }

    let mode: Mode
    let category: String
    /// The instant a count-up `Text(timerInterval:)` must start from so it reads accumulated + elapsed.
    let countUpStart: Date
    let accumulatedSeconds: Int

    init(snapshot: WidgetSnapshot, now: Date) {
        category = snapshot.timerCategory ?? "Timer"
        accumulatedSeconds = snapshot.timerAccumulatedSeconds
        countUpStart = (snapshot.timerStartedAt ?? now).addingTimeInterval(-Double(snapshot.timerAccumulatedSeconds))
        if snapshot.timerRunning {
            mode = .running
        } else if snapshot.timerCategory != nil {
            // The app publishes a category for any active (running or paused) session.
            mode = .paused
        } else {
            mode = .idle
        }
    }
}

/// A small capsule button face for `Link`s inside widgets and Live Activities.
struct WidgetsCapsuleLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = WidgetsPalette.pill

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
            .foregroundStyle(WidgetsPalette.text)
    }
}

// MARK: - Views

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BalanceEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                BalanceWidgetMediumView(snapshot: entry.snapshot, now: entry.date)
            default:
                BalanceWidgetSmallView(snapshot: entry.snapshot, now: entry.date)
            }
        }
        .foregroundStyle(WidgetsPalette.text)
        .containerBackground(for: .widget) { Color("WidgetBackground") }
        .widgetURL(DeepLink.home.url)
    }
}

/// Balance, this month's gross extra time, and the running timer if any.
struct BalanceWidgetSmallView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let status = WidgetsTimerStatus(snapshot: snapshot, now: now)
        VStack(alignment: .leading, spacing: 4) {
            Text("Balance")
                .font(.caption)
                .foregroundStyle(WidgetsPalette.dim)
            Text(DurationFormat.hm(snapshot.balanceSeconds, signed: true))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            switch status.mode {
            case .running:
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(timerInterval: status.countUpStart...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
            case .paused:
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                    Text(DurationFormat.clockWithSeconds(status.accumulatedSeconds))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(WidgetsPalette.dim)
                .lineLimit(1)
            case .idle:
                EmptyView()
            }
            Text("This month " + DurationFormat.hm(snapshot.monthGrossExtraSeconds, signed: true))
                .font(.caption2)
                .foregroundStyle(WidgetsPalette.dim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Left: the small layout. Right: today's delta, the Inbox count and the timer button.
struct BalanceWidgetMediumView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let status = WidgetsTimerStatus(snapshot: snapshot, now: now)
        HStack(alignment: .top, spacing: 12) {
            BalanceWidgetSmallView(snapshot: snapshot, now: now)
            Rectangle()
                .fill(WidgetsPalette.faint)
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Today")
                    .font(.caption)
                    .foregroundStyle(WidgetsPalette.dim)
                Text(DurationFormat.hm(snapshot.todayDeltaSeconds, signed: true))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                if snapshot.inboxCount > 0 {
                    Link(destination: DeepLink.inbox.url) {
                        Label("\(snapshot.inboxCount) to review", systemImage: "tray.full")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                switch status.mode {
                case .idle:
                    Link(destination: DeepLink.timerStart.url) {
                        WidgetsCapsuleLabel(title: "Start timer", systemImage: "play.fill", tint: WidgetsPalette.start)
                    }
                case .running:
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text(status.category)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(timerInterval: status.countUpStart...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(.caption)
                    Link(destination: DeepLink.timerStop.url) {
                        WidgetsCapsuleLabel(title: "Stop", systemImage: "stop.fill", tint: WidgetsPalette.stop)
                    }
                case .paused:
                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle")
                        Text(status.category)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DurationFormat.clockWithSeconds(status.accumulatedSeconds))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(WidgetsPalette.dim)
                    HStack(spacing: 6) {
                        Link(destination: DeepLink.timerResume.url) {
                            WidgetsCapsuleLabel(title: "Resume", systemImage: "play.fill", tint: WidgetsPalette.start)
                        }
                        Link(destination: DeepLink.timerStop.url) {
                            WidgetsCapsuleLabel(title: "Stop", systemImage: "stop.fill", tint: WidgetsPalette.stop)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Previews

extension WidgetSnapshot {
    /// Sample with a running timer and two Inbox items, for previews only.
    static var widgetsRunningSample: WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(),
                       balanceSeconds: 11 * 3600 + 20 * 60,
                       monthGrossExtraSeconds: 3 * 3600 + 15 * 60,
                       todayDeltaSeconds: 2520,
                       timerRunning: true,
                       timerCategory: "Home work",
                       timerStartedAt: Date().addingTimeInterval(-25 * 60),
                       timerAccumulatedSeconds: 10 * 60,
                       inboxCount: 2)
    }

    /// Sample with a paused timer, for previews only.
    static var widgetsPausedSample: WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(),
                       balanceSeconds: -(1 * 3600 + 5 * 60),
                       monthGrossExtraSeconds: 45 * 60,
                       todayDeltaSeconds: -900,
                       timerRunning: false,
                       timerCategory: "After hours",
                       timerStartedAt: nil,
                       timerAccumulatedSeconds: 35 * 60 + 12,
                       inboxCount: 0)
    }
}

#Preview(as: .systemSmall) {
    BalanceWidget()
} timeline: {
    BalanceEntry(date: .now, snapshot: .placeholder)
    BalanceEntry(date: .now, snapshot: .widgetsRunningSample)
}

#Preview(as: .systemMedium) {
    BalanceWidget()
} timeline: {
    BalanceEntry(date: .now, snapshot: .placeholder)
    BalanceEntry(date: .now, snapshot: .widgetsRunningSample)
    BalanceEntry(date: .now, snapshot: .widgetsPausedSample)
}
