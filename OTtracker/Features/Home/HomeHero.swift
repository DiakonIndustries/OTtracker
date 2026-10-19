import SwiftUI
import OTCore

/// The time bank: one big number on a gradient, with today, this week and this month's extra beneath.
struct HomeHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The headline is settled through yesterday; today is shown separately because it is still moving.
        let settled = model.settledBalanceSeconds
        let summary = model.summary
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Time bank", systemImage: "hourglass")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(HomeHero.caption(for: settled))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(.white.opacity(0.92))

            Text(Format.hm(settled, signed: true))
                .font(.system(size: 58, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())

            HStack(spacing: 8) {
                HomeHeroStat(title: "Today", seconds: summary.todayDeltaSeconds)
                HomeHeroStat(title: "This week", seconds: summary.weekDeltaSeconds)
                HomeHeroStat(title: "Month extra", seconds: summary.monthGrossExtraSeconds)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroGradient(negative: settled < 0),
                    in: RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
        .shadow(color: (settled < 0 ? Color.negative : Color.blue).opacity(0.28), radius: 18, x: 0, y: 10)
    }

    static func caption(for balance: Int) -> String {
        if balance < 0 { return "You owe time" }
        if balance > 0 { return "Owed to you" }
        return "All square"
    }
}

/// One frosted tile on the hero.
struct HomeHeroStat: View {
    let title: String
    let seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            Text(Format.hm(seconds, signed: true))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    HomeHero().padding().environment(AppModel.preview())
}
