import SwiftUI
import OTCore

/// Remaining balance of every leave type that tracks one. Tap to open the Time Off tab.
struct HomeLeaveStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let types = model.store.timeOffTypes.filter { $0.tracksBalance }
        Button {
            model.selectedTab = .timeOff
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Leave balances")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(types) { type in
                        HomeLeaveCell(name: type.name, remainingSeconds: remainingSeconds(for: type))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .homeCard()
    }

    private func remainingSeconds(for type: TimeOffType) -> Int? {
        guard let balance = model.leaveBalance(for: type.id) else { return nil }
        return balance.remainingSeconds
    }
}

/// Name over remaining hours for one leave type.
struct HomeLeaveCell: View {
    let name: String
    let remainingSeconds: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(valueText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            Text("remaining")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueText: String {
        guard let remainingSeconds else { return "—" }
        return Format.hm(remainingSeconds)
    }

    private var valueColor: Color {
        guard let remainingSeconds else { return .secondary }
        return remainingSeconds < 0 ? Color.negative : Color.primary
    }
}

#Preview {
    HomeLeaveStrip().environment(AppModel.preview())
}
