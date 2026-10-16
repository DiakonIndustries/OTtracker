import SwiftUI
import OTCore

/// The big bank balance with this month's gross extra, this week's and this year's delta.
struct HomeBalanceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 6) {
            Text("Bank balance")
                .font(.caption)
                .foregroundStyle(.secondary)
            DeltaText(seconds: summary.balanceSeconds, font: .system(size: 46, weight: .bold, design: .rounded))
            Text(HomeBalanceHeader.sentence(for: summary.balanceSeconds))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 4)
            HStack(alignment: .top, spacing: 8) {
                HomeStatColumn(title: "This month", seconds: summary.monthGrossExtraSeconds, suffix: "extra")
                HomeStatColumn(title: "This week", seconds: summary.weekDeltaSeconds)
                HomeStatColumn(title: "Year", seconds: summary.ytdDeltaSeconds)
            }
        }
        .homeCard()
    }

    static func sentence(for balance: Int) -> String {
        if balance < 0 { return "You owe time" }
        if balance > 0 { return "Time owed to you" }
        return "All square"
    }
}

/// One small labelled statistic in the balance header.
struct HomeStatColumn: View {
    let title: String
    let seconds: Int
    var suffix: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                DeltaText(seconds: seconds, font: .subheadline.weight(.semibold))
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HomeBalanceHeader().environment(AppModel.preview())
}
