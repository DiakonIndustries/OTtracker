import SwiftUI
import OTCore

@main
struct OTtrackerApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// Temporary first screen; replaced by the real root view once the app code lands.
struct PlaceholderView: View {
    private let store = Store()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 56))
            Text("OTtracker")
                .font(.largeTitle.bold())
            Text("Grace \(store.settings.graceMinutes) min · week starts \(store.settings.weekStartsOn.name)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
