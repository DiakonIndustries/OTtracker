import Foundation
import OTCore

/// Where the `Store` JSON lives. One document, written atomically.
protocol StoreRepository: AnyObject {
    func load() throws -> Store?
    func save(_ store: Store) throws
}

final class FileStoreRepository: StoreRepository {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Application Support/OTtracker/store.json
    static func `default`() -> FileStoreRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OTtracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStoreRepository(url: dir.appendingPathComponent("store.json"))
    }

    func load() throws -> Store? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try StoreCodec.decode(data)
    }

    func save(_ store: Store) throws {
        let data = try StoreCodec.encode(store)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Keeps everything in memory. Used by previews and tests.
final class InMemoryStoreRepository: StoreRepository {
    var store: Store?

    init(store: Store? = nil) {
        self.store = store
    }

    func load() throws -> Store? { store }

    func save(_ store: Store) throws { self.store = store }
}

/// App-level file locations.
enum AppFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// Documents/Exports — visible in the Files app.
    static var exports: URL {
        let dir = documents.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scratch files for the share sheet.
    static var shareScratch: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// App Group container shared with the widget extension (nil when the entitlement is missing).
    static var appGroup: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)
    }
}
