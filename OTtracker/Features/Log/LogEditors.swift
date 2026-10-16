import SwiftUI
import OTCore

// MARK: - Shared editor helpers

/// The decision about the absence after a presence session, as shown in pickers and menus.
enum LogGapChoice: String, CaseIterable, Identifiable {
    case undecided, work, personal

    var id: String { rawValue }

    init(_ value: Bool?) {
        if let value {
            self = value ? .work : .personal
        } else {
            self = .undecided
        }
    }

    var title: String {
        switch self {
        case .undecided: return "Undecided"
        case .work: return "Work trip"
        case .personal: return "Personal"
        }
    }

    /// What goes into `PresenceSession.followingGapIsWork`.
    var value: Bool? {
        switch self {
        case .undecided: return nil
        case .work: return true
        case .personal: return false
        }
    }
}

/// One editable segment of a manual session.
struct LogSegmentDraft: Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date?
}

enum LogManual {
    /// Picker tag for "Custom…" category.
    static let customTag = "__custom__"
}

enum LogAdjustmentSign: String, CaseIterable, Identifiable {
    case add, subtract

    var id: String { rawValue }

    var title: String {
        switch self {
        case .add: return "+ Add"
        case .subtract: return "− Subtract"
        }
    }
}

// MARK: - Presence editor

/// Arrival / departure at a work location. `session == nil` creates a new hand-entered one.
struct PresenceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let existing: PresenceSession?
    private let defaultDay: DayKey
    private let onDone: (() -> Void)?

    @State private var locationID: UUID?
    @State private var enteredAt: Date
    @State private var exitedAt: Date
    @State private var isOpen: Bool
    @State private var gap: LogGapChoice
    @State private var note: String
    @State private var loaded = false
    @State private var confirmDelete = false

    init(session: PresenceSession?, defaultDay: DayKey, onDone: (() -> Void)? = nil) {
        existing = session
        self.defaultDay = defaultDay
        self.onDone = onDone
        _locationID = State(initialValue: session?.locationID)
        let entered = session?.enteredAt ?? Date()
        _enteredAt = State(initialValue: entered)
        _exitedAt = State(initialValue: session?.exitedAt ?? entered.addingTimeInterval(8 * 3600))
        _isOpen = State(initialValue: session?.isOpen ?? false)
        _gap = State(initialValue: LogGapChoice(session?.followingGapIsWork))
        _note = State(initialValue: session?.note ?? "")
    }

    var body: some View {
        let cal = model.calendar
        NavigationStack {
            Form {
                Section("Where") {
                    if model.store.locations.isEmpty {
                        Text("Add a work location in Settings first").foregroundStyle(.secondary)
                    } else {
                        Picker("Location", selection: $locationID) {
                            ForEach(model.store.locations) { loc in
                                Text(loc.name).tag(Optional(loc.id))
                            }
                        }
                    }
                }
                Section("When") {
                    DateTimeField(title: "Arrived", date: $enteredAt, calendar: cal)
                    Toggle("Still there (no departure yet)", isOn: $isOpen)
                    if !isOpen {
                        DateTimeField(title: "Left", date: $exitedAt, calendar: cal)
                        LabeledContent("Duration", value: Format.hm(max(0, Interval(start: enteredAt, end: exitedAt).seconds)))
                    }
                }
                Section {
                    Picker("Time away afterwards", selection: $gap) {
                        ForEach(LogGapChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                } footer: {
                    Text("Decides how the time between this departure and the next arrival on the same day counts. Undecided applies the default: a work trip when the next arrival is at another location, personal otherwise.")
                }
                Section("Details") {
                    TextField("Note", text: $note)
                    LabeledContent("Source", value: LogText.source(existing?.source ?? .manual))
                }
                if let error = validationError {
                    Section {
                        Text(error).foregroundStyle(Color.negative)
                    }
                }
                if existing != nil {
                    Section {
                        Button("Delete arrival / departure", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New arrival" : "Edit arrival")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .confirmationDialog("Delete this arrival / departure?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteExisting() }
            }
            .onAppear { prepare() }
            .onChange(of: isOpen) { _, open in
                if !open && exitedAt <= enteredAt {
                    exitedAt = enteredAt.addingTimeInterval(8 * 3600)
                }
            }
        }
    }

    private var validationError: String? {
        if !isOpen && exitedAt < enteredAt { return "Departure must be after arrival." }
        if isOpen, let open = model.store.openPresenceSession, open.id != existing?.id {
            return "Another arrival is still open. Set its departure first."
        }
        return nil
    }

    private var canSave: Bool {
        !model.store.locations.isEmpty && locationID != nil && validationError == nil
    }

    /// Fills defaults that need the store's calendar (not available in `init`).
    private func prepare() {
        guard !loaded else { return }
        loaded = true
        if locationID == nil { locationID = model.store.locations.first?.id }
        guard existing == nil else { return }
        let cal = model.calendar
        if let window = model.dayResult(for: defaultDay).scheduledWindow {
            enteredAt = window.start
            exitedAt = window.end
        } else {
            enteredAt = TimeOfDay(hour: 7).date(on: defaultDay, calendar: cal)
            exitedAt = TimeOfDay(hour: 15, minute: 30).date(on: defaultDay, calendar: cal)
        }
    }

    private func save() {
        guard canSave, let locationID = locationID else { return }
        let leftAt: Date? = isOpen ? nil : exitedAt
        let decision = gap.value
        if var s = existing {
            s.locationID = locationID
            s.enteredAt = enteredAt
            s.exitedAt = leftAt
            s.followingGapIsWork = decision
            s.note = note
            model.savePresence(s)
        } else {
            let arrivedAt = enteredAt
            let session = PresenceSession(locationID: locationID, enteredAt: arrivedAt, exitedAt: leftAt,
                                          source: .manual, followingGapIsWork: decision, note: note)
            model.mutate { s in
                s.locationEvents.append(LocationEvent(locationID: locationID, kind: .enter, at: arrivedAt, source: .manual))
                if let leftAt {
                    s.locationEvents.append(LocationEvent(locationID: locationID, kind: .exit, at: leftAt, source: .manual))
                }
                s.upsert(session)
            }
        }
        finish()
    }

    private func deleteExisting() {
        guard let existing = existing else { return }
        model.deletePresence(id: existing.id)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

// MARK: - Manual session editor

/// Work done elsewhere: a block entered after the fact (new) or the segments of a timer session (existing).
struct ManualSessionEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let existing: ManualSession?
    private let defaultDay: DayKey
    private let onDone: (() -> Void)?

    @State private var categoryChoice: String
    @State private var customCategory: String
    @State private var note: String
    @State private var countsAs: ManualCountsAs
    @State private var start: Date
    @State private var end: Date
    @State private var segments: [LogSegmentDraft]
    @State private var isStopped: Bool
    @State private var loaded = false
    @State private var confirmDelete = false

    init(session: ManualSession?, defaultDay: DayKey, defaultCountsAs: ManualCountsAs = .extra, onDone: (() -> Void)? = nil) {
        existing = session
        self.defaultDay = defaultDay
        self.onDone = onDone
        _categoryChoice = State(initialValue: session?.category ?? "")
        _customCategory = State(initialValue: "")
        _note = State(initialValue: session?.note ?? "")
        _countsAs = State(initialValue: session?.countsAs ?? defaultCountsAs)
        let first = session?.startedAt ?? Date()
        _start = State(initialValue: first)
        _end = State(initialValue: first.addingTimeInterval(3600))
        _segments = State(initialValue: (session?.segments ?? []).map { LogSegmentDraft(start: $0.start, end: $0.end) })
        _isStopped = State(initialValue: session?.isStopped ?? true)
    }

    var body: some View {
        let cal = model.calendar
        NavigationStack {
            Form {
                Section("What") {
                    Picker("Category", selection: $categoryChoice) {
                        ForEach(model.settings.manualCategories, id: \.self) { name in
                            Text(name).tag(name)
                        }
                        Text("Custom…").tag(LogManual.customTag)
                    }
                    if categoryChoice == LogManual.customTag {
                        TextField("Category name", text: $customCategory)
                    }
                    TextField("Note (optional)", text: $note)
                }
                Section {
                    Picker("Counts as", selection: $countsAs) {
                        Text("Extra time").tag(ManualCountsAs.extra)
                        Text("Regular").tag(ManualCountsAs.regular)
                    }
                } footer: {
                    Text("Extra time adds to your balance. Regular fills the scheduled window first, like being at work (use it for a remote day).")
                }
                if existing == nil {
                    Section("When") {
                        DateTimeField(title: "Start", date: $start, calendar: cal)
                        DateTimeField(title: "End", date: $end, calendar: cal)
                        LabeledContent("Duration", value: Format.hm(max(0, Interval(start: start, end: end).seconds)))
                    }
                } else {
                    Section("Segments") {
                        ForEach(segments) { seg in
                            VStack(alignment: .leading, spacing: 6) {
                                DateTimeField(title: "Start", date: segmentStart(seg.id), calendar: cal)
                                if seg.end == nil {
                                    LabeledContent("End") {
                                        Text("Running").foregroundStyle(.secondary)
                                    }
                                } else {
                                    DateTimeField(title: "End", date: segmentEnd(seg.id), calendar: cal)
                                }
                            }
                        }
                        .onDelete { offsets in
                            segments.remove(atOffsets: offsets)
                        }
                        Button {
                            addSegment()
                        } label: {
                            Label("Add segment", systemImage: "plus")
                        }
                        .disabled(hasOpenSegment)
                    }
                    Section {
                        Toggle("Stopped", isOn: $isStopped)
                        LabeledContent("Active time", value: Format.hm(activeSeconds))
                    } footer: {
                        Text("Paused time never counts. Turning Stopped off makes this the active timer again.")
                    }
                }
                if let error = validationError {
                    Section {
                        Text(error).foregroundStyle(Color.negative)
                    }
                }
                if existing != nil {
                    Section {
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Work elsewhere" : "Edit work elsewhere")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(validationError != nil)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteExisting() }
            }
            .onAppear { prepare() }
            .onChange(of: start) { _, newStart in
                if end <= newStart { end = newStart.addingTimeInterval(3600) }
            }
            .onChange(of: isStopped) { _, stopped in
                guard stopped else { return }
                let now = model.now
                for i in segments.indices where segments[i].end == nil {
                    segments[i].end = max(now, segments[i].start)
                }
            }
        }
    }

    // MARK: Derived

    private var effectiveCategory: String {
        if categoryChoice == LogManual.customTag {
            return customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return categoryChoice
    }

    private var hasOpenSegment: Bool {
        segments.contains { $0.end == nil }
    }

    private var activeSeconds: Int {
        let now = model.now
        return segments.reduce(0) { total, seg in
            total + Interval(start: seg.start, end: seg.end ?? max(now, seg.start)).seconds
        }
    }

    private var validationError: String? {
        if effectiveCategory.isEmpty { return "Choose a category." }
        if existing == nil {
            if end <= start { return "End must be after start." }
            return nil
        }
        if segments.isEmpty { return "Add at least one segment." }
        for (i, seg) in segments.enumerated() {
            if let segEnd = seg.end {
                if segEnd < seg.start { return "Segment \(i + 1) ends before it starts." }
            } else if i != segments.count - 1 || isStopped {
                return "Only the last segment of a running entry can be open."
            }
            if i > 0, let previousEnd = segments[i - 1].end, seg.start < previousEnd {
                return "Segments overlap or are out of order."
            }
        }
        if !isStopped, let active = model.store.activeManualSession, active.id != existing?.id {
            return "Another timer is already running or paused."
        }
        return nil
    }

    // MARK: Segment bindings

    private func segmentStart(_ id: UUID) -> Binding<Date> {
        Binding(
            get: { segments.first { $0.id == id }?.start ?? model.now },
            set: { value in
                if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].start = value }
            }
        )
    }

    private func segmentEnd(_ id: UUID) -> Binding<Date> {
        Binding(
            get: {
                let seg = segments.first { $0.id == id }
                return seg?.end ?? seg?.start ?? model.now
            },
            set: { value in
                if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].end = value }
            }
        )
    }

    private func addSegment() {
        let base = segments.last.flatMap { $0.end } ?? model.now
        segments.append(LogSegmentDraft(start: base, end: base.addingTimeInterval(3600)))
    }

    // MARK: Actions

    /// Fills defaults that need the store (categories, calendar), not available in `init`.
    private func prepare() {
        guard !loaded else { return }
        loaded = true
        let categories = model.settings.manualCategories
        if let existing = existing {
            if !categories.contains(existing.category) {
                categoryChoice = LogManual.customTag
                customCategory = existing.category
            }
        } else {
            let cal = model.calendar
            start = TimeOfDay(hour: 17).date(on: defaultDay, calendar: cal)
            end = TimeOfDay(hour: 18).date(on: defaultDay, calendar: cal)
            let preferred = model.settings.defaultManualCategory
            if categories.contains(preferred) {
                categoryChoice = preferred
            } else if let first = categories.first {
                categoryChoice = first
            } else {
                categoryChoice = LogManual.customTag
            }
        }
    }

    private func save() {
        guard validationError == nil else { return }
        let category = effectiveCategory
        if let existing = existing {
            var m = existing
            m.category = category
            m.note = note
            m.countsAs = countsAs
            m.segments = segments.map { ManualSegment(start: $0.start, end: $0.end) }
            m.isStopped = isStopped
            model.saveManual(m)
        } else {
            model.saveManual(ManualSession.block(category: category, note: note, countsAs: countsAs,
                                                 start: start, end: end, createdAt: model.now))
        }
        finish()
    }

    private func deleteExisting() {
        guard let existing = existing else { return }
        model.deleteManual(id: existing.id)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

// MARK: - Adjustment editor

/// A signed correction to the bank on one day.
struct AdjustmentEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let existing: Adjustment?
    private let onDone: (() -> Void)?

    @State private var day: DayKey
    @State private var sign: LogAdjustmentSign
    @State private var seconds: Int
    @State private var reason: String
    @State private var confirmDelete = false

    init(adjustment: Adjustment?, defaultDay: DayKey, onDone: (() -> Void)? = nil) {
        existing = adjustment
        self.onDone = onDone
        _day = State(initialValue: adjustment?.day ?? defaultDay)
        _sign = State(initialValue: (adjustment?.seconds ?? 0) < 0 ? .subtract : .add)
        _seconds = State(initialValue: adjustment.map { abs($0.seconds) } ?? 3600)
        _reason = State(initialValue: adjustment?.reason ?? "")
    }

    var body: some View {
        let cal = model.calendar
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: dayBinding, displayedComponents: .date)
                        .environment(\.calendar, cal)
                        .environment(\.timeZone, cal.timeZone)
                    Picker("Direction", selection: $sign) {
                        ForEach(LogAdjustmentSign.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Amount") {
                    DurationPicker(seconds: $seconds)
                    LabeledContent("Applied to balance") {
                        DeltaText(seconds: signedSeconds)
                    }
                }
                Section("Reason") {
                    TextField("Reason", text: $reason, axis: .vertical)
                }
                if existing != nil {
                    Section {
                        Button("Delete adjustment", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New adjustment" : "Edit adjustment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(seconds <= 0)
                }
            }
            .confirmationDialog("Delete this adjustment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteExisting() }
            }
        }
    }

    private var signedSeconds: Int {
        sign == .add ? seconds : -seconds
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { Format.noon(day, model.calendar) },
            set: { day = DayKey($0, calendar: model.calendar) }
        )
    }

    private func save() {
        guard seconds > 0 else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveAdjustment(Adjustment(id: existing?.id ?? UUID(), day: day, seconds: signedSeconds, reason: trimmed))
        finish()
    }

    private func deleteExisting() {
        guard let existing = existing else { return }
        model.deleteAdjustment(id: existing.id)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

// MARK: - Previews

#Preview("Presence") {
    PresenceEditorView(session: nil, defaultDay: DayKey(year: 2026, month: 10, day: 14))
        .environment(AppModel.preview())
}

#Preview("Manual") {
    ManualSessionEditorView(session: nil, defaultDay: DayKey(year: 2026, month: 10, day: 14))
        .environment(AppModel.preview())
}

#Preview("Adjustment") {
    AdjustmentEditorView(adjustment: nil, defaultDay: DayKey(year: 2026, month: 10, day: 14))
        .environment(AppModel.preview())
}
