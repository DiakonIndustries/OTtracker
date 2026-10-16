import SwiftUI
import OTCore

// MARK: - Sheet driver

/// Every sheet the Inbox can present, so the screen needs a single `.sheet(item:)`.
enum InboxSheet: Identifiable {
    case dateTime(item: InboxItem, action: InboxAction)
    case duration(item: InboxItem, action: InboxAction)
    case timeOff(item: InboxItem, kind: TimeOffKind)
    case manual(item: InboxItem)
    case presence(item: InboxItem)
    case mail(MonthlyExportFile)
    case share(MonthlyExportFile)
    case help

    var id: String {
        switch self {
        case .dateTime(let item, let action): return "date|\(item.key)|\(action.title)"
        case .duration(let item, let action): return "duration|\(item.key)|\(action.title)"
        case .timeOff(let item, let kind): return "timeoff|\(item.key)|\(kind.rawValue)"
        case .manual(let item): return "manual|\(item.key)"
        case .presence(let item): return "presence|\(item.key)"
        case .mail(let file): return "mail|\(file.month)"
        case .share(let file): return "share|\(file.month)"
        case .help: return "help"
        }
    }
}

/// A destructive action waiting for the user's confirmation.
struct InboxPendingAction: Identifiable {
    let item: InboxItem
    let action: InboxAction

    var id: String { "\(item.key)|\(action.title)" }
}

/// One bullet of the "How the Inbox works" explainer.
struct InboxHelpPoint: Identifiable {
    let symbol: String
    let title: String
    let body: String

    var id: String { title }
}

// MARK: - Copy

/// Text used by the Inbox screens.
enum InboxText {
    /// `export:2026-09` → `2026-09`.
    static func month(fromKey key: String) -> String {
        let prefix = "export:"
        guard key.hasPrefix(prefix) else { return key }
        return String(key.dropFirst(prefix.count))
    }

    static func destructiveMessage(_ action: InboxAction) -> String {
        switch action {
        case .removeSession:
            return "The arrival and departure are removed from the ledger and the day is recomputed without them. Raw location events stay in the log."
        case .deleteSession:
            return "The open session is deleted and nothing is counted for it."
        default:
            return "This cannot be undone."
        }
    }

    /// Four bullets taken from SPEC section 5.3.
    static let helpPoints: [InboxHelpPoint] = [
        InboxHelpPoint(symbol: "questionmark.bubble",
                       title: "Questions, not chores",
                       body: "An item appears whenever a rule had to decide something for you: a mid-day gap, a missed workday, an auto-detected exit, an early arrival, a long-running timer, a session with no exit, an exit with no arrival, or a finished monthly export."),
        InboxHelpPoint(symbol: "checkmark.seal",
                       title: "The default is already applied",
                       body: "Nothing waits on you. Mid-day gaps are deducted (counted when you moved between sites), early arrivals are ignored and no-shows are deficits. The orange tag shows what was done, and the balance always says what the data says."),
        InboxHelpPoint(symbol: "arrow.triangle.2.circlepath",
                       title: "Resolving edits a fact, dismissing hides the question",
                       body: "Confirm, Keep deficit, Don't count, Still working, Ignore and Dismiss only hide the item. Every other action changes the record, so the item disappears on its own. A dismissed item does not come back."),
        InboxHelpPoint(symbol: "list.bullet.rectangle",
                       title: "Newest first; the title opens the day",
                       body: "Items are sorted newest first under Today, Yesterday and Earlier. Tap an item's title to open that day in the Log, where every component of the delta is editable."),
    ]
}

// MARK: - Date and time input

/// Collects the one instant an action needs: an exit time, an arrival time or a timer stop.
struct InboxDateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let item: InboxItem
    private let action: InboxAction
    private let onDone: (() -> Void)?
    @State private var picked: Date?

    init(item: InboxItem, action: InboxAction, onDone: (() -> Void)? = nil) {
        self.item = item
        self.action = action
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                        .font(.headline)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    DateTimeField(title: fieldTitle, date: dateBinding, calendar: model.calendar)
                    contextRows
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear {
                if picked == nil { picked = defaultDate }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var contextRows: some View {
        switch action {
        case .setExitTime:
            if let session = presenceSession {
                ValueRow("Arrived", Format.dateTime(session.enteredAt, cal))
                if isValid {
                    ValueRow("Duration", Format.hm(Interval(start: session.enteredAt, end: date).seconds))
                }
            }
        case .setArrivalTime:
            ValueRow("Left", Format.dateTime(item.occurredAt, cal))
            if isValid {
                ValueRow("Duration", Format.hm(Interval(start: date, end: item.occurredAt).seconds))
            }
        case .setTimerStop:
            if let session = manualSession {
                if let started = session.startedAt {
                    ValueRow("Started", Format.dateTime(started, cal))
                }
                if isValid {
                    ValueRow("Active time", Format.hm(session.activeSeconds(now: date)))
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Values

    private var cal: Calendar { model.calendar }

    private var presenceSession: PresenceSession? {
        item.subjectID.flatMap { model.store.presenceSession(id: $0) }
    }

    private var manualSession: ManualSession? {
        item.subjectID.flatMap { model.store.manualSession(id: $0) }
    }

    private var date: Date { picked ?? defaultDate }

    private var dateBinding: Binding<Date> {
        Binding(get: { picked ?? defaultDate }, set: { picked = $0 })
    }

    private var fieldTitle: String {
        switch action {
        case .setExitTime: return "Left at"
        case .setArrivalTime: return "Arrived at"
        case .setTimerStop: return "Stopped at"
        default: return "When"
        }
    }

    /// Exit → the item's instant (or scheduled end / +8h when the item points at the arrival);
    /// arrival → scheduled start (or 8h before the exit); timer stop → now.
    private var defaultDate: Date {
        switch action {
        case .setExitTime:
            if let session = presenceSession, item.occurredAt <= session.enteredAt {
                var guess = session.enteredAt.addingTimeInterval(8 * 3600)
                if let window = model.dayResult(for: item.day).scheduledWindow, window.end > session.enteredAt {
                    guess = window.end
                }
                return min(guess, model.now)
            }
            return item.occurredAt
        case .setArrivalTime:
            if let window = model.dayResult(for: item.day).scheduledWindow, window.start < item.occurredAt {
                return window.start
            }
            return item.occurredAt.addingTimeInterval(-8 * 3600)
        case .setTimerStop:
            return model.now
        default:
            return item.occurredAt
        }
    }

    /// The instant the picked time must come after.
    private var lowerBound: Date? {
        switch action {
        case .setExitTime: return presenceSession?.enteredAt
        case .setTimerStop: return manualSession?.segments.last?.start
        default: return nil
        }
    }

    /// The instant the picked time must not pass.
    private var upperBound: Date? {
        switch action {
        case .setArrivalTime: return item.occurredAt
        case .setExitTime, .setTimerStop: return model.now
        default: return nil
        }
    }

    private var isValid: Bool {
        if let lower = lowerBound, date <= lower { return false }
        if let upper = upperBound, date > upper { return false }
        return true
    }

    private var footerText: String {
        switch action {
        case .setExitTime:
            return "The session closes at this time and the day is recomputed. The exit must be after the arrival and not in the future."
        case .setArrivalTime:
            return "A session from this arrival to the recorded departure is added. The arrival must be before the departure."
        case .setTimerStop:
            return "The timer stops at this time; paused time never counts. The stop must be after the last resume and not in the future."
        default:
            return ""
        }
    }

    // MARK: Actions

    private func save() {
        guard isValid else { return }
        model.resolve(item, with: action, date: date)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

// MARK: - Duration input

/// Collects a number of hours and minutes, e.g. for "Enter hours" on a missed day.
struct InboxDurationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let item: InboxItem
    private let action: InboxAction
    private let onDone: (() -> Void)?
    @State private var secondsOverride: Int?

    init(item: InboxItem, action: InboxAction, onDone: (() -> Void)? = nil) {
        self.item = item
        self.action = action
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                        .font(.headline)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    DurationPicker(seconds: secondsBinding)
                    if let window = model.dayResult(for: item.day).scheduledWindow {
                        ValueRow("Scheduled", Format.hm(window.seconds))
                    }
                    ValueRow("Entered", Format.hm(seconds))
                } header: {
                    Text("Hours worked")
                } footer: {
                    Text("Counted on \(Format.dayLong(item.day, model.calendar)). Enter the time you actually worked that day.")
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(seconds <= 0)
                }
            }
        }
    }

    private var defaultSeconds: Int {
        model.dayResult(for: item.day).scheduledWindow?.seconds ?? 8 * 3600
    }

    private var seconds: Int { secondsOverride ?? defaultSeconds }

    private var secondsBinding: Binding<Int> {
        Binding(get: { secondsOverride ?? defaultSeconds }, set: { secondsOverride = $0 })
    }

    private func save() {
        guard seconds > 0 else { return }
        model.resolve(item, with: action, seconds: seconds)
        finish()
    }

    private func finish() {
        onDone?()
        dismiss()
    }
}

// MARK: - Explainer

/// "How the Inbox works": four bullets from SPEC section 5.3.
struct InboxHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let onDone: (() -> Void)?

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List(InboxText.helpPoints) { point in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: point.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28, alignment: .center)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.title)
                            .font(.headline)
                        Text(point.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("How the Inbox works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone?()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview("Date") {
    InboxDateSheet(item: InboxItem(key: "stale:preview", kind: .staleOpen, day: DayKey(year: 2026, month: 10, day: 14),
                                   occurredAt: Date(), title: "Still at Plant A?", detail: "No exit was recorded since 7:02 AM.",
                                   actions: [.setExitTime, .deleteSession]),
                   action: .setExitTime)
        .environment(AppModel.preview())
}

#Preview("Duration") {
    InboxDurationSheet(item: InboxItem(key: "noshow:2026-10-14", kind: .noShow, day: DayKey(year: 2026, month: 10, day: 14),
                                       occurredAt: Date(), title: "No show on Tue, Oct 14", detail: "Scheduled 7:00 AM – 3:30 PM.",
                                       defaultApplied: "Deducted 8h 30m",
                                       actions: [.addTimeOff(kind: .pto), .enterHours, .keepDeficit]),
                       action: .enterHours)
        .environment(AppModel.preview())
}

#Preview("Help") {
    InboxHelpSheet()
}
