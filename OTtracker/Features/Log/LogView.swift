import SwiftUI
import OTCore

// MARK: - Shared Log helpers

/// The four "add" actions offered by the Log screens.
enum LogAddKind: String, CaseIterable, Identifiable {
    case presence, manual, adjustment, timeOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presence: return "Arrival / departure"
        case .manual: return "Work elsewhere"
        case .adjustment: return "Adjustment"
        case .timeOff: return "Time off"
        }
    }

    var systemImage: String {
        switch self {
        case .presence: return "mappin.and.ellipse"
        case .manual: return "laptopcomputer"
        case .adjustment: return "plusminus"
        case .timeOff: return "sun.max"
        }
    }
}

/// Every sheet a Log screen can present, so each screen needs a single `.sheet(item:)`.
enum LogSheet: Identifiable {
    case add(LogAddKind)
    case presence(PresenceSession)
    case manual(ManualSession)
    case timeOff(TimeOffEntry)
    case adjustment(Adjustment)

    var id: String {
        switch self {
        case .add(let kind): return "add-\(kind.rawValue)"
        case .presence(let s): return "presence-\(s.id.uuidString)"
        case .manual(let m): return "manual-\(m.id.uuidString)"
        case .timeOff(let t): return "timeoff-\(t.id.uuidString)"
        case .adjustment(let a): return "adjustment-\(a.id.uuidString)"
        }
    }
}

/// "+" toolbar menu shared by the Log list and the day detail.
struct LogAddMenu: View {
    @Binding var sheet: LogSheet?

    var body: some View {
        Menu {
            ForEach(LogAddKind.allCases) { kind in
                Button {
                    sheet = .add(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }
}

/// Builds the editor for a `LogSheet`. `day` is the default day for new records.
struct LogSheetView: View {
    let sheet: LogSheet
    let day: DayKey
    let onDone: () -> Void

    var body: some View {
        switch sheet {
        case .add(let kind):
            switch kind {
            case .presence:
                PresenceEditorView(session: nil, defaultDay: day, onDone: onDone)
            case .manual:
                ManualSessionEditorView(session: nil, defaultDay: day, onDone: onDone)
            case .adjustment:
                AdjustmentEditorView(adjustment: nil, defaultDay: day, onDone: onDone)
            case .timeOff:
                TimeOffEditorView(entry: nil, defaultDay: day, onDone: onDone)
            }
        case .presence(let s):
            PresenceEditorView(session: s, defaultDay: day, onDone: onDone)
        case .manual(let m):
            ManualSessionEditorView(session: m, defaultDay: day, onDone: onDone)
        case .timeOff(let t):
            TimeOffEditorView(entry: t, defaultDay: day, onDone: onDone)
        case .adjustment(let a):
            AdjustmentEditorView(adjustment: a, defaultDay: day, onDone: onDone)
        }
    }
}

// MARK: - Log list

/// Days newest first, grouped by week. Tapping a day opens `DayDetailView`.
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [DayKey] = []
    @State private var weeksShown = 8
    @State private var sheet: LogSheet?

    init() {}

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(weekStarts.filter { !visibleDays(in: $0).isEmpty }, id: \.self) { start in
                    let days = visibleDays(in: start)
                    Section {
                        ForEach(days, id: \.self) { day in
                            NavigationLink(value: day) {
                                LogDayRow(day: day)
                            }
                        }
                    } header: {
                        LogWeekHeader(weekStart: start, days: days)
                    }
                }
                if canShowOlder {
                    Section {
                        Button("Show older weeks") { weeksShown += 8 }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: DayKey.self) { day in
                DayDetailView(day: day)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LogAddMenu(sheet: $sheet)
                }
            }
        }
        .sheet(item: $sheet) { s in
            LogSheetView(sheet: s, day: model.today) { sheet = nil }
        }
        .onAppear { handleRoute() }
        .onChange(of: model.pendingRoute) { _, _ in handleRoute() }
    }

    // MARK: Weeks

    /// Week starts, current week first, stepping back 7 days at a time.
    private var weekStarts: [DayKey] {
        let cal = model.calendar
        let current = Format.weekStart(of: model.today, cal)
        return (0..<weeksShown).map { current.adding(days: -7 * $0, calendar: cal) }
    }

    /// Days of the week from tracking start up to and including today, newest first.
    private func visibleDays(in weekStart: DayKey) -> [DayKey] {
        let cal = model.calendar
        let first = max(weekStart, model.trackingStart)
        let last = min(weekStart.adding(days: 6, calendar: cal), model.today)
        guard first <= last else { return [] }
        return Array(DayKey.days(from: first, through: last, calendar: cal).reversed())
    }

    private var canShowOlder: Bool {
        guard let oldest = weekStarts.last else { return false }
        return oldest > model.trackingStart
    }

    // MARK: Routes

    private func handleRoute() {
        guard let route = model.pendingRoute else { return }
        let cal = model.calendar
        switch route {
        case .day(let day):
            path = [day]
        case .editPresence(let id):
            guard let session = model.store.presenceSession(id: id) else {
                model.consumeRoute()
                return
            }
            path = [DayKey(session.enteredAt, calendar: cal)]
            sheet = .presence(session)
        case .editManual(let id):
            guard let session = model.store.manualSession(id: id) else {
                model.consumeRoute()
                return
            }
            path = [DayKey(session.startedAt ?? session.createdAt, calendar: cal)]
            sheet = .manual(session)
        case .exportMonth, .locations, .importFile, .export:
            // Not ours; another feature consumes these.
            return
        }
        model.consumeRoute()
    }
}

// MARK: - Rows

/// Section header: the week's date range and its total delta.
struct LogWeekHeader: View {
    @Environment(AppModel.self) private var model
    let weekStart: DayKey
    let days: [DayKey]

    var body: some View {
        HStack {
            Text(Format.weekRange(start: weekStart, model.calendar))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            DeltaText(seconds: total, font: .subheadline.weight(.semibold))
        }
        .textCase(nil)
    }

    private var total: Int {
        days.reduce(0) { $0 + model.dayResult(for: $1).deltaSeconds }
    }
}

/// One day in History: a date block, what happened, and the day's delta.
struct LogDayRow: View {
    @Environment(AppModel.self) private var model
    let day: DayKey

    var body: some View {
        let r = model.dayResult(for: day)
        let cal = model.calendar
        let isToday = day == model.today
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 0) {
                Text(day.weekday(in: cal).shortName.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isToday ? Color.white.opacity(0.85) : Color.secondary)
                Text("\(day.day)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isToday ? Color.white : Color.primary)
            }
            .frame(width: 46, height: 46)
            .background(isToday ? Color.accentColor : Theme.page,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title(r, cal))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(r.firstIn == nil && r.kind != .workday ? Color.secondary : Color.primary)
                    .monospacedDigit()
                Text(subtitle(r))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if r.deltaSeconds != 0 || r.hasWindow {
                DeltaPill(seconds: r.deltaSeconds, font: .footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    /// "7:02 AM – 5:42 PM", "7:02 AM – now" while still there, else what kind of day it was.
    private func title(_ r: DayResult, _ cal: Calendar) -> String {
        if let first = r.firstIn {
            let out = r.lastOut.map { Format.time($0, cal) } ?? "now"
            return "\(Format.time(first, cal)) – \(out)"
        }
        if r.timeOffSeconds > 0 { return "Time off" }
        switch r.kind {
        case .holiday: return model.store.holiday(on: day)?.name ?? "Holiday"
        case .weekend: return "Weekend"
        case .dayOff: return "Day off"
        case .excused: return "Excused"
        case .workday: return day == model.today ? "Not in yet" : "No time recorded"
        }
    }

    private func subtitle(_ r: DayResult) -> String {
        var parts: [String] = []
        if r.presenceSeconds > 0 { parts.append("\(Format.hm(r.presenceSeconds)) on site") }
        if r.manualExtraSeconds + r.manualRegularSeconds > 0 {
            parts.append("\(Format.hm(r.manualExtraSeconds + r.manualRegularSeconds)) elsewhere")
        }
        if r.timeOffSeconds > 0 { parts.append("\(Format.hm(r.timeOffSeconds)) off") }
        if parts.isEmpty { return r.kind == .workday ? "Scheduled workday" : r.kind.label }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    LogView().environment(AppModel.preview())
}
