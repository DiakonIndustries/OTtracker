import SwiftUI
import OTCore

/// The Time Off tab: leave balances, the flex bank, booked time off, holidays and types.
struct TimeOffView: View {
    @Environment(AppModel.self) private var model

    @State private var editor: TimeOffEditorPayload?
    @State private var pendingDelete: TimeOffEntry?
    @State private var confirmDelete = false
    @State private var balanceTypeID: UUID?

    init() {}

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if upcoming.isEmpty && recentPast.isEmpty {
                    Section {
                        Text("Nothing booked yet. Book PTO, personal time or a flex day above.")
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
            .navigationDestination(item: $balanceTypeID) { id in
                TimeOffBalanceEditor(typeID: id)
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

    /// Balance tiles (each leave type and the flex bank) and the one "book" button.
    private var summarySection: some View {
        Section {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(balanceTypes) { type in
                        Button {
                            balanceTypeID = type.id
                        } label: {
                            TimeOffTile(title: type.name,
                                        seconds: model.leaveBalance(for: type.id)?.remainingSeconds ?? 0,
                                        caption: "left",
                                        symbol: type.kind == .pto ? "airplane" : "person.fill",
                                        color: type.kind == .pto ? .blue : .purple,
                                        signed: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    editor = TimeOffEditorPayload(entry: nil, defaultDay: model.today, defaultKind: .flex)
                } label: {
                    TimeOffTile(title: "Flex bank",
                                seconds: model.settledBalanceSeconds,
                                caption: "Tap to book a flex day from your bank",
                                symbol: "hourglass",
                                color: .positive,
                                signed: true)
                }
                .buttonStyle(.plain)
                Button {
                    editor = TimeOffEditorPayload(entry: nil, defaultDay: model.today, defaultKind: nil)
                } label: {
                    Label("Book time off", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            Text("A flex day takes the hours out of your bank instead of your PTO.")
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
        .tint(.primary)
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

/// One balance tile at the top of Time Off.
struct TimeOffTile: View {
    let title: String
    let seconds: Int
    let caption: String
    let symbol: String
    let color: Color
    let signed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(systemImage: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(signed ? Format.hm(seconds, signed: true) : Format.hm(seconds))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(seconds < 0 ? Color.negative : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}
