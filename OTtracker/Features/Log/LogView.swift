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
                ForEach(weekStarts, id: \.self) { start in
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
            .navigationTitle("Log")
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

    /// Days of the week up to and including today, newest first.
    private func visibleDays(in weekStart: DayKey) -> [DayKey] {
        let cal = model.calendar
        let last = min(weekStart.adding(days: 6, calendar: cal), model.today)
        return Array(DayKey.days(from: weekStart, through: last, calendar: cal).reversed())
    }

    private var canShowOlder: Bool {
        guard let oldest = weekStarts.last else { return false }
        return oldest > model.earliestDay
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
            Spacer()
            DeltaText(seconds: total, font: .footnote.weight(.semibold))
        }
        .textCase(nil)
    }

    private var total: Int {
        days.reduce(0) { $0 + model.dayResult(for: $1).deltaSeconds }
    }
}

/// One day in the Log list.
struct LogDayRow: View {
    @Environment(AppModel.self) private var model
    let day: DayKey

    var body: some View {
        let r = model.dayResult(for: day)
        let cal = model.calendar
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.relativeDay(day, today: model.today, cal))
                    if r.kind != .workday {
                        TagView(text: r.kind.label, color: r.kind.color)
                    }
                }
                Text(inOut(r, cal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                DeltaText(seconds: r.deltaSeconds)
                Text(r.presenceSeconds > 0 ? Format.hm(r.presenceSeconds) : "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// "7:02 AM – 5:42 PM", "7:02 AM – …" while still there, or "—".
    private func inOut(_ r: DayResult, _ cal: Calendar) -> String {
        guard let first = r.firstIn else { return "—" }
        let out = r.lastOut.map { Format.time($0, cal) } ?? "…"
        return "\(Format.time(first, cal)) – \(out)"
    }
}

#Preview {
    LogView().environment(AppModel.preview())
}
