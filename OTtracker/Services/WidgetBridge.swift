import Foundation
import WidgetKit
import OTCore

/// Writes the widget snapshot into the App Group container and reloads timelines.
@MainActor
final class WidgetBridge: WidgetBridging {
    private var last: WidgetSnapshot?

    func publish(_ snapshot: WidgetSnapshot) {
        var comparable = snapshot
        comparable.generatedAt = last?.generatedAt ?? snapshot.generatedAt
        if let last, last == comparable { return }
        last = snapshot
        guard let dir = AppFiles.appGroup else { return }
        let url = dir.appendingPathComponent(AppIdentifiers.snapshotFilename)
        if let data = try? StoreCodec.encoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor
final class NoopWidgetBridge: WidgetBridging {
    func publish(_ snapshot: WidgetSnapshot) {}
}
