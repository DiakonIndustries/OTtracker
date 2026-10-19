import SwiftUI
import OTCore

/// The Today tab: the bank, what is happening right now, anything to review, the trend and leave.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: HomeAddSheet? = nil

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    HomeHero()
                    HomeStatusCard()
                    if model.inboxCount > 0 {
                        HomeInboxNudge()
                    }
                    HomeChartsView()
                    if model.store.timeOffTypes.contains(where: { $0.tracksBalance }) {
                        HomeLeaveStrip()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Theme.page)
            .navigationTitle("Today")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .day(let day):
                    DayDetailView(day: day)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(HomeAddSheet.allCases) { kind in
                            Button {
                                sheet = kind
                            } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .presence:
                    PresenceEditorView(session: nil, defaultDay: model.today, onDone: { sheet = nil })
                case .manual:
                    ManualSessionEditorView(session: nil, defaultDay: model.today, onDone: { sheet = nil })
                case .timeOff:
                    TimeOffEditorView(entry: nil, defaultDay: model.today, onDone: { sheet = nil })
                case .adjustment:
                    AdjustmentEditorView(adjustment: nil, defaultDay: model.today, onDone: { sheet = nil })
                }
            }
        }
    }
}

#Preview {
    HomeView().environment(AppModel.preview())
}
