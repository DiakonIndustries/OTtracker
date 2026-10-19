import SwiftUI
import UniformTypeIdentifiers
import OTCore

/// iCloud Drive status, manual backup, restore from iCloud or from a JSON file.
struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var backups: [BackupInfo] = []
    @State private var isLoading = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var pendingRestore: BackupInfo?
    @State private var confirmRestore = false
    @State private var showingFilePicker = false
    @State private var pendingFileStore: Store?
    @State private var pendingFileName = ""
    @State private var confirmFileRestore = false

    var body: some View {
        Form {
            Section {
                if model.iCloudAvailable {
                    Label("iCloud Drive available", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("iCloud Drive unavailable — sign in to iCloud", systemImage: "xmark.icloud")
                        .foregroundStyle(.orange)
                }
                ValueRow("Last backup", model.lastBackupAt.map { Format.dateTime($0, model.calendar) } ?? "Never")
                Toggle("Automatic backups", isOn: backupEnabledBinding)
                Button {
                    backUpNow()
                } label: {
                    HStack {
                        Label("Back up now", systemImage: "icloud.and.arrow.up")
                        if isBackingUp {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isBackingUp)
            } header: {
                Text("iCloud Drive")
            } footer: {
                Text("A JSON snapshot of everything is written to your iCloud Drive after changes and about once a day. The last 30 daily files are kept. Restore on a new phone from the list below.")
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if backups.isEmpty {
                    Text("No backups found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(backups) { info in
                    Button {
                        pendingRestore = info
                        confirmRestore = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.filename)
                                    .foregroundStyle(.primary)
                                Text(Format.dateTime(info.modified, model.calendar))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(max(1, info.sizeBytes / 1024)) KB")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isRestoring)
                }
            } header: {
                HStack {
                    Text("Backups in iCloud")
                    Spacer()
                    if isRestoring {
                        ProgressView()
                    } else {
                        Button {
                            Task { await reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            } footer: {
                Text("Tap a backup to replace everything on this phone with it.")
            }

            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Restore from file…", systemImage: "doc.badge.arrow.up")
                }
                .disabled(isRestoring)
            } footer: {
                Text("A JSON backup exported by OTtracker, for example one you saved from Export.")
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
        .confirmationDialog("Replace everything on this phone with this backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let pendingRestore { restore(pendingRestore) }
                pendingRestore = nil
            }
        } message: {
            Text(pendingRestore?.filename ?? "")
        }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                readFile(url)
            case .failure(let error):
                model.alert = AppAlert(title: "Could not open file", message: error.localizedDescription)
            }
        }
        .background {
            // Separate host so the two confirmation dialogs never share one presentation slot.
            Color.clear
                .confirmationDialog("Replace everything on this phone with this file?", isPresented: $confirmFileRestore, titleVisibility: .visible) {
                    Button("Restore", role: .destructive) {
                        if let pendingFileStore { model.replaceStore(pendingFileStore) }
                        pendingFileStore = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingFileStore = nil
                    }
                } message: {
                    Text(pendingFileName)
                }
        }
    }

    private var backupEnabledBinding: Binding<Bool> {
        Binding(get: { model.settings.iCloudBackupEnabled },
                set: { value in model.updateSettings { $0.iCloudBackupEnabled = value } })
    }

    // MARK: Actions

    private func reload() async {
        isLoading = true
        backups = (try? await model.listBackups()) ?? []
        isLoading = false
    }

    private func backUpNow() {
        guard !isBackingUp else { return }
        isBackingUp = true
        Task { @MainActor in
            await model.backupNow()
            await reload()
            isBackingUp = false
        }
    }

    private func restore(_ info: BackupInfo) {
        isRestoring = true
        Task { @MainActor in
            do {
                try await model.restore(from: info)
            } catch {
                model.alert = AppAlert(title: "Restore failed", message: error.localizedDescription)
            }
            isRestoring = false
        }
    }

    private func readFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingFileStore = try StoreCodec.decode(data)
            pendingFileName = url.lastPathComponent
            confirmFileRestore = true
        } catch {
            model.alert = AppAlert(title: "Could not read backup", message: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        BackupView()
    }
    .environment(AppModel.preview())
}
