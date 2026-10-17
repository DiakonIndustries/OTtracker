import SwiftUI
import OTCore

// MARK: - Text helpers

/// Short labels for enums shown in the Log screens.
enum LogText {
    static func source(_ s: EventSource) -> String {
        switch s {
        case .geofence: return "Geofence"
        case .manual: return "Entered by hand"
        case .imported: return "Imported"
        }
    }

    static func countsAs(_ c: ManualCountsAs) -> String {
        switch c {
        case .extra: return "Extra time"
        case .regular: return "Regular"
        }
    }

    static func state(_ s: ManualSession.State) -> String {
        switch s {
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    static func eventKind(_ k: LocationEventKind) -> String {
        switch k {
        case .enter: return "Arrived"
        case .exit: return "Left"
        }
    }

    /// "7:00 PM – 8:15 PM"; "7:00 PM – now" while open; the end carries its date when it is on another day.
    static func range(_ start: Date, _ end: Date?, _ cal: Calendar) -> String {
        let a = Format.time(start, cal)
        guard let end else { return "\(a) – now" }
        let sameDay = DayKey(start, calendar: cal) == DayKey(end, calendar: cal)
        return "\(a) – \(sameDay ? Format.time(end, cal) : Format.dateTime(end, cal))"
    }

    /// "7:02 AM – 5:42 PM", or "since 7:02 AM" while still there.
    static func presenceRange(_ s: PresenceSession, _ cal: Calendar) -> String {
        guard let left = s.exitedAt else { return "since \(Format.time(s.enteredAt, cal))" }
        return range(s.enteredAt, left, cal)
    }
}

/// What a swipe-to-delete or "Remove override" is about to remove, pending confirmation.
enum LogDeleteTarget: Identifiable {
    case presence(UUID)
    case manual(UUID)
    case timeOff(UUID)
    case adjustment(UUID)
    case dayOverride(DayKey)

    var id: String {
        switch self {
        case .presence(let id): return "presence-\(id.uuidString)"
        case .manual(let id): return "manual-\(id.uuidString)"
        case .timeOff(let id): return "timeoff-\(id.uuidString)"
        case .adjustment(let id): return "adjustment-\(id.uuidString)"
        case .dayOverride(let day): return "override-\(day.isoString)"
        }
    }

    var buttonTitle: String {
        switch self {
        case .dayOverride: return "Remove override"
        case .presence, .manual, .timeOff, .adjustment: return "Delete"
        }
    }

    var message: String {
        switch self {
        case .presence: return "The arrival and departure are removed from the ledger. Raw events stay in the log."
        case .manual: return "This work-elsewhere entry and its time are removed."
        case .timeOff: return "This time off entry is removed and the leave balance restored."
        case .adjustment: return "This adjustment is removed from the balance."
        case .dayOverride: return "Day off, excused, early arrival, custom hours and the note for this day are cleared."
        }
    }
}

// MARK: - Day detail

/// Everything the ledger knows about one day, with every fact editable.
struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    let day: DayKey

    @State private var sheet: LogSheet?
    @State private var pendingDelete: LogDeleteTarget?
    @State private var customHoursExpanded = false
    @State private var rawEventsExpanded = false
    /// Local draft of the day note; committed on submit, focus loss and disappear so each keystroke
    /// does not run a full ledger recompute, a Live Activity update and a widget reload.
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    init(day: DayKey) {
        self.day = day
    }

    private var result: DayResult { model.dayResult(for: day) }
    private var cal: Calendar { model.calendar }
    private var dayOverride: DayOverride { model.store.overrideOrNew(for: day) }
    private var hasOverride: Bool { model.store.override(for: day) != nil }

    var body: some View {
        List {
            headerSection
            scheduleSection
            breakdownSection
            presenceSection
            manualSection
            timeOffSection
            adjustmentsSection
            rawEventsSection
        }
        .navigationTitle(Format.dayShort(day, cal))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LogAddMenu(sheet: $sheet)
            }
        }
        .sheet(item: $sheet) { s in
            LogSheetView(sheet: s, day: day) { sheet = nil }
        }
        .confirmationDialog("Are you sure?", isPresented: deleteBinding, titleVisibility: .visible, presenting: pendingDelete) { target in
            Button(target.buttonTitle, role: .destructive) { perform(target) }
        } message: { target in
            Text(target.message)
        }
        .onAppear {
            if customSchedule != nil { customHoursExpanded = true }
            note = dayOverride.note
        }
        .onChange(of: dayOverride.note) { _, new in
            // Model -> local (e.g. "Remove override" cleared it), so a stale commit cannot bring it back.
            if new != note { note = new }
        }
        .onDisappear(perform: commitNote)
    }

    // MARK: Header

    @ViewBuilder private var headerSection: some View {
        let r = result
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(Format.dayLong(day, cal)).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TagView(text: r.kind.label, color: r.kind.color)
                        ForEach(r.flags, id: \.self) { flag in
                            TagView(text: flag.label)
                        }
                    }
                }
                if r.kind == .holiday, let holiday = model.store.holiday(on: day) {
                    Text(holiday.name).foregroundStyle(.secondary)
                }
                DeltaText(seconds: r.deltaSeconds, font: .largeTitle.bold())
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Schedule and overrides

    @ViewBuilder private var scheduleSection: some View {
        let r = result
        let base = customBase
        Section("Schedule") {
            if let w = r.scheduledWindow {
                ValueRow("Window", "\(Format.time(w.start, cal)) – \(Format.time(w.end, cal))")
            } else {
                ValueRow("Window", "No schedule")
            }
            ValueRow("Expected", Format.hm(r.expectedSeconds))
            Toggle("Day off", isOn: dayOffBinding)
            Toggle("Excused (delta 0)", isOn: excusedBinding)
            Toggle("Count early arrival", isOn: countEarlyBinding)
            DisclosureGroup("Custom hours for this day", isExpanded: $customHoursExpanded) {
                Toggle("Use custom hours", isOn: customHoursBinding)
                DatePicker("Start", selection: customStartBinding, displayedComponents: .hourAndMinute)
                    .environment(\.calendar, cal)
                    .environment(\.timeZone, cal.timeZone)
                DatePicker("End", selection: customEndBinding, displayedComponents: .hourAndMinute)
                    .environment(\.calendar, cal)
                    .environment(\.timeZone, cal.timeZone)
                Stepper("Unpaid break: \(base.unpaidBreakMinutes) min", value: customBreakBinding, in: 0...240, step: 5)
                if customSchedule != nil && !base.isValid {
                    Text("End must be after start.")
                        .font(.footnote)
                        .foregroundStyle(Color.negative)
                }
            }
            TextField("Note for this day", text: $note)
                .focused($noteFocused)
                .onSubmit(commitNote)
                .onChange(of: noteFocused) { _, focused in
                    if !focused { commitNote() }
                }
            if hasOverride {
                Button("Remove override", role: .destructive) {
                    pendingDelete = .dayOverride(day)
                }
            }
        }
    }

    /// The custom per-day schedule when the override carries one.
    private var customSchedule: WeekdaySchedule? {
        switch dayOverride.kind {
        case .schedule(let s): return s
        case .dayOff, .none: return nil
        }
    }

    /// What the custom-hours controls show: the custom schedule, else today's window, else the defaults.
    private var customBase: WeekdaySchedule {
        if let s = customSchedule { return s }
        if let w = result.scheduledWindow {
            return WeekdaySchedule(isWorkday: true, start: timeOfDay(w.start), end: timeOfDay(w.end), unpaidBreakMinutes: 0)
        }
        return WeekdaySchedule()
    }

    private func timeOfDay(_ date: Date) -> TimeOfDay {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    private func updateOverride(_ change: (inout DayOverride) -> Void) {
        var o = dayOverride
        change(&o)
        model.setOverride(o)
    }

    private func applyCustom(_ s: WeekdaySchedule) {
        updateOverride { $0.kind = .schedule(s) }
    }

    private var dayOffBinding: Binding<Bool> {
        Binding(
            get: {
                if case .dayOff = dayOverride.kind { return true }
                return false
            },
            set: { on in
                updateOverride { $0.kind = on ? DayOverrideKind.dayOff : DayOverrideKind.none }
            }
        )
    }

    private var excusedBinding: Binding<Bool> {
        Binding(get: { dayOverride.excused }, set: { v in updateOverride { $0.excused = v } })
    }

    private var countEarlyBinding: Binding<Bool> {
        Binding(get: { dayOverride.countEarlyArrival }, set: { v in model.countEarlyArrival(day: day, v) })
    }

    private var customHoursBinding: Binding<Bool> {
        Binding(
            get: { customSchedule != nil },
            set: { on in
                let base = customBase
                updateOverride { $0.kind = on ? DayOverrideKind.schedule(base) : DayOverrideKind.none }
            }
        )
    }

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { customBase.start.date(on: day, calendar: cal) },
            set: { date in
                var s = customBase
                s.isWorkday = true
                s.start = timeOfDay(date)
                applyCustom(s)
            }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { customBase.end.date(on: day, calendar: cal) },
            set: { date in
                var s = customBase
                s.isWorkday = true
                s.end = timeOfDay(date)
                applyCustom(s)
            }
        )
    }

    private var customBreakBinding: Binding<Int> {
        Binding(
            get: { customBase.unpaidBreakMinutes },
            set: { minutes in
                var s = customBase
                s.isWorkday = true
                s.unpaidBreakMinutes = minutes
                applyCustom(s)
            }
        )
    }

    /// Writes the local note through the model once it differs. `Store.setOverride` drops an override
    /// that ends up empty, so committing a cleared note still removes it.
    private func commitNote() {
        guard note != dayOverride.note else { return }
        updateOverride { $0.note = note }
    }

    // MARK: Breakdown

    @ViewBuilder private var breakdownSection: some View {
        let r = result
        Section {
            Group {
                if r.presenceSeconds != 0 {
                    ValueRow("Presence", Format.hm(r.presenceSeconds))
                }
                if r.presenceInsideSeconds != 0 {
                    ValueRow("Inside window", Format.hm(r.presenceInsideSeconds))
                }
                if r.extraAfterSeconds != 0 {
                    DeltaRow("Extra after", r.extraAfterSeconds)
                }
                if r.extraBeforeSeconds != 0 {
                    if r.extraBeforeCounted {
                        DeltaRow("Extra before (counted)", r.extraBeforeSeconds)
                    } else {
                        ValueRow("Extra before (not counted)", Format.hm(r.extraBeforeSeconds))
                    }
                }
                if r.gapsDeductedSeconds != 0 {
                    DeltaRow("Gaps deducted", -r.gapsDeductedSeconds)
                }
                if r.gapsWorkSeconds != 0 {
                    ValueRow("Gaps as work", Format.hm(r.gapsWorkSeconds))
                }
                if r.lateArrivalSeconds != 0 {
                    DeltaRow("Late arrival", -r.lateArrivalSeconds)
                }
            }
            Group {
                if r.earlyExitSeconds != 0 {
                    DeltaRow("Early exit", -r.earlyExitSeconds)
                }
                if r.manualExtraSeconds != 0 {
                    DeltaRow("Manual extra", r.manualExtraSeconds)
                }
                if r.manualRegularSeconds != 0 {
                    ValueRow("Manual regular", Format.hm(r.manualRegularSeconds))
                }
                if r.timeOffSeconds != 0 {
                    if r.hasWindow {
                        DeltaRow("Time off", r.timeOffSeconds)
                    } else {
                        ValueRow("Time off", Format.hm(r.timeOffSeconds))
                    }
                }
                if r.flexSpentSeconds != 0 {
                    DeltaRow("Flex spent", -r.flexSpentSeconds)
                }
                if r.adjustmentSeconds != 0 {
                    DeltaRow("Adjustments", r.adjustmentSeconds)
                }
                LabeledContent {
                    DeltaText(seconds: r.deltaSeconds, font: .body.bold())
                } label: {
                    Text("Delta").bold()
                }
            }
        } header: {
            Text("Breakdown")
        } footer: {
            Text("Delta = extra after + counted early + manual extra + adjustments + time off − deducted gaps − flex spent")
        }
    }

    // MARK: Presence

    private var presenceSessions: [PresenceSession] {
        let window = day.interval(in: cal)
        let now = model.now
        return model.store.presence
            .filter { $0.interval(now: now).overlaps(window) }
            .sorted { $0.enteredAt < $1.enteredAt }
    }

    @ViewBuilder private var presenceSection: some View {
        let sessions = presenceSessions
        Section("Presence") {
            if sessions.isEmpty {
                Text("No arrivals recorded").foregroundStyle(.secondary)
            }
            ForEach(sessions) { s in
                LogPresenceRow(session: s, onEdit: { sheet = .presence(s) }, onGap: { setGap(s, $0) })
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = .presence(s.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func setGap(_ s: PresenceSession, _ value: Bool?) {
        var changed = s
        changed.followingGapIsWork = value
        model.savePresence(changed)
    }

    // MARK: Work elsewhere

    private var manualSessions: [ManualSession] {
        let window = day.interval(in: cal)
        let now = model.now
        return model.store.manual
            .filter { m in m.intervals(now: now).contains { $0.overlaps(window) } }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
    }

    @ViewBuilder private var manualSection: some View {
        let sessions = manualSessions
        Section("Work elsewhere") {
            if sessions.isEmpty {
                Text("No work elsewhere").foregroundStyle(.secondary)
            }
            ForEach(sessions) { m in
                Button {
                    sheet = .manual(m)
                } label: {
                    LogManualRow(session: m)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = .manual(m.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: Time off

    @ViewBuilder private var timeOffSection: some View {
        let entries = model.store.timeOff(on: day)
        if !entries.isEmpty {
            Section("Time off") {
                ForEach(entries) { t in
                    Button {
                        sheet = .timeOff(t)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.timeOffTypeName(t.typeID))
                                if !t.note.isEmpty {
                                    Text(t.note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(Format.hm(t.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = .timeOff(t.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: Adjustments

    @ViewBuilder private var adjustmentsSection: some View {
        let entries = model.store.adjustments(on: day)
        if !entries.isEmpty {
            Section("Adjustments") {
                ForEach(entries) { a in
                    Button {
                        sheet = .adjustment(a)
                    } label: {
                        HStack {
                            Text(a.reason.isEmpty ? "Adjustment" : a.reason)
                            Spacer()
                            DeltaText(seconds: a.seconds)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = .adjustment(a.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: Raw events

    private var rawEvents: [LocationEvent] {
        model.store.locationEvents
            .filter { DayKey($0.at, calendar: cal) == day }
            .sorted { $0.at < $1.at }
    }

    @ViewBuilder private var rawEventsSection: some View {
        let events = rawEvents
        Section {
            DisclosureGroup(isExpanded: $rawEventsExpanded) {
                if events.isEmpty {
                    Text("No events").foregroundStyle(.secondary)
                }
                ForEach(events) { e in
                    HStack {
                        Text(LogText.eventKind(e.kind))
                        Text(Format.time(e.at, cal)).monospacedDigit()
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.locationName(e.locationID))
                            Text(LogText.source(e.source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            } label: {
                Text("Raw events (\(events.count))")
            }
        }
    }

    // MARK: Delete

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func perform(_ target: LogDeleteTarget) {
        switch target {
        case .presence(let id): model.deletePresence(id: id)
        case .manual(let id): model.deleteManual(id: id)
        case .timeOff(let id): model.deleteTimeOff(id: id)
        case .adjustment(let id): model.deleteAdjustment(id: id)
        case .dayOverride(let d): model.removeOverride(day: d)
        }
        pendingDelete = nil
    }
}

// MARK: - Rows

/// One presence session: location, in – out, duration, source, and the gap-after decision menu.
struct LogPresenceRow: View {
    @Environment(AppModel.self) private var model
    let session: PresenceSession
    let onEdit: () -> Void
    let onGap: (Bool?) -> Void

    var body: some View {
        let cal = model.calendar
        HStack(alignment: .top, spacing: 8) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.locationName(session.locationID))
                    Text(LogText.presenceRange(session, cal))
                        .font(.subheadline)
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        durationText
                        Text("·")
                        Text(LogText.source(session.source))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !session.note.isEmpty {
                        Text(session.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Time away after")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(LogGapChoice.allCases) { choice in
                        Button(choice.title) { onGap(choice.value) }
                    }
                } label: {
                    Text(LogGapChoice(session.followingGapIsWork).title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder private var durationText: some View {
        if session.isOpen {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.hm(session.seconds(now: context.date)))
            }
        } else {
            Text(Format.hm(session.seconds(now: model.now)))
        }
    }
}

/// One manual session: category, counts-as, segments, active time, state.
struct LogManualRow: View {
    @Environment(AppModel.self) private var model
    let session: ManualSession

    var body: some View {
        let cal = model.calendar
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.category)
                Text(LogText.countsAs(session.countsAs) + " · " + LogText.state(session.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(session.segments.indices, id: \.self) { i in
                    Text(LogText.range(session.segments[i].start, session.segments[i].end, cal))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if !session.note.isEmpty {
                    Text(session.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            durationText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var durationText: some View {
        if session.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationFormat.clockWithSeconds(session.activeSeconds(now: context.date)))
                    .monospacedDigit()
            }
        } else {
            Text(Format.hm(session.activeSeconds(now: model.now)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let model = AppModel.preview()
    return NavigationStack {
        DayDetailView(day: model.today.adding(days: -1, calendar: model.calendar))
    }
    .environment(model)
}
