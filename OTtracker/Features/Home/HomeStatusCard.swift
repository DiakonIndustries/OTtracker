import SwiftUI
import OTCore

/// What is happening right now, with the one action that matters:
/// a running timer (pause / stop), being at a work site (progress through the shift),
/// or neither (start a timer). Tapping "Today's details" opens the day's breakdown.
struct HomeStatusCard: View {
    @Environment(AppModel.self) private var model
    @State private var showStart = false
    @State private var confirmDiscard = false

    var body: some View {
        let result = model.todayResult
        VStack(alignment: .leading, spacing: 16) {
            if let timer = model.activeTimer {
                timerContent(timer)
            } else if let open = model.openPresence {
                atWorkContent(open, result)
            } else {
                idleContent(result)
            }
            if result.flags.contains(.earlyArrivalUncounted) {
                earlyArrivalButton(result)
            }
            Divider()
            NavigationLink(value: HomeRoute.day(model.today)) {
                HStack(spacing: 8) {
                    Text("Today's details")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    DeltaPill(seconds: result.deltaSeconds, font: .footnote.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .card()
        .sheet(isPresented: $showStart) {
            TimerStartSheet(onDone: { showStart = false })
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Discard this timer?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard timer", role: .destructive) {
                model.discardTimer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing from this timer will be logged.")
        }
    }

    // MARK: Timer running or paused

    @ViewBuilder
    private func timerContent(_ timer: ManualSession) -> some View {
        let running = timer.state == .running
        HStack(spacing: 8) {
            StatusDot(color: running ? Color.positive : Color.orange)
            Text(running ? "Timer running" : "Timer paused")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard timer", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: running ? 1.0 : 60.0)) { context in
                Text(DurationFormat.clockWithSeconds(timer.activeSeconds(now: context.date)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(running ? Color.primary : Color.secondary)
            }
            Text(timer.note.isEmpty ? timer.category : "\(timer.category) · \(timer.note)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        HStack(spacing: 12) {
            if running {
                Button {
                    model.pauseTimer()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    model.resumeTimer()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                model.stopTimer()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.headline)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    // MARK: At a work site

    @ViewBuilder
    private func atWorkContent(_ open: PresenceSession, _ result: DayResult) -> some View {
        let cal = model.calendar
        HStack(spacing: 12) {
            IconBadge(systemImage: "building.2.fill", color: .positive)
            VStack(alignment: .leading, spacing: 2) {
                Text("At \(model.locationName(open.locationID))")
                    .font(.title3.weight(.semibold))
                Text("Since \(sinceText(open.enteredAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(color: .positive)
        }
        if let window = result.scheduledWindow {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let total = max(1, window.end.timeIntervalSince(window.start))
                let done = min(max(now.timeIntervalSince(window.start) / total, 0), 1)
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: done)
                        .tint(now > window.end ? Color.positive : Color.accentColor)
                        .scaleEffect(x: 1, y: 1.6, anchor: .center)
                    HStack {
                        Text(Format.time(window.start, cal))
                        Spacer()
                        Text(shiftText(now: now, window: window))
                            .fontWeight(.semibold)
                            .foregroundStyle(now > window.end ? Color.positive : Color.primary)
                        Spacer()
                        Text(Format.time(window.end, cal))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        } else {
            Text("No shift today, so all of this time counts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func shiftText(now: Date, window: Interval) -> String {
        if now < window.start { return "Shift starts soon" }
        if now <= window.end { return "\(Format.hm(Int(window.end.timeIntervalSince(now)))) to go" }
        return "\(Format.hm(Int(now.timeIntervalSince(window.end)), signed: true)) overtime"
    }

    /// Time only when the session started today, otherwise date and time.
    private func sinceText(_ date: Date) -> String {
        let cal = model.calendar
        if DayKey(date, calendar: cal) == model.today { return Format.time(date, cal) }
        return Format.dateTime(date, cal)
    }

    // MARK: Nothing running

    @ViewBuilder
    private func idleContent(_ result: DayResult) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: idleSymbol(result), color: idleColor(result))
            VStack(alignment: .leading, spacing: 2) {
                Text(idleTitle(result))
                    .font(.title3.weight(.semibold))
                Text(idleSubtitle(result))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        VStack(spacing: 8) {
            Button {
                showStart = true
            } label: {
                Label("Start timer", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            Text("For work away from your sites. Paused time never counts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private func idleTitle(_ result: DayResult) -> String {
        switch result.kind {
        case .holiday: return model.store.holiday(on: model.today)?.name ?? "Holiday"
        case .weekend, .dayOff: return "Day off"
        case .excused: return "Excused today"
        case .workday:
            if result.lastOut != nil { return "Done for today" }
            if let window = result.scheduledWindow, model.now < window.start { return "Not started yet" }
            return "Away from work"
        }
    }

    private func idleSubtitle(_ result: DayResult) -> String {
        let cal = model.calendar
        if let lastOut = result.lastOut, result.kind == .workday {
            return "Left at \(Format.time(lastOut, cal))"
        }
        if let window = result.scheduledWindow {
            return "Shift \(Format.time(window.start, cal)) – \(Format.time(window.end, cal))"
        }
        return "Nothing scheduled. Anything you log counts as extra."
    }

    private func idleSymbol(_ result: DayResult) -> String {
        switch result.kind {
        case .holiday: return "gift.fill"
        case .weekend, .dayOff: return "sun.max.fill"
        case .excused: return "checkmark.seal.fill"
        case .workday: return result.lastOut != nil ? "moon.stars.fill" : "clock.fill"
        }
    }

    private func idleColor(_ result: DayResult) -> Color {
        switch result.kind {
        case .holiday, .weekend, .dayOff: return .orange
        case .excused: return .secondary
        case .workday: return .accentColor
        }
    }

    // MARK: Early arrival

    private func earlyArrivalButton(_ result: DayResult) -> some View {
        Button {
            model.countEarlyArrival(day: model.today)
        } label: {
            Label("Count early arrival \(Format.hm(result.extraBeforeSeconds, signed: true))", systemImage: "sunrise.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .buttonBorderShape(.capsule)
    }
}

#Preview {
    NavigationStack {
        HomeStatusCard().padding()
    }
    .environment(AppModel.preview())
}
