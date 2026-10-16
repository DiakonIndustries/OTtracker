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
                        .tabItem { Label("Home", systemImage: "clock") }
                        .tag(AppModel.Tab.home)
                    LogView()
                        .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                        .tag(AppModel.Tab.log)
                    InboxView()
                        .tabItem { Label("Inbox", systemImage: "tray") }
                        .badge(model.inboxCount)
                        .tag(AppModel.Tab.inbox)
                    TimeOffView()
                        .tabItem { Label("Time Off", systemImage: "sun.max") }
                        .tag(AppModel.Tab.timeOff)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.Tab.settings)
                }
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

#Preview {
    RootView().environment(AppModel.preview())
}
