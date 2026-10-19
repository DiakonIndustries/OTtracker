import Foundation
import OTCore

/// JSON snapshots in the app's iCloud Drive container: Documents/Backups/.
final class ICloudBackupService: BackupServicing {
    private let keepCount = 30

    private func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    private func backupsDirectory() throws -> URL {
        guard let root = containerURL() else { throw BackupError.unavailable }
        let dir = root.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func isAvailable() async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            FileManager.default.ubiquityIdentityToken != nil && self.containerURL() != nil
        }.value
    }

    func write(_ data: Data, now: Date) async throws -> URL {
        try await Task.detached(priority: .utility) { [self] in
            let dir = try self.backupsDirectory()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            let dated = dir.appendingPathComponent("OTtracker-\(f.string(from: now)).json")
            let latest = dir.appendingPathComponent("OTtracker-latest.json")
            try data.write(to: dated, options: .atomic)
            try data.write(to: latest, options: .atomic)
            try self.prune(in: dir)
            return latest
        }.value
    }

    private func prune(in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("OTtracker-") && $0.lastPathComponent != "OTtracker-latest.json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files.dropFirst(keepCount) { try? FileManager.default.removeItem(at: f) }
    }

    /// Every backup in the container, newest first. On a new phone the files are still in iCloud and
    /// appear locally as `.OTtracker-x.json.icloud` placeholders; those are listed under their real
    /// name and their download is started so `read` can wait for them.
    func list() async throws -> [BackupInfo] {
        try await Task.detached(priority: .utility) { [self] in
            let dir = try self.backupsDirectory()
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            return urls.compactMap { url -> BackupInfo? in
                var name = url.lastPathComponent
                var real = url
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    // Not yet downloaded from iCloud: ".OTtracker-x.json.icloud" -> "OTtracker-x.json"
                    name = String(name.dropFirst().dropLast(".icloud".count))
                    real = dir.appendingPathComponent(name)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                }
                guard name.hasPrefix("OTtracker-"), name.hasSuffix(".json") else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupInfo(url: real, modified: values?.contentModificationDate ?? .distantPast, sizeBytes: values?.fileSize ?? 0)
            }.sorted { $0.modified > $1.modified }
        }.value
    }

    func read(_ info: BackupInfo) async throws -> Data {
        try await Task.detached(priority: .utility) {
            // Make sure the file is downloaded from iCloud before reading.
            try? FileManager.default.startDownloadingUbiquitousItem(at: info.url)
            var attempts = 0
            while attempts < 40 {
                // Resource values are cached on the URL's backing NSURL and are never purged off the
                // main thread, so probe a fresh URL value each iteration.
                let probe = URL(fileURLWithPath: info.url.path)
                let exists = FileManager.default.fileExists(atPath: probe.path)
                let status = (try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if exists, status == nil || status == .current { break }
                try await Task.sleep(nanoseconds: 500_000_000)
                attempts += 1
            }
            // On timeout, read whatever local copy exists (.downloaded); otherwise fail clearly.
            guard FileManager.default.fileExists(atPath: info.url.path) else { throw BackupError.notDownloaded }
            return try Data(contentsOf: info.url)
        }.value
    }
}

enum BackupError: LocalizedError {
    case unavailable
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud Drive is not available. Sign in to iCloud and enable iCloud Drive for OTtracker."
        case .notDownloaded: return "This backup has not finished downloading from iCloud. Check your connection and try again in a moment."
        }
    }
}

final class NoopBackupService: BackupServicing {
    func isAvailable() async -> Bool { false }
    func write(_ data: Data, now: Date) async throws -> URL { throw BackupError.unavailable }
    func list() async throws -> [BackupInfo] { [] }
    func read(_ info: BackupInfo) async throws -> Data { throw BackupError.unavailable }
}
