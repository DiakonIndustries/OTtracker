import SwiftUI
import OTCore

/// Remaining balance of every leave type that tracks one. Tap to open Time Off.
struct HomeLeaveStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let types = model.store.timeOffTypes.filter { $0.tracksBalance }
        Button {
            model.selectedTab = .timeOff
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Time off left")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    ForEach(types) { type in
                        HomeLeaveCell(name: type.name, remainingSeconds: model.leaveBalance(for: type.id)?.remainingSeconds)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }
}

/// Name over remaining time for one leave type.
struct HomeLeaveCell: View {
    let name: String
    let remainingSeconds: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(remainingSeconds.map { Format.hm($0) } ?? "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle((remainingSeconds ?? 0) < 0 ? Color.negative : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    HomeLeaveStrip().padding().environment(AppModel.preview())
}
