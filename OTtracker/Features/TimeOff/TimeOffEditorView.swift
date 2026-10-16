import SwiftUI
import OTCore

/// Books or edits one time-off entry. Sheet content: owns its NavigationStack, Cancel/Save,
/// validates, saves through the model, offers Delete when editing, calls onDone then dismisses.
struct TimeOffEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let entry: TimeOffEntry?
    private let defaultKind: TimeOffKind?
    private let onDone: (() -> Void)?

    @State private var typeID: UUID
    @State private var day: DayKey
    @State private var fullDay: Bool
    @State private var customSeconds: Int
    @State private var note: String
    @State private var confirmDelete = false
    @State private var didResolveType = false

    init(entry: TimeOffEntry?, defaultDay: DayKey, defaultKind: TimeOffKind? = nil, onDone: (() -> Void)? = nil) {
        self.entry = entry
        self.defaultKind = defaultKind
        self.onDone = onDone
        var initialType = TimeOffType.ptoID
        if let existing = entry {
            initialType = existing.typeID
        } else if let kind = defaultKind, let builtIn = TimeOffType.builtIn.first(where: { $0.kind == kind }) {
            initialType = builtIn.id
        }
        _typeID = State(initialValue: initialType)
        _day = State(initialValue: entry?.day ?? defaultDay)
        _fullDay = State(initialValue: entry == nil)
        _customSeconds = State(initialValue: entry?.seconds ?? 8 * 3600)
        _note = State(initialValue: entry?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                whenSection
                Section("Note") {
                    TextField("Why (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
                balanceSection
                if entry != nil {
                    Section {
                        Button("Delete Time Off", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(entry == nil ? "New Time Off" : "Edit Time Off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDone?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete this time off?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteEntry() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The hours come back to the balance they were taken from.")
            }
            .onAppear { resolveType() }
            .onChange(of: fullDay) { _, isFull in
                if !isFull && entry == nil { customSeconds = scheduledSeconds }
            }
        }
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $typeID) {
                ForEach(model.store.timeOffTypes) { type in
                    Text(type.name).tag(type.id)
                }
            }
        } footer: {
            if let type = selectedType, type.deductsFromBank {
                Text("Flex time is paid out of your bank: the day expects fewer hours and the same amount is subtracted from the balance.")
            }
        }
    }

    private var whenSection: some View {
        Section {
            DatePicker("Day", selection: TimeOffDates.dateBinding($day, calendar: model.calendar), displayedComponents: .date)
                .environment(\.calendar, model.calendar)
                .environment(\.timeZone, model.calendar.timeZone)
            Toggle("Full day", isOn: $fullDay)
            if fullDay {
                ValueRow("Hours", Format.hm(scheduledSeconds))
            } else {
                DurationPicker(seconds: $customSeconds)
            }
        } header: {
            Text("When")
        } footer: {
            Text(scheduleFootnote)
        }
    }

    @ViewBuilder
    private var balanceSection: some View {
        if let type = selectedType {
            if type.deductsFromBank {
                Section {
                    LabeledContent("Bank balance") { DeltaText(seconds: bankAvailable) }
                    LabeledContent("After this") { DeltaText(seconds: bankAvailable - effectiveSeconds) }
                    if effectiveSeconds > bankAvailable {
                        warning("This takes more flex time than you have banked.")
                    }
                } header: {
                    Text("Flex bank")
                }
            } else if type.tracksBalance {
                Section {
                    ValueRow("\(type.name) remaining", Format.hm(leaveAvailable))
                    ValueRow("After this", Format.hm(leaveAvailable - effectiveSeconds))
                    if effectiveSeconds > leaveAvailable {
                        warning("This uses more \(type.name) than you have left.")
                    }
                } header: {
                    Text("Balance")
                }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    // MARK: Derived

    private var selectedType: TimeOffType? { model.store.timeOffType(id: typeID) }

    private var scheduledWindowSeconds: Int? { model.dayResult(for: day).scheduledWindow?.seconds }

    /// Full-day hours: the day's scheduled window, else 8h 30m.
    private var scheduledSeconds: Int { scheduledWindowSeconds ?? (8 * 3600 + 1800) }

    private var effectiveSeconds: Int { fullDay ? scheduledSeconds : customSeconds }

    private var isValid: Bool { effectiveSeconds > 0 && selectedType != nil }

    private var scheduleFootnote: String {
        let dayText = Format.dayShort(day, model.calendar)
        if scheduledWindowSeconds != nil {
            return "A full day on \(dayText) is the scheduled window: \(Format.hm(scheduledSeconds))."
        }
        return "No schedule on \(dayText); a full day counts as 8h 30m."
    }

    /// Bank balance with this entry's own flex hours added back when it is already counted.
    private var bankAvailable: Int {
        var bank = model.summary.balanceSeconds
        if let existing = entry, existing.day <= model.today,
           let oldType = model.store.timeOffType(id: existing.typeID), oldType.deductsFromBank {
            bank += existing.seconds
        }
        return bank
    }

    /// Remaining leave for the selected type, with this entry's own hours added back when already counted.
    private var leaveAvailable: Int {
        var remaining = model.leaveBalance(for: typeID)?.remainingSeconds ?? 0
        if let existing = entry, existing.typeID == typeID, existing.day <= model.today {
            remaining += existing.seconds
        }
        return remaining
    }

    // MARK: Actions

    /// Picks the real type for `defaultKind` from the store (custom types included) once the model is available.
    private func resolveType() {
        guard !didResolveType else { return }
        didResolveType = true
        guard entry == nil else { return }
        let types = model.store.timeOffTypes
        if let kind = defaultKind, let match = types.first(where: { $0.kind == kind }) {
            typeID = match.id
        } else if !types.contains(where: { $0.id == typeID }) {
            typeID = types.first(where: { $0.kind == .pto })?.id ?? types.first?.id ?? typeID
        }
    }

    private func save() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveTimeOff(TimeOffEntry(id: entry?.id ?? UUID(), day: day, typeID: typeID, seconds: effectiveSeconds, note: trimmed))
        onDone?()
        dismiss()
    }

    private func deleteEntry() {
        if let existing = entry { model.deleteTimeOff(id: existing.id) }
        onDone?()
        dismiss()
    }
}

#Preview {
    TimeOffEditorView(entry: nil, defaultDay: DayKey(year: 2026, month: 10, day: 16), defaultKind: .flex)
        .environment(AppModel.preview())
}
