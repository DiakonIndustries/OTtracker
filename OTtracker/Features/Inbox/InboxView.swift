import SwiftUI
import OTCore

/// One section of the Inbox list: Today, Yesterday or Earlier.
struct InboxGroup: Identifiable {
    let title: String
    let items: [InboxItem]

    var id: String { title }
}

/// The app's to-do list: every question the tracking rules could not answer on their own
/// (SPEC section 5.3). The default is always already applied; acting here edits a fact or
/// dismisses the question.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: InboxSheet?
    @State private var pendingDestructive: InboxPendingAction?
    @State private var confirmDismissAll = false

    init() {}

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            InboxItemRow(item: item) { action in
                                request(action, on: item)
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.inbox.isEmpty {
                    EmptyStateView(systemImage: "tray", title: "All caught up",
                                   message: "Questions about your tracking show up here.")
                }
            }
            .navigationTitle("Inbox")
            .navigationDestination(for: DayKey.self) { day in
                DayDetailView(day: day)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            sheet = .help
                        } label: {
                            Label("How the Inbox works", systemImage: "questionmark.circle")
                        }
                        Button(role: .destructive) {
                            confirmDismissAll = true
                        } label: {
                            Label("Dismiss all shown", systemImage: "tray.and.arrow.down")
                        }
                        .disabled(model.inbox.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Dismiss all \(model.inbox.count) items?", isPresented: $confirmDismissAll, titleVisibility: .visible) {
                Button("Dismiss all", role: .destructive) { dismissAllShown() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hides every question listed right now. What the app already did stays applied and the balance does not change.")
            }
        }
        .confirmationDialog("Are you sure?", isPresented: destructiveBinding, titleVisibility: .visible, presenting: pendingDestructive) { pending in
            Button(pending.action.title, role: .destructive) { perform(pending.action, on: pending.item) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(InboxText.destructiveMessage(pending.action))
        }
        .sheet(item: $sheet) { s in
            sheetContent(s)
        }
        .onAppear { handleRoute() }
        .onChange(of: model.pendingRoute) { _, _ in handleRoute() }
    }

    // MARK: Grouping

    /// Today / Yesterday / Earlier by `item.day`; the engine's newest-first order is kept inside each.
    private var groups: [InboxGroup] {
        let today = model.today
        let yesterday = today.adding(days: -1, calendar: model.calendar)
        var todayItems: [InboxItem] = []
        var yesterdayItems: [InboxItem] = []
        var earlierItems: [InboxItem] = []
        for item in model.inbox {
            if item.day >= today {
                todayItems.append(item)
            } else if item.day == yesterday {
                yesterdayItems.append(item)
            } else {
                earlierItems.append(item)
            }
        }
        var out: [InboxGroup] = []
        if !todayItems.isEmpty { out.append(InboxGroup(title: "Today", items: todayItems)) }
        if !yesterdayItems.isEmpty { out.append(InboxGroup(title: "Yesterday", items: yesterdayItems)) }
        if !earlierItems.isEmpty { out.append(InboxGroup(title: "Earlier", items: earlierItems)) }
        return out
    }

    private var destructiveBinding: Binding<Bool> {
        Binding(get: { pendingDestructive != nil }, set: { shown in if !shown { pendingDestructive = nil } })
    }

    // MARK: Actions

    /// Destructive actions ask first; everything else runs immediately.
    private func request(_ action: InboxAction, on item: InboxItem) {
        if action.isDestructive {
            pendingDestructive = InboxPendingAction(item: item, action: action)
        } else {
            perform(action, on: item)
        }
    }

    /// Applies the action through the model; collects input in a sheet when the resolver asks for it.
    private func perform(_ action: InboxAction, on item: InboxItem) {
        let outcome = model.resolve(item, with: action)
        switch outcome {
        case .applied:
            break
        case .needsInput(let input):
            switch input {
            case .dateTime:
                sheet = .dateTime(item: item, action: action)
            case .duration:
                sheet = .duration(item: item, action: action)
            case .timeOffForm(let kind):
                sheet = .timeOff(item: item, kind: kind)
            case .manualForm:
                sheet = .manual(item: item)
            case .sessionEditor:
                sheet = .presence(item: item)
            }
        case .notApplicable:
            switch action {
            case .emailExport:
                presentExport(month: InboxText.month(fromKey: item.key), email: true)
            case .shareExport:
                presentExport(month: InboxText.month(fromKey: item.key), email: false)
            default:
                break
            }
        }
    }

    /// Opens the mail composer (or the share sheet when mail is unavailable) for a monthly file.
    private func presentExport(month: String, email: Bool) {
        guard let file = model.monthlyExport(for: month) else {
            model.alert = AppAlert(title: "Export not found",
                                   message: "The Excel file for \(month) is no longer in Documents/Exports. Create a new one from Settings → Export.")
            return
        }
        if email && MailComposer.canSend {
            sheet = .mail(file)
        } else {
            sheet = .share(file)
        }
    }

    private func dismissAllShown() {
        let keys = model.inbox.map { $0.key }
        guard !keys.isEmpty else { return }
        model.mutate { s in
            for key in keys { s.dismissInbox(key) }
        }
    }

    // MARK: Routes

    /// Notification taps "Email" / "Share" land here as `.exportMonth`; other routes belong to other tabs.
    private func handleRoute() {
        guard let route = model.pendingRoute else { return }
        switch route {
        case .exportMonth(let month, let email):
            model.consumeRoute()
            presentExport(month: month, email: email)
        case .day, .editPresence, .editManual, .locations, .importFile, .export:
            break
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ s: InboxSheet) -> some View {
        switch s {
        case .dateTime(let item, let action):
            InboxDateSheet(item: item, action: action, onDone: { sheet = nil })
        case .duration(let item, let action):
            InboxDurationSheet(item: item, action: action, onDone: { sheet = nil })
        case .timeOff(let item, let kind):
            TimeOffEditorView(entry: nil, defaultDay: item.day, defaultKind: kind, onDone: { sheet = nil })
        case .manual(let item):
            ManualSessionEditorView(session: nil, defaultDay: item.day, defaultCountsAs: .regular, onDone: { sheet = nil })
        case .presence(let item):
            PresenceEditorView(session: item.subjectID.flatMap { model.store.presenceSession(id: $0) },
                               defaultDay: item.day, onDone: { sheet = nil })
        case .mail(let file):
            MailComposer(to: [model.settings.exportEmail].compactMap { $0 },
                         subject: "OTtracker export \(file.title)",
                         body: "Attached: last month's OTtracker export.",
                         attachment: file.url,
                         onDone: { sheet = nil })
        case .share(let file):
            ShareSheet(items: [file.url], onDone: { sheet = nil })
        case .help:
            InboxHelpSheet(onDone: { sheet = nil })
        }
    }
}

#Preview {
    InboxView().environment(AppModel.preview())
}
