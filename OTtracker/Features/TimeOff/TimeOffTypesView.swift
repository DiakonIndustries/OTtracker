import SwiftUI
import OTCore

/// Manage time-off types. Built-in types (PTO, Personal, Flex) can be renamed only.
struct TimeOffTypesView: View {
    @Environment(AppModel.self) private var model

    @State private var editing: TimeOffTypePayload?
    @State private var pendingDelete: TimeOffType?
    @State private var confirmDelete = false

    init() {}

    var body: some View {
        List {
            Section {
                ForEach(model.store.timeOffTypes) { type in
                    Button {
                        editing = TimeOffTypePayload(type: type)
                    } label: {
                        TimeOffTypeRow(type: type)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !TimeOffTypesView.isBuiltIn(type) {
                            Button(role: .destructive) {
                                pendingDelete = type
                                confirmDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text("PTO, Personal and Flex are built in: they can be renamed but not removed. “Tracks balance” keeps a starting balance, accrual and usage ledger; “Deducts from bank” takes the hours out of your flex time.")
            }
        }
        .navigationTitle("Time Off Types")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = TimeOffTypePayload(type: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add type")
            }
        }
        .sheet(item: $editing) { payload in
            TimeOffTypeEditor(type: payload.type)
        }
        .confirmationDialog("Delete this type?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let type = pendingDelete { model.deleteTimeOffType(id: type.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        guard let type = pendingDelete else { return "" }
        let uses = model.store.timeOff.filter { $0.typeID == type.id }.count
        if uses == 0 {
            return "\(type.name) has no entries. Its balance settings are removed too."
        }
        return "\(uses) \(uses == 1 ? "entry" : "entries") keep their hours but will show as “Time off”. Its balance settings are removed too."
    }

    static func isBuiltIn(_ type: TimeOffType) -> Bool {
        TimeOffType.builtIn.contains { $0.id == type.id }
    }
}

/// Name, kind caption and behaviour badges for one type.
struct TimeOffTypeRow: View {
    let type: TimeOffType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(type.name)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text(TimeOffFormat.kindLabel(type.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if type.tracksBalance {
                    TagView(text: "Tracks balance", color: .blue)
                }
                if type.deductsFromBank {
                    TagView(text: "Deducts from bank", color: .orange)
                }
            }
        }
    }
}

/// Adds or edits one type. Sheet content with its own NavigationStack.
struct TimeOffTypeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let type: TimeOffType?
    private let onDone: (() -> Void)?

    @State private var name: String
    @State private var kind: TimeOffKind
    @State private var tracksBalance: Bool
    @State private var deductsFromBank: Bool
    @State private var confirmDelete = false

    init(type: TimeOffType?, onDone: (() -> Void)? = nil) {
        self.type = type
        self.onDone = onDone
        _name = State(initialValue: type?.name ?? "")
        _kind = State(initialValue: type?.kind ?? .other)
        _tracksBalance = State(initialValue: type?.tracksBalance ?? true)
        _deductsFromBank = State(initialValue: type?.deductsFromBank ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if hasDuplicateName {
                        Text("Another type already has this name.")
                    }
                }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(TimeOffKind.allCases, id: \.self) { k in
                            Text(TimeOffFormat.kindLabel(k)).tag(k)
                        }
                    }
                    .disabled(isBuiltIn)
                    Toggle("Tracks balance", isOn: $tracksBalance)
                        .disabled(isBuiltIn)
                    Toggle("Deducts from bank", isOn: $deductsFromBank)
                        .disabled(isBuiltIn)
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text(behaviourFootnote)
                }
                if canDelete {
                    Section {
                        Button("Delete Type", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(type == nil ? "New Type" : "Edit Type")
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
            .confirmationDialog("Delete this type?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteType() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Entries using it keep their hours but will show as “Time off”. Its balance settings are removed too.")
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .flex && !isBuiltIn { deductsFromBank = true }
            }
        }
    }

    // MARK: Derived

    private var isBuiltIn: Bool {
        guard let existing = type else { return false }
        return TimeOffTypesView.isBuiltIn(existing)
    }

    private var canDelete: Bool { type != nil && !isBuiltIn }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasDuplicateName: Bool {
        let lowered = trimmedName.lowercased()
        guard !lowered.isEmpty else { return false }
        return model.store.timeOffTypes.contains {
            $0.id != type?.id && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == lowered
        }
    }

    private var isValid: Bool { !trimmedName.isEmpty && !hasDuplicateName }

    private var behaviourFootnote: String {
        if isBuiltIn {
            return "Built-in types keep their behaviour; only the name can be changed."
        }
        return "Tracks balance shows a starting balance, accrual and remaining hours on the Time Off tab. Deducts from bank makes the hours come out of your flex time, like a flex day."
    }

    // MARK: Actions

    private func save() {
        model.saveTimeOffType(TimeOffType(id: type?.id ?? UUID(), name: trimmedName, kind: kind,
                                          tracksBalance: tracksBalance, deductsFromBank: deductsFromBank))
        onDone?()
        dismiss()
    }

    private func deleteType() {
        if let existing = type { model.deleteTimeOffType(id: existing.id) }
        onDone?()
        dismiss()
    }
}

#Preview {
    NavigationStack {
        TimeOffTypesView()
    }
    .environment(AppModel.preview())
}
