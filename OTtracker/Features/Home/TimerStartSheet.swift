import SwiftUI
import OTCore

/// Picks a category, an optional note and how the time counts, then starts the manual timer.
struct TimerStartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var onDone: (() -> Void)?

    @State private var pickedCategory: String? = nil
    @State private var customName = ""
    @State private var rememberCustom = true
    @State private var note = ""
    @State private var countsAs: ManualCountsAs = .extra

    /// Picker tag for the "Custom…" row; never a real category name.
    private let customTag = "\u{1F}custom"

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: categorySelection) {
                        ForEach(model.settings.manualCategories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                        Text("Custom…").tag(customTag)
                    }
                    if isCustom {
                        TextField("Category name", text: $customName)
                            .textInputAutocapitalization(.sentences)
                        Toggle("Add to my categories", isOn: $rememberCustom)
                    }
                } header: {
                    Text("Category")
                }

                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Note")
                }

                Section {
                    Picker("Counts as", selection: $countsAs) {
                        Text("Extra time").tag(ManualCountsAs.extra)
                        Text("Regular").tag(ManualCountsAs.regular)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Counts as")
                } footer: {
                    Text("Extra time adds straight to the bank. Regular fills today's schedule first, as if you were on site — use it for a remote day.")
                }
            }
            .navigationTitle("Start timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        finish()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        start()
                    }
                    .disabled(!canStart)
                }
            }
        }
    }

    // MARK: Selection

    /// The configured default when it exists, else the first category, else "Custom…".
    private var defaultCategory: String {
        let categories = model.settings.manualCategories
        let preferred = model.settings.defaultManualCategory
        if categories.contains(preferred) { return preferred }
        return categories.first ?? customTag
    }

    private var effectiveSelection: String {
        pickedCategory ?? defaultCategory
    }

    private var categorySelection: Binding<String> {
        Binding(get: { effectiveSelection }, set: { pickedCategory = $0 })
    }

    private var isCustom: Bool {
        effectiveSelection == customTag
    }

    private var finalCategory: String {
        if isCustom { return customName.trimmingCharacters(in: .whitespacesAndNewlines) }
        return effectiveSelection
    }

    private var canStart: Bool {
        !finalCategory.isEmpty && model.activeTimer == nil
    }

    // MARK: Actions

    private func start() {
        let category = finalCategory
        guard !category.isEmpty else { return }
        if isCustom && rememberCustom && !model.settings.manualCategories.contains(category) {
            model.updateSettings { $0.manualCategories.append(category) }
        }
        model.startTimer(category: category,
                         note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                         countsAs: countsAs)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

#Preview {
    TimerStartSheet().environment(AppModel.preview())
}
