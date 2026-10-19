import SwiftUI
import OTCore

private enum SettingsExportRange: Hashable, CaseIterable {
    case all, thisMonth, lastMonth, thisYear, custom

    var title: String {
        switch self {
        case .all: return "All history"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisYear: return "This year"
        case .custom: return "Custom"
        }
    }
}

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
struct SettingsShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Excel / JSON / CSV template via the Share sheet, plus the automatic monthly files.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    @State private var range: SettingsExportRange = .all
    @State private var customFromOverride: Date?
    @State private var customThroughOverride: Date?
    @State private var shareItem: SettingsShareItem?
    @State private var mailExport: MonthlyExportFile?

    var body: some View {
        Form {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(SettingsExportRange.allCases, id: \.self) { r in
                        Text(r.title).tag(r)
                    }
                }
                if range == .custom {
                    DatePicker("From", selection: customFromBinding, displayedComponents: .date)
                        .environment(\.calendar, model.calendar)
                        .environment(\.timeZone, model.calendar.timeZone)
                    DatePicker("Through", selection: customThroughBinding, displayedComponents: .date)
                        .environment(\.calendar, model.calendar)
                        .environment(\.timeZone, model.calendar.timeZone)
                }
            } header: {
                Text("Range")
            } footer: {
                Text(rangeDescription)
            }

            Section {
                Button {
                    let r = resolvedRange
                    produce { try model.exportXLSX(from: r.from, through: r.through) }
                } label: {
                    Label("Excel workbook (.xlsx)", systemImage: "tablecells")
                }
                Button {
                    produce { try model.exportJSON() }
                } label: {
                    Label("JSON backup", systemImage: "doc.text")
                }
                Button {
                    produce { try model.csvTemplateURL() }
                } label: {
                    Label("CSV import template", systemImage: "doc.plaintext")
                }
            } header: {
                Text("Share")
            } footer: {
                Text("The Excel has 12 sheets: Summary, Days, Presence, Manual, TimeOff, Holidays, Locations, Schedule, Overrides, Adjustments, Events and Settings; it imports back losslessly. The JSON backup is the whole store. The CSV template is the hand-filled import format.")
            }

            Section {
                if model.monthlyExports.isEmpty {
                    Text("No monthly files yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.monthlyExports) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.title)
                            Text(file.url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            shareItem = SettingsShareItem(url: file.url)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        if MailComposer.canSend {
                            Button {
                                mailExport = file
                            } label: {
                                Image(systemName: "envelope")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Monthly exports")
            } footer: {
                Text("Created automatically on the first launch after a month ends. The files live in Documents/Exports and are visible in the Files app.")
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .background {
            // Separate host for the second sheet so both presentations stay independent.
            Color.clear
                .sheet(item: $mailExport) { file in
                    MailComposer(to: [model.settings.exportEmail].compactMap { $0 },
                                 subject: "OTtracker \(file.title)",
                                 body: "Attached is the OTtracker export for \(file.title).",
                                 attachment: file.url,
                                 onDone: { mailExport = nil })
                }
        }
    }

    // MARK: Range

    private var customFromDate: Date {
        customFromOverride ?? Format.noon(Format.firstOfMonth(model.today), model.calendar)
    }

    private var customThroughDate: Date {
        customThroughOverride ?? Format.noon(model.today, model.calendar)
    }

    private var customFromBinding: Binding<Date> {
        Binding(get: { customFromDate }, set: { customFromOverride = $0 })
    }

    private var customThroughBinding: Binding<Date> {
        Binding(get: { customThroughDate }, set: { customThroughOverride = $0 })
    }

    /// nil/nil means "all history" (the model picks the first recorded day through today).
    private var resolvedRange: (from: DayKey?, through: DayKey?) {
        let calendar = model.calendar
        let today = model.today
        switch range {
        case .all:
            return (nil, nil)
        case .thisMonth:
            return (Format.firstOfMonth(today), today)
        case .lastMonth:
            let lastOfPrevious = Format.firstOfMonth(today).adding(days: -1, calendar: calendar)
            return (Format.firstOfMonth(lastOfPrevious), Format.lastOfMonth(lastOfPrevious, calendar))
        case .thisYear:
            return (DayKey(year: today.year, month: 1, day: 1), today)
        case .custom:
            let from = DayKey(customFromDate, calendar: calendar)
            let through = DayKey(customThroughDate, calendar: calendar)
            return (min(from, through), max(from, through))
        }
    }

    private var rangeDescription: String {
        let r = resolvedRange
        if let from = r.from, let through = r.through {
            return "\(Format.dayWithYear(from, model.calendar)) – \(Format.dayWithYear(through, model.calendar))"
        }
        return "Everything from the first recorded day through today."
    }

    // MARK: Producing files

    private func produce(_ make: () throws -> URL) {
        do {
            shareItem = SettingsShareItem(url: try make())
        } catch {
            model.alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        ExportView()
    }
    .environment(AppModel.preview())
}
