import SwiftUI
import OTCore

/// Payload for the rename sheet.
struct SettingsCategoryRename: Identifiable {
    let original: String
    var id: String { original }
}

/// Manual-timer categories: add, rename, delete (keep at least one), pick the default.
struct SettingsCategoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var renaming: SettingsCategoryRename?
    @State private var pendingDelete: String?
    @State private var confirmDelete = false

    private var categories: [String] { model.settings.manualCategories }

    private var trimmedNewName: String { newName.trimmingCharacters(in: .whitespaces) }

    private var canAdd: Bool {
        !trimmedNewName.isEmpty && !categories.contains { $0.caseInsensitiveCompare(trimmedNewName) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                ForEach(categories, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        if name == model.settings.defaultManualCategory {
                            TagView(text: "Default", color: .blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        renaming = SettingsCategoryRename(original: name)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if categories.count > 1 {
                            Button(role: .destructive) {
                                pendingDelete = name
                                confirmDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Tap a category to rename it. Swipe to delete. At least one category must remain.")
            }

            Section {
                HStack {
                    TextField("New category", text: $newName)
                        .textInputAutocapitalization(.sentences)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.borderless)
                        .disabled(!canAdd)
                }
            } header: {
                Text("Add")
            }

            Section {
                Picker("Default category", selection: defaultBinding) {
                    ForEach(categories, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } header: {
                Text("Default for new timers")
            } footer: {
                Text("Used by the Start timer button on the Home screen and the widget.")
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { item in
            SettingsCategoryRenameSheet(original: item.original)
        }
        .confirmationDialog("Delete this category?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text("Past sessions keep the name \"\(pendingDelete ?? "")\"; it just stops being offered for new timers.")
        }
    }

    private var defaultBinding: Binding<String> {
        Binding(get: { model.settings.defaultManualCategory },
                set: { value in model.updateSettings { $0.defaultManualCategory = value } })
    }

    // MARK: Actions

    private func add() {
        guard canAdd else { return }
        let name = trimmedNewName
        model.updateSettings { $0.manualCategories.append(name) }
        newName = ""
    }

    private func delete(_ name: String) {
        model.updateSettings { s in
            s.manualCategories.removeAll { $0 == name }
            if s.manualCategories.isEmpty { s.manualCategories = [Settings.defaultCategories[0]] }
            if s.defaultManualCategory == name { s.defaultManualCategory = s.manualCategories[0] }
        }
    }
}

/// Sheet content: rename one category everywhere (settings, default, and past manual sessions).
struct SettingsCategoryRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: String
    @State private var name: String

    init(original: String) {
        self.original = original
        _name = State(initialValue: original)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var isDuplicate: Bool {
        trimmed.caseInsensitiveCompare(original) != .orderedSame
            && model.settings.manualCategories.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var canSave: Bool { !trimmed.isEmpty && trimmed != original && !isDuplicate }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .onSubmit { if canSave { save() } }
                    if isDuplicate {
                        Text("A category with this name already exists.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Past sessions in this category are renamed too, so the Excel export stays consistent.")
                }
            }
            .navigationTitle("Rename category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let newName = trimmed
        let oldName = original
        model.mutate { s in
            if let index = s.settings.manualCategories.firstIndex(of: oldName) {
                s.settings.manualCategories[index] = newName
            }
            if s.settings.defaultManualCategory == oldName {
                s.settings.defaultManualCategory = newName
            }
            for index in s.manual.indices where s.manual[index].category == oldName {
                s.manual[index].category = newName
            }
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        SettingsCategoriesView()
    }
    .environment(AppModel.preview())
}
