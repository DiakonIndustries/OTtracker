import SwiftUI
import OTCore

/// One-line description of a schedule version, e.g. "Mon–Fri 7:00 AM – 3:30 PM".
enum SettingsScheduleSummary {
    static func text(_ version: ScheduleVersion, day: DayKey, calendar: Calendar) -> String {
        let workdays = Weekday.allCases.filter { version[$0].isWorkday }
        guard let first = workdays.first else { return "No workdays" }
        let reference = version[first]
        let sameHours = workdays.allSatisfy { version[$0].start == reference.start && version[$0].end == reference.end }
        let dayText = daysText(workdays)
        if sameHours {
            let start = Format.time(reference.start.date(on: day, calendar: calendar), calendar)
            let end = Format.time(reference.end.date(on: day, calendar: calendar), calendar)
            return "\(dayText) \(start) – \(end)"
        }
        return "\(dayText), hours vary"
    }

    /// "Mon–Fri" for a contiguous run, otherwise "Mon, Wed, Fri".
    static func daysText(_ days: [Weekday]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let contiguous = days.count == last.rawValue - first.rawValue + 1
        if contiguous && days.count > 1 { return "\(first.shortName)–\(last.shortName)" }
        return days.map { $0.shortName }.joined(separator: ", ")
    }
}

/// Sheet content: edits one `ScheduleVersion`, or creates a new one effective today.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let original: ScheduleVersion?
    private let onDone: (() -> Void)?

    @State private var days: [WeekdaySchedule]
    @State private var note: String
    /// nil until the user touches the date picker; the default resolves against the model in `body`.
    @State private var effectiveFromOverride: Date?
    @State private var confirmDelete = false

    init(version: ScheduleVersion?, onDone: (() -> Void)? = nil) {
        original = version
        self.onDone = onDone
        // The placeholder date only seeds the seven weekday entries; the real "effective from" is today (see effectiveDate).
        let template = version ?? ScheduleVersion.standardWeek(effectiveFrom: DayKey(year: 2000, month: 1, day: 1))
        _days = State(initialValue: template.days)
        _note = State(initialValue: template.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Effective from", selection: effectiveBinding, displayedComponents: .date)
                        .environment(\.calendar, model.calendar)
                        .environment(\.timeZone, model.calendar.timeZone)
                    if conflictsWithOtherVersion {
                        Text("Another version already starts on this day.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Days from this date on follow these hours until a later version takes over. Earlier days keep the previous version.")
                }

                ForEach(Weekday.ordered(startingOn: .sunday), id: \.self) { weekday in
                    Section {
                        SettingsWeekdayRow(weekday: weekday, schedule: dayBinding(weekday),
                                           calendar: model.calendar, day: model.today)
                    }
                }

                Section {
                    Button("Copy Monday to all workdays", action: copyMondayToWorkdays)
                    TextField("Note", text: $note)
                }

                if original != nil {
                    Section {
                        Button("Delete this version", role: .destructive) { confirmDelete = true }
                            .disabled(isOnlyVersion)
                    } footer: {
                        if isOnlyVersion {
                            Text("The only schedule version cannot be deleted. Edit it instead.")
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "New schedule" : "Edit schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: finish)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete this schedule version?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let original { model.deleteSchedule(id: original.id) }
                    finish()
                }
            } message: {
                Text("Days that used it fall back to the previous version.")
            }
        }
    }

    // MARK: Effective date

    private var effectiveDate: Date {
        if let effectiveFromOverride { return effectiveFromOverride }
        if let original { return Format.noon(original.effectiveFrom, model.calendar) }
        return model.now
    }

    private var effectiveDay: DayKey { DayKey(effectiveDate, calendar: model.calendar) }

    private var effectiveBinding: Binding<Date> {
        Binding(get: { effectiveDate }, set: { effectiveFromOverride = $0 })
    }

    // MARK: Validation

    private var invalidDays: [Weekday] {
        Weekday.allCases.filter { weekday in
            let s = days[weekday.rawValue - 1]
            return s.isWorkday && !s.isValid
        }
    }

    private var conflictsWithOtherVersion: Bool {
        let day = effectiveDay
        return model.store.schedules.contains { $0.id != original?.id && $0.effectiveFrom == day }
    }

    private var canSave: Bool { invalidDays.isEmpty && !conflictsWithOtherVersion && days.count == 7 }

    private var isOnlyVersion: Bool {
        guard let original else { return false }
        return model.store.schedules.count <= 1 && model.store.schedules.contains { $0.id == original.id }
    }

    // MARK: Actions

    private func dayBinding(_ weekday: Weekday) -> Binding<WeekdaySchedule> {
        let index = weekday.rawValue - 1
        return Binding(get: { days[index] }, set: { days[index] = $0 })
    }

    private func copyMondayToWorkdays() {
        let mondayIndex = Weekday.monday.rawValue - 1
        let monday = days[mondayIndex]
        for index in days.indices where index != mondayIndex && days[index].isWorkday {
            days[index].start = monday.start
            days[index].end = monday.end
            days[index].unpaidBreakMinutes = monday.unpaidBreakMinutes
        }
    }

    private func save() {
        let version = ScheduleVersion(id: original?.id ?? UUID(), effectiveFrom: effectiveDay, days: days,
                                      note: note.trimmingCharacters(in: .whitespaces))
        model.saveSchedule(version)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

/// Toggle + start/end/break controls for one weekday.
struct SettingsWeekdayRow: View {
    let weekday: Weekday
    @Binding var schedule: WeekdaySchedule
    let calendar: Calendar
    let day: DayKey

    var body: some View {
        Group {
            Toggle(weekday.name, isOn: $schedule.isWorkday)
            if schedule.isWorkday {
                DatePicker("Start", selection: timeBinding($schedule.start), displayedComponents: .hourAndMinute)
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
                DatePicker("End", selection: timeBinding($schedule.end), displayedComponents: .hourAndMinute)
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
                Stepper(value: $schedule.unpaidBreakMinutes, in: 0...120, step: 15) {
                    ValueRow("Unpaid break", "\(schedule.unpaidBreakMinutes) min")
                }
                if !schedule.isValid {
                    Text("Start must be before end.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    ValueRow("Expected", Format.hm(schedule.expectedSeconds))
                }
            }
        }
    }

    private func timeBinding(_ time: Binding<TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { time.wrappedValue.date(on: day, calendar: calendar) },
            set: { date in
                let c = calendar.dateComponents([.hour, .minute], from: date)
                time.wrappedValue = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        )
    }
}

#Preview {
    ScheduleEditorView(version: nil).environment(AppModel.preview())
}
