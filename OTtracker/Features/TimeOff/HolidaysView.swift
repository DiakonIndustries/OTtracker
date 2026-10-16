import SwiftUI
import UniformTypeIdentifiers
import OTCore

/// Holidays grouped by year (newest year first, ascending within a year), with add, edit,
/// swipe-delete, CSV import (date,name) and a downloadable template.
struct HolidaysView: View {
    @Environment(AppModel.self) private var model

    @State private var editing: TimeOffHolidayPayload?
    @State private var pendingDelete: Holiday?
    @State private var confirmDelete = false
    @State private var showImporter = false
    @State private var importPreview: TimeOffHolidayImportPreview?
    @State private var shareFile: TimeOffShareFile?

    init() {}

    var body: some View {
        List {
            ForEach(years, id: \.self) { year in
                Section {
                    ForEach(holidays(in: year)) { holiday in
                        holidayRow(holiday)
                    }
                } header: {
                    Text(verbatim: String(year))
                }
            }
        }
        .overlay {
            if model.store.holidays.isEmpty {
                EmptyStateView(systemImage: "calendar.badge.plus", title: "No holidays",
                               message: "Add holidays by hand or import a CSV with a date,name header.")
            }
        }
        .navigationTitle("Holidays")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import CSV…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        shareTemplate()
                    } label: {
                        Label("Template…", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                Button {
                    editing = TimeOffHolidayPayload(holiday: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add holiday")
            }
        }
        .sheet(item: $editing) { payload in
            TimeOffHolidayEditor(holiday: payload.holiday, defaultDay: model.today)
        }
        .sheet(item: $importPreview) { item in
            TimeOffHolidayImportSheet(preview: item.preview)
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: HolidaysView.importTypes) { result in
            handleImport(result)
        }
        .confirmationDialog("Delete this holiday?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let holiday = pendingDelete { model.deleteHoliday(id: holiday.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: Rows

    private func holidayRow(_ holiday: Holiday) -> some View {
        Button {
            editing = TimeOffHolidayPayload(holiday: holiday)
        } label: {
            HStack {
                Text(holiday.name)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Format.dayShort(holiday.day, model.calendar))
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = holiday
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Derived

    private var years: [Int] {
        Array(Set(model.store.holidays.map { $0.day.year })).sorted(by: >)
    }

    private func holidays(in year: Int) -> [Holiday] {
        model.store.holidays
            .filter { $0.day.year == year }
            .sorted { $0.day < $1.day }
    }

    private var deleteMessage: String {
        guard let holiday = pendingDelete else { return "" }
        return "\(holiday.name) on \(Format.dayShort(holiday.day, model.calendar)) will be removed. That day goes back to its normal schedule."
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }

    // MARK: Actions

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let preview = try model.previewImport(url: url, mode: .merge)
                importPreview = TimeOffHolidayImportPreview(preview: preview)
            } catch {
                model.alert = AppAlert(title: "Import failed", message: error.localizedDescription)
            }
        case .failure(let error):
            model.alert = AppAlert(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func shareTemplate() {
        let url = AppFiles.shareScratch.appendingPathComponent("holidays-template.csv")
        let text = "date,name\n2026-11-26,Thanksgiving\n2026-12-25,Christmas\n"
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            shareFile = TimeOffShareFile(url: url)
        } catch {
            model.alert = AppAlert(title: "Template failed", message: error.localizedDescription)
        }
    }
}

/// Adds or edits one holiday. Sheet content with its own NavigationStack.
struct TimeOffHolidayEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let holiday: Holiday?
    private let onDone: (() -> Void)?

    @State private var name: String
    @State private var day: DayKey
    @State private var confirmDelete = false

    init(holiday: Holiday?, defaultDay: DayKey, onDone: (() -> Void)? = nil) {
        self.holiday = holiday
        self.onDone = onDone
        _name = State(initialValue: holiday?.name ?? "")
        _day = State(initialValue: holiday?.day ?? defaultDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    DatePicker("Date", selection: TimeOffDates.dateBinding($day, calendar: model.calendar), displayedComponents: .date)
                        .environment(\.calendar, model.calendar)
                        .environment(\.timeZone, model.calendar.timeZone)
                } footer: {
                    if hasDuplicateOnDay {
                        Text("Another holiday is already on this day.")
                    }
                }
                if holiday != nil {
                    Section {
                        Button("Delete Holiday", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(holiday == nil ? "New Holiday" : "Edit Holiday")
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
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog("Delete this holiday?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteHoliday() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasDuplicateOnDay: Bool {
        model.store.holidays.contains { $0.day == day && $0.id != holiday?.id }
    }

    private func save() {
        model.saveHoliday(Holiday(id: holiday?.id ?? UUID(), day: day, name: trimmedName))
        onDone?()
        dismiss()
    }

    private func deleteHoliday() {
        if let existing = holiday { model.deleteHoliday(id: existing.id) }
        onDone?()
        dismiss()
    }
}

/// Shows what a holiday import would do before it is applied.
struct TimeOffHolidayImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let preview: ImportPreview

    private var holidayCounts: ImportPlan.Counts {
        preview.plan.counts["holidays"] ?? ImportPlan.Counts()
    }

    /// New or updated rows of any other kind the file happened to contain.
    private var otherRecords: Int {
        preview.plan.counts.reduce(0) { total, pair in
            pair.key == "holidays" ? total : total + pair.value.new + pair.value.updated
        }
    }

    private var canImport: Bool { holidayCounts.new + holidayCounts.updated + otherRecords > 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ValueRow("New", "\(holidayCounts.new)")
                    ValueRow("Updated", "\(holidayCounts.updated)")
                    ValueRow("Unchanged", "\(holidayCounts.unchanged)")
                } header: {
                    Text("Holidays")
                } footer: {
                    Text(preview.filename)
                }
                if otherRecords > 0 {
                    Section {
                        ValueRow("Other records", "\(otherRecords)")
                    } footer: {
                        Text("This file also carries other record types. They are merged as well.")
                    }
                }
                if !preview.plan.invalid.isEmpty {
                    Section("Skipped rows") {
                        ForEach(Array(preview.plan.invalid.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Line \(item.element.line)")
                                    .font(.subheadline.weight(.semibold))
                                Text(item.element.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !canImport {
                    Section {
                        Text("Nothing new to import.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Holidays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        model.applyImport(preview)
                        dismiss()
                    }
                    .disabled(!canImport)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HolidaysView()
    }
    .environment(AppModel.preview())
}
