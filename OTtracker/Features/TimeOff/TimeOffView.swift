import SwiftUI
import OTCore

/// The Time Off tab: leave balances, the flex bank, booked time off, holidays and types.
struct TimeOffView: View {
    @Environment(AppModel.self) private var model

    @State private var editor: TimeOffEditorPayload?
    @State private var pendingDelete: TimeOffEntry?
    @State private var confirmDelete = false

    init() {}

    var body: some View {
        NavigationStack {
            List {
                balancesSection
                bankSection
                if upcoming.isEmpty && recentPast.isEmpty {
                    Section {
                        Text("No time off booked yet. Tap + to book PTO, personal time or a flex day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { entry in entryRow(entry) }
                    }
                }
                if !recentPast.isEmpty {
                    Section("Past 90 days") {
                        ForEach(recentPast) { entry in entryRow(entry) }
                    }
                }
                moreSection
            }
            .navigationTitle("Time Off")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = TimeOffEditorPayload(entry: nil, defaultDay: model.today, defaultKind: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Book time off")
                }
            }
            .sheet(item: $editor) { payload in
                TimeOffEditorView(entry: payload.entry, defaultDay: payload.defaultDay, defaultKind: payload.defaultKind)
            }
            .confirmationDialog("Delete this time off?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let entry = pendingDelete { model.deleteTimeOff(id: entry.id) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(deleteMessage)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var balancesSection: some View {
        Section("Balances") {
            if balanceTypes.isEmpty {
                Text("No type tracks a balance. Turn on “Tracks balance” for a type to see it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(balanceTypes) { type in
                    NavigationLink {
                        TimeOffBalanceEditor(typeID: type.id)
                    } label: {
                        TimeOffBalanceCard(name: type.name, balance: model.leaveBalance(for: type.id))
                    }
                }
            }
        }
    }

    private var bankSection: some View {
        Section {
            LabeledContent("Flex time available") {
                DeltaText(seconds: model.settledBalanceSeconds, font: .title3)
            }
            Button {
                editor = TimeOffEditorPayload(entry: nil, defaultDay: model.today, defaultKind: .flex)
            } label: {
                Label("Book a flex day", systemImage: "calendar.badge.minus")
            }
        } header: {
            Text("Bank")
        } footer: {
            Text("A flex day lowers the hours expected that day and takes the same amount out of your bank.")
        }
    }

    private var moreSection: some View {
        Section {
            NavigationLink {
                HolidaysView()
            } label: {
                LabeledContent("Holidays") {
                    Text(upcomingHolidayCount == 1 ? "1 upcoming" : "\(upcomingHolidayCount) upcoming")
                }
            }
            NavigationLink {
                TimeOffTypesView()
            } label: {
                LabeledContent("Time off types") {
                    Text("\(model.store.timeOffTypes.count)")
                }
            }
        }
    }

    private func entryRow(_ entry: TimeOffEntry) -> some View {
        Button {
            editor = TimeOffEditorPayload(entry: entry, defaultDay: entry.day, defaultKind: nil)
        } label: {
            TimeOffEntryRow(entry: entry)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = entry
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Derived

    private var balanceTypes: [TimeOffType] {
        model.store.timeOffTypes.filter { $0.tracksBalance }
    }

    private var upcoming: [TimeOffEntry] {
        let today = model.today
        return model.store.timeOff
            .filter { $0.day >= today }
            .sorted(by: TimeOffView.ascending)
    }

    private var recentPast: [TimeOffEntry] {
        let today = model.today
        let cutoff = today.adding(days: -90, calendar: model.calendar)
        return model.store.timeOff
            .filter { $0.day < today && $0.day >= cutoff }
            .sorted(by: TimeOffView.descending)
    }

    private var upcomingHolidayCount: Int {
        let today = model.today
        return model.store.holidays.filter { $0.day >= today }.count
    }

    private var deleteMessage: String {
        guard let entry = pendingDelete else { return "" }
        return "\(Format.hm(entry.seconds)) of \(model.timeOffTypeName(entry.typeID)) on \(Format.dayShort(entry.day, model.calendar)) will be removed."
    }

    private static func ascending(_ a: TimeOffEntry, _ b: TimeOffEntry) -> Bool {
        if a.day != b.day { return a.day < b.day }
        return a.id.uuidString < b.id.uuidString
    }

    private static func descending(_ a: TimeOffEntry, _ b: TimeOffEntry) -> Bool {
        if a.day != b.day { return a.day > b.day }
        return a.id.uuidString < b.id.uuidString
    }
}

/// One leave type's balance: name, remaining (large), and how it got there.
struct TimeOffBalanceCard: View {
    let name: String
    /// nil → zeros (type has no ledger yet).
    let balance: LeaveBalance?

    private var starting: Int { balance?.startingSeconds ?? 0 }
    private var accrued: Int { balance?.accruedSeconds ?? 0 }
    private var used: Int { balance?.usedSeconds ?? 0 }
    private var remaining: Int { balance?.remainingSeconds ?? 0 }

    private var caption: String {
        if starting != 0 {
            return "start \(Format.hm(starting)) · accrued \(Format.hm(accrued)) · used \(Format.hm(used))"
        }
        return "accrued \(Format.hm(accrued)) · used \(Format.hm(used))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Format.hm(remaining))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(remaining < 0 ? Color.negative : Color.primary)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A booked time-off entry in a list.
struct TimeOffEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: TimeOffEntry

    private var deductsFromBank: Bool {
        model.store.timeOffType(id: entry.typeID)?.deductsFromBank ?? false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dayShort(entry.day, model.calendar))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(model.timeOffTypeName(entry.typeID))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if deductsFromBank {
                        TagView(text: "From bank", color: .orange)
                    }
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(Format.hm(entry.seconds))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    TimeOffView().environment(AppModel.preview())
}
