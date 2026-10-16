import SwiftUI
import OTCore

/// Which "Add" editor the Today card is presenting.
enum HomeTodaySheet: String, Identifiable {
    case presence, manual, timeOff, adjustment

    var id: String { rawValue }
}

/// Today at a glance: schedule window, presence, delta so far, flags and a quick-add menu.
/// Tapping the summary opens the day's detail.
struct HomeTodayCard: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: HomeTodaySheet? = nil

    var body: some View {
        let result = model.todayResult
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: HomeRoute.day(model.today)) {
                summary(result)
            }
            .buttonStyle(.plain)
            actions(result)
        }
        .homeCard()
        .sheet(item: $sheet) { which in
            switch which {
            case .presence:
                PresenceEditorView(session: nil, defaultDay: model.today, onDone: { sheet = nil })
            case .manual:
                ManualSessionEditorView(session: nil, defaultDay: model.today, onDone: { sheet = nil })
            case .timeOff:
                TimeOffEditorView(entry: nil, defaultDay: model.today, onDone: { sheet = nil })
            case .adjustment:
                AdjustmentEditorView(adjustment: nil, defaultDay: model.today, onDone: { sheet = nil })
            }
        }
    }

    // MARK: Summary (tappable)

    @ViewBuilder
    private func summary(_ result: DayResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                    .font(.headline)
                Text(Format.dayShort(model.today, model.calendar))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                TagView(text: result.kind.label, color: result.kind.color)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Label(scheduleText(result), systemImage: "calendar")
                .font(.subheadline)
            presenceLine(result)
                .font(.subheadline)
            HStack {
                Text("So far today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                DeltaText(seconds: result.deltaSeconds, font: .title3.weight(.semibold))
            }
            if !result.flags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(result.flags, id: \.rawValue) { flag in
                        TagView(text: flag.label, color: HomeStyle.color(for: flag))
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func presenceLine(_ result: DayResult) -> some View {
        let cal = model.calendar
        if let open = model.openPresence {
            Label("At \(model.locationName(open.locationID)) since \(sinceText(open.enteredAt))", systemImage: "mappin.and.ellipse")
                .foregroundStyle(Color.blue)
        } else if let firstIn = result.firstIn {
            if let lastOut = result.lastOut {
                Label("In \(Format.time(firstIn, cal)) · Out \(Format.time(lastOut, cal))", systemImage: "arrow.left.arrow.right")
            } else {
                Label("In \(Format.time(firstIn, cal))", systemImage: "arrow.right.to.line")
            }
        } else {
            Label(emptyPresenceText(result), systemImage: "clock")
                .foregroundStyle(.secondary)
        }
    }

    private func emptyPresenceText(_ result: DayResult) -> String {
        result.hasWindow ? "No arrival recorded yet" : "Nothing recorded"
    }

    private func scheduleText(_ result: DayResult) -> String {
        guard let window = result.scheduledWindow else { return "No schedule today" }
        return "\(Format.time(window.start, model.calendar)) – \(Format.time(window.end, model.calendar))"
    }

    /// Time only when the open session started today, otherwise date and time.
    private func sinceText(_ date: Date) -> String {
        let cal = model.calendar
        if DayKey(date, calendar: cal) == model.today { return Format.time(date, cal) }
        return Format.dateTime(date, cal)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ result: DayResult) -> some View {
        HStack(spacing: 12) {
            if result.flags.contains(.earlyArrivalUncounted) {
                Button {
                    model.countEarlyArrival(day: model.today)
                } label: {
                    Label("Count early arrival (+\(Format.hm(result.extraBeforeSeconds)))", systemImage: "sunrise")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(Color.positive)
            }
            Spacer()
            Menu {
                Button {
                    sheet = .presence
                } label: {
                    Label("Arrival / departure", systemImage: "mappin.and.ellipse")
                }
                Button {
                    sheet = .manual
                } label: {
                    Label("Work elsewhere", systemImage: "laptopcomputer")
                }
                Button {
                    sheet = .timeOff
                } label: {
                    Label("Time off", systemImage: "sun.max")
                }
                Button {
                    sheet = .adjustment
                } label: {
                    Label("Adjustment", systemImage: "plus.forwardslash.minus")
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview {
    NavigationStack {
        HomeTodayCard()
    }
    .environment(AppModel.preview())
}
