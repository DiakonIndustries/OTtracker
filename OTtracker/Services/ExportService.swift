import Foundation
import OTCore

/// A monthly Excel file that was generated automatically.
struct MonthlyExportFile: Identifiable, Hashable {
    /// `yyyy-MM`
    var month: String
    var url: URL
    var id: String { month }

    var title: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return month }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        var c = DateComponents(); c.year = y; c.month = m; c.day = 1
        return Calendar.current.date(from: c).map { f.string(from: $0) } ?? month
    }
}

/// Builds files for sharing and finds the automatic monthly exports on disk.
enum ExportService {
    static func monthlyURL(for month: String) -> URL {
        AppFiles.exports.appendingPathComponent("OTtracker-\(month).xlsx")
    }

    static func existingMonthlyExports() -> [MonthlyExportFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppFiles.exports, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> MonthlyExportFile? in
            let name = url.lastPathComponent
            guard name.hasPrefix("OTtracker-"), name.hasSuffix(".xlsx") else { return nil }
            let month = String(name.dropFirst("OTtracker-".count).dropLast(".xlsx".count))
            guard month.count == 7, month[month.index(month.startIndex, offsetBy: 4)] == "-" else { return nil }
            return MonthlyExportFile(month: month, url: url)
        }.sorted { $0.month > $1.month }
    }

    /// Writes an xlsx for the range into `directory` and returns its URL.
    ///
    /// The Summary sheet (balance, month/week/YTD figures, leave balances) is taken at the end of the
    /// range when it ends before today, so the automatic monthly file describes that month rather than
    /// the day it was generated; ranges that run through today use `now`.
    static func writeXLSX(store: Store, from: DayKey, through: DayKey, now: Date, to directory: URL, filename: String) throws -> URL {
        let cal = store.calendar
        let asOf = min(now, through.end(in: cal).addingTimeInterval(-1))
        let results = Ledger.dayResults(store: store, from: from, through: through, now: now)
        let summary = Ledger.summary(store: store, now: asOf)
        let balances = Ledger.leaveBalances(store: store, asOf: min(through, DayKey(now, calendar: cal)))
        // The Days sheet's running balance must continue the real bank balance when the range
        // starts after tracking began, not restart at the configured starting balance.
        let trackingStart = Ledger.trackingStart(store: store, now: now)
        let opening: Int? = from > trackingStart
            ? Ledger.balance(store: store, asOf: from.adding(days: -1, calendar: cal), now: now)
            : nil
        let data = try ExportBuilder.xlsx(store: store, dayResults: results, from: from, through: through, now: now,
                                          summary: summary, leaveBalances: balances, openingBalanceSeconds: opening)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func writeJSON(store: Store, to directory: URL, filename: String) throws -> URL {
        let data = try ExportBuilder.json(store: store)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func writeCSVTemplate(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("OTtracker-import-template.csv")
        try ExportBuilder.csvTemplate().data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
