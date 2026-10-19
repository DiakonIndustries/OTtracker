import SwiftUI
import OTCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                TabView(selection: $model.selectedTab) {
                    HomeView()
                        .tabItem { Label("Today", systemImage: "sun.max") }
                        .tag(AppModel.Tab.home)
                    LogView()
                        .tabItem { Label("History", systemImage: "calendar") }
                        .tag(AppModel.Tab.log)
                    InboxView()
                        .tabItem { Label("Inbox", systemImage: "tray") }
                        .badge(model.inboxCount)
                        .tag(AppModel.Tab.inbox)
                    TimeOffView()
                        .tabItem { Label("Time Off", systemImage: "beach.umbrella") }
                        .tag(AppModel.Tab.timeOff)
                }
                .sheet(isPresented: $model.showSettings) {
                    SettingsView()
                }
            }
        }
        .fontDesign(.rounded)
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

#Preview {
    RootView().environment(AppModel.preview())
}
