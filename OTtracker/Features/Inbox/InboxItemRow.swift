import SwiftUI
import OTCore

// MARK: - Style

/// Icon, colour and button layout per Inbox item.
enum InboxStyle {
    static func symbol(for kind: InboxKind) -> String {
        switch kind {
        case .gap: return "arrow.triangle.branch"
        case .noShow: return "calendar.badge.exclamationmark"
        case .exit: return "figure.walk.departure"
        case .earlyArrival: return "sunrise"
        case .timer: return "timer"
        case .staleOpen: return "clock.badge.questionmark"
        case .orphanExit: return "location.slash"
        case .monthlyExport: return "doc.richtext"
        }
    }

    static func color(for kind: InboxKind) -> Color {
        switch kind {
        case .gap: return .orange
        case .noShow: return .red
        case .exit: return .blue
        case .earlyArrival: return .teal
        case .timer: return .purple
        case .staleOpen: return .orange
        case .orphanExit: return .pink
        case .monthlyExport: return .green
        }
    }

    /// Up to three buttons per row, split as evenly as possible (6 → 3+3, 5 → 3+2, 4 → 2+2).
    static func rows(for actions: [InboxAction]) -> [[InboxAction]] {
        guard actions.count > 3 else { return [actions] }
        let rowCount = (actions.count + 2) / 3
        let perRow = (actions.count + rowCount - 1) / rowCount
        var out: [[InboxAction]] = []
        var index = 0
        while index < actions.count {
            let end = min(index + perRow, actions.count)
            out.append(Array(actions[index..<end]))
            index = end
        }
        return out
    }
}

// MARK: - Row

/// One Inbox question: icon, title (opens the day), detail, what was already applied, and the actions.
struct InboxItemRow: View {
    @Environment(AppModel.self) private var model

    private let item: InboxItem
    private let onAction: (InboxAction) -> Void

    init(item: InboxItem, onAction: @escaping (InboxAction) -> Void) {
        self.item = item
        self.onAction = onAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item.day) {
                header
            }
            actionRows
        }
        .padding(.vertical, 4)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: InboxStyle.symbol(for: item.kind))
                .font(.title3)
                .foregroundStyle(InboxStyle.color(for: item.kind))
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let applied = item.defaultApplied, !applied.isEmpty {
                        TagView(text: applied, color: .orange)
                    }
                    stamp
                }
            }
        }
    }

    /// When it happened; a live elapsed counter for a timer that is still going.
    @ViewBuilder
    private var stamp: some View {
        if item.kind == .timer, let session = activeTimerSession {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timerLabel(session, at: context.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(when)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// "Running 4:12:07" or "Paused 3:58:00".
    private func timerLabel(_ session: ManualSession, at date: Date) -> String {
        let state = session.state == .running ? "Running" : "Paused"
        return "\(state) \(DurationFormat.clockWithSeconds(session.activeSeconds(now: date)))"
    }

    private var activeTimerSession: ManualSession? {
        guard let id = item.subjectID, let session = model.store.manualSession(id: id), session.isActive else { return nil }
        return session
    }

    private var when: String {
        let cal = model.calendar
        let day = Format.relativeDay(item.day, today: model.today, cal)
        switch item.kind {
        case .noShow, .monthlyExport:
            return day
        case .gap, .exit, .earlyArrival, .timer, .staleOpen, .orphanExit:
            return "\(day) · \(Format.time(item.occurredAt, cal))"
        }
    }

    // MARK: Actions

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(InboxStyle.rows(for: item.actions).enumerated()), id: \.offset) { row in
                HStack(spacing: 8) {
                    ForEach(row.element, id: \.self) { action in
                        button(for: action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func button(for action: InboxAction) -> some View {
        if action.isDestructive {
            Button(action.title, role: .destructive) { onAction(action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .lineLimit(1)
        } else {
            Button(action.title) { onAction(action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
        }
    }
}

#Preview {
    NavigationStack {
        List {
            InboxItemRow(item: InboxItem(key: "noshow:2026-10-14", kind: .noShow, day: DayKey(year: 2026, month: 10, day: 14),
                                         occurredAt: Date(), title: "No show on Tue, Oct 14", detail: "Scheduled 7:00 AM – 3:30 PM.",
                                         defaultApplied: "Deducted 8h 30m",
                                         actions: [.addTimeOff(kind: .pto), .addTimeOff(kind: .personal), .markRemoteDay,
                                                   .enterHours, .excuseDay, .keepDeficit])) { _ in }
            InboxItemRow(item: InboxItem(key: "exit:preview", kind: .exit, day: DayKey(year: 2026, month: 10, day: 14),
                                         occurredAt: Date(), title: "Left Plant A at 5:42 PM", detail: "+42m logged.",
                                         actions: [.confirm, .adjustSession, .removeSession])) { _ in }
        }
    }
    .environment(AppModel.preview())
}
