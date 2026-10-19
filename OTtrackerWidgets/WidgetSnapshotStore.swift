import Foundation
import OTCore

/// Reads the `WidgetSnapshot` the app writes into the App Group container
/// (`WidgetBridge.publish` in the app). The extension never touches the full `Store`.
enum WidgetSnapshotStore {
    /// `<App Group container>/widget-snapshot.json`, nil when the entitlement is missing.
    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent(AppIdentifiers.snapshotFilename)
    }

    /// The snapshot on disk, or nil when the file is missing or unreadable.
    static func read() -> WidgetSnapshot? {
        guard let url = fileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StoreCodec.decoder().decode(WidgetSnapshot.self, from: data)
    }

    /// For real timelines: the snapshot on disk, or an all-zero snapshot when nothing has been published yet.
    static func load() -> WidgetSnapshot {
        read() ?? zero
    }

    /// For the widget gallery and placeholders: the snapshot on disk, or believable sample numbers.
    static func loadOrPlaceholder() -> WidgetSnapshot {
        read() ?? WidgetSnapshot.placeholder
    }

    /// Everything zero, no timer, nothing to review.
    static var zero: WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date())
    }
}
