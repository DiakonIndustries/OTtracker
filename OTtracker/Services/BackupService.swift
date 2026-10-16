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

    func list() async throws -> [BackupInfo] {
        try await Task.detached(priority: .utility) { [self] in
            let dir = try self.backupsDirectory()
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            return urls.filter { $0.pathExtension == "json" }.compactMap { url -> BackupInfo? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupInfo(url: url, modified: values?.contentModificationDate ?? .distantPast, sizeBytes: values?.fileSize ?? 0)
            }.sorted { $0.modified > $1.modified }
        }.value
    }

    func read(_ info: BackupInfo) async throws -> Data {
        try await Task.detached(priority: .utility) {
            // Make sure the file is downloaded from iCloud before reading.
            try? FileManager.default.startDownloadingUbiquitousItem(at: info.url)
            var attempts = 0
            while attempts < 20 {
                if let values = try? info.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   let status = values.ubiquitousItemDownloadingStatus, status != .current {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    attempts += 1
                    continue
                }
                break
            }
            return try Data(contentsOf: info.url)
        }.value
    }
}

enum BackupError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud Drive is not available. Sign in to iCloud and enable iCloud Drive for OTtracker."
        }
    }
}

final class NoopBackupService: BackupServicing {
    func isAvailable() async -> Bool { false }
    func write(_ data: Data, now: Date) async throws -> URL { throw BackupError.unavailable }
    func list() async throws -> [BackupInfo] { [] }
    func read(_ info: BackupInfo) async throws -> Data { throw BackupError.unavailable }
}
