import SwiftUI
import WidgetKit
import OTCore

/// The widget extension: the home-screen balance widget and the running-timer Live Activity.
@main
struct OTtrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
        TimerLiveActivity()
    }
}
