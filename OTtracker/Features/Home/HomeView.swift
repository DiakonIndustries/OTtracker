import SwiftUI
import OTCore

/// The Home tab: balance, timer, today, Inbox nudge, charts and leave balances.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HomeStyle.cardSpacing) {
                    HomeBalanceHeader()
                    HomeTimerCard()
                    HomeTodayCard()
                    if model.inboxCount > 0 {
                        HomeInboxNudge()
                    }
                    HomeChartsView()
                    if model.store.timeOffTypes.contains(where: { $0.tracksBalance }) {
                        HomeLeaveStrip()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(HomeStyle.pageBackground)
            .navigationTitle("OTtracker")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .day(let day):
                    DayDetailView(day: day)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.selectedTab = .settings
                            model.pendingRoute = .export
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await model.backupNow() }
                        } label: {
                            Label("Back up now", systemImage: "icloud.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView().environment(AppModel.preview())
}
