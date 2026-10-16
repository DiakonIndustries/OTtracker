import SwiftUI
import OTCore

/// Starting balance and accrual rule for one leave type, with a live preview of today's balance.
/// Pushed from the Time Off tab; Save writes through the model and pops back.
struct TimeOffBalanceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let typeID: UUID

    @State private var loaded = false
    @State private var startingSeconds = 0
    @State private var asOf = DayKey(year: 2000, month: 1, day: 1)
    @State private var accrues = false
    @State private var accrualSeconds = 0
    @State private var period: AccrualPeriod = .monthly
    @State private var anchor = DayKey(year: 2000, month: 1, day: 1)

    /// Configs created by `Store()` carry this placeholder; shown as Jan 1 of this year instead.
    private static let placeholderDay = DayKey(year: 2000, month: 1, day: 1)

    init(typeID: UUID) {
        self.typeID = typeID
    }

    var body: some View {
        Form {
            Section {
                DurationPicker(seconds: $startingSeconds, maxHours: 500)
                DatePicker("As of", selection: TimeOffDates.dateBinding($asOf, calendar: model.calendar), displayedComponents: .date)
                    .environment(\.calendar, model.calendar)
                    .environment(\.timeZone, model.calendar.timeZone)
            } header: {
                Text("Starting balance")
            } footer: {
                Text("What you had on the as-of day. Hours taken after it are subtracted; accruals are added.")
            }

            Section {
                Toggle("Accrues automatically", isOn: $accrues)
                if accrues {
                    DurationPicker(seconds: $accrualSeconds, maxHours: 100)
                    Picker("Period", selection: $period) {
                        ForEach(AccrualPeriod.allCases, id: \.self) { p in
                            Text(TimeOffFormat.periodLabel(p)).tag(p)
                        }
                    }
                    DatePicker("First accrual on", selection: TimeOffDates.dateBinding($anchor, calendar: model.calendar), displayedComponents: .date)
                        .environment(\.calendar, model.calendar)
                        .environment(\.timeZone, model.calendar.timeZone)
                }
            } header: {
                Text("Accrual")
            } footer: {
                if accrues {
                    Text("Adds \(Format.hm(accrualSeconds)) on \(Format.dayWithYear(anchor, model.calendar)) and every \(TimeOffFormat.periodNoun(period)) after that.")
                }
            }

            Section {
                if let preview = previewBalance {
                    ValueRow("Starting", Format.hm(preview.startingSeconds))
                    ValueRow("Accrued so far", Format.hm(preview.accruedSeconds))
                    ValueRow("Used", Format.hm(preview.usedSeconds))
                    LabeledContent("Remaining") {
                        Text(Format.hm(preview.remainingSeconds))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(preview.remainingSeconds < 0 ? Color.negative : Color.primary)
                    }
                } else {
                    Text("No preview available.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Live preview of \(model.timeOffTypeName(typeID)) as of \(Format.dayWithYear(model.today, model.calendar)) with these settings.")
            }
        }
        .navigationTitle(model.timeOffTypeName(typeID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .onAppear { load() }
    }

    // MARK: Derived

    private var editedConfig: LeaveBalanceConfig {
        LeaveBalanceConfig(typeID: typeID, startingSeconds: startingSeconds, asOf: asOf,
                           accrual: accrues ? AccrualRule(seconds: accrualSeconds, period: period, anchor: anchor) : nil)
    }

    private var isValid: Bool { !accrues || accrualSeconds > 0 }

    /// The ledger's answer for today on a copy of the store with the edited config upserted.
    private var previewBalance: LeaveBalance? {
        var copy = model.store
        copy.upsert(editedConfig)
        return Ledger.leaveBalances(store: copy, asOf: model.today).first { $0.typeID == typeID }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        let thisYear = DayKey(year: model.today.year, month: 1, day: 1)
        if let config = model.store.leaveBalances.first(where: { $0.typeID == typeID }) {
            startingSeconds = config.startingSeconds
            asOf = config.asOf <= TimeOffBalanceEditor.placeholderDay ? thisYear : config.asOf
            if let rule = config.accrual {
                accrues = true
                accrualSeconds = rule.seconds
                period = rule.period
                anchor = rule.anchor
            } else {
                accrues = false
                anchor = asOf
            }
        } else {
            startingSeconds = 0
            asOf = thisYear
            accrues = false
            anchor = thisYear
        }
    }

    private func save() {
        model.saveLeaveBalance(editedConfig)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        TimeOffBalanceEditor(typeID: TimeOffType.ptoID)
    }
    .environment(AppModel.preview())
}
