import SwiftUI
import UniformTypeIdentifiers
import OTCore

/// Human wording for errors thrown by the import pipeline.
enum SettingsImportErrorText {
    static func describe(_ error: Error) -> String {
        if let importError = error as? ImportError {
            switch importError {
            case .unrecognizedFormat:
                return "This file is not an OTtracker Excel export, a JSON backup, or the CSV template."
            case .unreadable(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }

    static func formatName(_ format: ImportFormat) -> String {
        switch format {
        case .xlsx: return "Excel workbook"
        case .json: return "JSON backup"
        case .csv: return "CSV template"
        case .holidaysCSV: return "Holidays CSV"
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "presence": return "Presence"
        case "manual": return "Manual sessions"
        case "timeOff": return "Time off"
        case "holidays": return "Holidays"
        case "adjustments": return "Adjustments"
        case "locations": return "Locations"
        case "overrides": return "Day overrides"
        case "schedules": return "Schedules"
        case "events": return "Location events"
        case "timeOffTypes": return "Time-off types"
        case "leaveBalances": return "Leave balances"
        case "settings": return "Settings"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

/// File picker → preview of the plan → Merge or Replace.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: ImportMode = .merge
    @State private var showingPicker = false
    @State private var pickedURL: URL?
    @State private var preview: ImportPreview?
    @State private var confirmReplace = false
    @State private var imported = false

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.json, .commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.insert(xlsx, at: 0) }
        return types
    }

    var body: some View {
        Form {
            Section {
                Text("Import the app's own Excel export, a JSON backup, or the CSV template you can get from Export. Merge adds new rows and updates rows with the same ID. Replace wipes everything except settings first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mode", selection: $mode) {
                    Text("Merge").tag(ImportMode.merge)
                    Text("Replace").tag(ImportMode.replace)
                }
                .pickerStyle(.segmented)
            } footer: {
                if mode == .replace {
                    Text("Replace deletes every record on this phone except settings before importing. Make a backup first.")
                        .foregroundStyle(.red)
                } else {
                    Text("Rows without an ID are matched on their day, times and name so importing the same file twice does not duplicate anything.")
                }
            }

            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("Choose file…", systemImage: "folder")
                }
            }

            if let preview {
                previewSections(preview)
            }

            if imported {
                Section {
                    Label("Imported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickedURL = url
                load(url)
            case .failure(let error):
                model.alert = AppAlert(title: "Could not open file", message: error.localizedDescription)
            }
        }
        .onChange(of: mode) { _, _ in
            if let pickedURL, preview != nil { load(pickedURL) }
        }
        .confirmationDialog("Replace everything on this phone with this file?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace and import", role: .destructive) {
                if let preview { apply(preview) }
            }
        } message: {
            Text("Every record except settings is deleted first. This cannot be undone.")
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewSections(_ preview: ImportPreview) -> some View {
        Section {
            ValueRow("File", preview.filename)
            ValueRow("Format", SettingsImportErrorText.formatName(preview.format))
        } header: {
            Text("File")
        }

        Section {
            let kinds = countedKinds(preview.plan)
            if kinds.isEmpty {
                Text("Nothing recognised in this file.")
                    .foregroundStyle(.secondary)
            }
            ForEach(kinds, id: \.self) { kind in
                let counts = preview.plan.counts[kind] ?? ImportPlan.Counts()
                HStack {
                    Text(SettingsImportErrorText.kindLabel(kind))
                    Spacer()
                    Text("\(counts.new) new · \(counts.updated) updated · \(counts.unchanged) same")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if !preview.plan.newLocationNames.isEmpty {
                Text("Will create locations: \(preview.plan.newLocationNames.joined(separator: ", "))")
                    .font(.footnote)
            }
            if !preview.plan.newTimeOffTypeNames.isEmpty {
                Text("Will create time-off types: \(preview.plan.newTimeOffTypeNames.joined(separator: ", "))")
                    .font(.footnote)
            }
        } header: {
            Text("Changes")
        }

        if !preview.plan.invalid.isEmpty {
            Section {
                DisclosureGroup("\(preview.plan.invalid.count) invalid rows (skipped)") {
                    ForEach(Array(preview.plan.invalid.prefix(50).enumerated()), id: \.offset) { item in
                        Text("line \(item.element.line): \(item.element.reason)")
                            .font(.caption)
                    }
                    if preview.plan.invalid.count > 50 {
                        Text("… and \(preview.plan.invalid.count - 50) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            Button(preview.mode == .replace ? "Replace and import" : "Import",
                   role: preview.mode == .replace ? .destructive : nil) {
                if preview.mode == .replace {
                    confirmReplace = true
                } else {
                    apply(preview)
                }
            }
            .disabled(preview.mode == .merge && preview.plan.totalNew + preview.plan.totalUpdated == 0)
        } footer: {
            if preview.mode == .merge && preview.plan.totalNew + preview.plan.totalUpdated == 0 {
                Text("Nothing new to import.")
            }
        }
    }

    private func countedKinds(_ plan: ImportPlan) -> [String] {
        plan.counts.keys.filter { key in
            let c = plan.counts[key] ?? ImportPlan.Counts()
            return c.new + c.updated + c.unchanged > 0
        }.sorted()
    }

    // MARK: Actions

    private func load(_ url: URL) {
        imported = false
        do {
            preview = try model.previewImport(url: url, mode: mode)
        } catch {
            preview = nil
            model.alert = AppAlert(title: "Could not read file", message: SettingsImportErrorText.describe(error))
        }
    }

    private func apply(_ preview: ImportPreview) {
        model.applyImport(preview)
        self.preview = nil
        pickedURL = nil
        imported = true
    }
}

#Preview {
    NavigationStack {
        ImportView()
    }
    .environment(AppModel.preview())
}
