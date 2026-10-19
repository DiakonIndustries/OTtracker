import SwiftUI
import OTCore

private enum SettingsScheduleSheet: Identifiable {
    case new
    case edit(ScheduleVersion)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let version): return version.id.uuidString
        }
    }
}

/// All schedule versions, newest first, with the one in force today tagged.
struct SettingsSchedulesListView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: SettingsScheduleSheet?
    @State private var pendingDelete: ScheduleVersion?
    @State private var confirmDelete = false

    private var versions: [ScheduleVersion] {
        model.store.schedules.sorted { $0.effectiveFrom > $1.effectiveFrom }
    }

    private var currentID: UUID? {
        model.store.scheduleVersion(for: model.today)?.id
    }

    var body: some View {
        List {
            if versions.isEmpty {
                EmptyStateView(systemImage: "calendar.badge.clock", title: "No schedule yet",
                               message: "Add your weekly hours so the app knows what counts as extra.")
            } else {
                Section {
                    ForEach(versions) { version in
                        row(version)
                    }
                } footer: {
                    Text("Each version applies from its date until the next one starts. When your hours change, add a new version instead of editing the old one so past days keep their expected hours.")
                }
            }
        }
        .navigationTitle("Work schedule")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .new
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .new:
                ScheduleEditorView(version: nil)
            case .edit(let version):
                ScheduleEditorView(version: version)
            }
        }
        .confirmationDialog("Delete this schedule version?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.deleteSchedule(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { "From \(Format.dayWithYear($0.effectiveFrom, model.calendar)). Days that used it fall back to the previous version." } ?? "")
        }
    }

    private func row(_ version: ScheduleVersion) -> some View {
        Button {
            sheet = .edit(version)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(Format.dayWithYear(version.effectiveFrom, model.calendar))")
                    Text(SettingsScheduleSummary.text(version, day: model.today, calendar: model.calendar))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !version.note.isEmpty {
                        Text(version.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if version.id == currentID {
                    TagView(text: "Current", color: .blue)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if versions.count > 1 {
                Button(role: .destructive) {
                    pendingDelete = version
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsSchedulesListView()
    }
    .environment(AppModel.preview())
}
