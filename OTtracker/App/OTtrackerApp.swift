import SwiftUI
import OTCore

@main
struct OTtrackerApp: App {
    @State private var model = OTtrackerApp.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppIdentifiers.refreshTaskID)) {
            await model.performBackgroundRefresh()
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        #if DEBUG
        if let scene = DemoMode.scene { return DemoMode.makeModel(scene: scene) }
        #endif
        return AppModel.live()
    }
}
