import SwiftUI
import OTCore

/// The manual timer: start, pause / resume, stop and discard. Elapsed time ticks live.
struct HomeTimerCard: View {
    @Environment(AppModel.self) private var model
    @State private var showStart = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let timer = model.activeTimer {
                activeContent(timer)
            } else {
                idleContent
            }
        }
        .homeCard()
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

    // MARK: Running or paused

    @ViewBuilder
    private func activeContent(_ timer: ManualSession) -> some View {
        HStack {
            Label("Timer", systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TagView(text: timer.state == .running ? "Running" : "Paused",
                    color: timer.state == .running ? Color.positive : Color.orange)
        }
        Text(timer.category)
            .font(.headline)
        if !timer.note.isEmpty {
            Text(timer.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        TimelineView(.periodic(from: .now, by: timer.state == .running ? 1.0 : 60.0)) { context in
            Text(DurationFormat.clockWithSeconds(timer.activeSeconds(now: context.date)))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timer.state == .running ? Color.primary : Color.secondary)
        }
        Text(HomeTimerCard.caption(for: timer.countsAs))
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 12) {
            if timer.state == .running {
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
        .controlSize(.large)
        Button("Discard timer", role: .destructive) {
            confirmDiscard = true
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    // MARK: Nothing running

    @ViewBuilder
    private var idleContent: some View {
        Label("Timer", systemImage: "timer")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Working away from a site?")
            .font(.headline)
        Text("Track home work, after hours, travel or anything else. Paused time never counts.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Button {
            showStart = true
        } label: {
            Label("Start timer", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    static func caption(for countsAs: ManualCountsAs) -> String {
        switch countsAs {
        case .extra: return "Counts as extra time"
        case .regular: return "Fills your schedule"
        }
    }
}

#Preview {
    HomeTimerCard().environment(AppModel.preview())
}
