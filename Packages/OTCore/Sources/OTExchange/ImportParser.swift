import Foundation
import OTModels
import OTXLSX
import OTCSV

/// Detects the format and parses into an `ImportBundle`. Never mutates the store.
public enum ImportParser {
    /// Format by file extension (`.xlsx`, `.json`, `.csv`), otherwise by content: a zip signature is
    /// xlsx, a leading `{` is json, readable text is csv. A csv whose header is exactly `date,name`
    /// is `holidaysCSV`. Empty or binary data of unknown shape gives nil.
    public static func detectFormat(data: Data, filename: String) -> ImportFormat? {
        let ext = fileExtension(filename)
        switch ext {
        case "xlsx": return .xlsx
        case "json": return .json
        case "csv": return decodeText(data).map(csvKind) ?? .csv
        default: break
        }
        guard !data.isEmpty else { return nil }
        if data.count >= 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B,
           data[data.startIndex + 2] == 0x03, data[data.startIndex + 3] == 0x04 {
            return .xlsx
        }
        if let first = firstSignificantByte(data), first == 0x7B { return .json }
        guard looksLikeText(data), let text = decodeText(data) else { return nil }
        return csvKind(text)
    }

    /// Detects the format and parses. Throws `unrecognizedFormat` or `unreadable`.
    public static func parse(data: Data, filename: String, store: Store) throws -> ImportBundle {
        guard let format = detectFormat(data: data, filename: filename) else { throw ImportError.unrecognizedFormat }
        switch format {
        case .xlsx:
            let workbook: Workbook
            do { workbook = try XLSXReader.read(data, timeZone: store.settings.timeZone) }
            catch { throw ImportError.unreadable("Could not read the Excel file: \(error)") }
            // Excel dates are wall-clock in the zone the file was written in (its Settings sheet). When the
            // store is set to another zone, read the cells again in the file's zone so every instant is kept.
            if let tz = workbookTimeZone(workbook), tz.identifier != store.settings.timeZoneIdentifier,
               let reread = try? XLSXReader.read(data, timeZone: tz) {
                return parse(workbook: reread, store: store)
            }
            return parse(workbook: workbook, store: store)
        case .json:
            return try parse(json: data)
        case .csv, .holidaysCSV:
            guard let text = decodeText(data) else { throw ImportError.unreadable("The file is not UTF-8 text") }
            return parse(csvText: text, store: store)
        }
    }

    /// A JSON backup written by this app: `fullStore` plus every record flattened into rows so
    /// Merge works too (presence and time-off rows carry the names from that store).
    public static func parse(json data: Data) throws -> ImportBundle {
        let full: Store
        do { full = try StoreCodec.decode(data) }
        catch { throw ImportError.unreadable("Not an OTtracker JSON backup: \(error)") }
        var b = ImportBundle()
        b.fullStore = full
        b.presence = full.presence.map { s in
            ImportBundle.PresenceRow(id: s.id, locationName: full.location(id: s.locationID)?.name ?? s.locationID.uuidString,
                                     enteredAt: s.enteredAt, exitedAt: s.exitedAt, source: s.source,
                                     followingGapIsWork: s.followingGapIsWork, note: s.note)
        }
        b.manual = full.manual
        b.timeOff = full.timeOff.map { t in
            ImportBundle.TimeOffRow(id: t.id, day: t.day, typeName: full.timeOffType(id: t.typeID)?.name ?? t.typeID.uuidString,
                                    seconds: t.seconds, note: t.note)
        }
        b.holidays = full.holidays
        b.adjustments = full.adjustments
        b.locations = full.locations
        b.overrides = full.overrides
        b.schedules = full.schedules
        b.events = full.locationEvents
        b.timeOffTypes = full.timeOffTypes
        b.leaveBalances = full.leaveBalances
        b.settings = full.settings
        return b
    }

    // MARK: Helpers

    static func fileExtension(_ filename: String) -> String {
        let name = filename.split(separator: "/").last.map(String.init) ?? filename
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func firstSignificantByte(_ data: Data) -> UInt8? {
        var bytes = data[...]
        if bytes.count >= 3, bytes[bytes.startIndex] == 0xEF, bytes[bytes.startIndex + 1] == 0xBB, bytes[bytes.startIndex + 2] == 0xBF {
            bytes = bytes.dropFirst(3)
        }
        return bytes.first { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }
    }

    /// Text never carries control bytes other than tab, line feed, carriage return and form feed;
    /// anything else (zip, image, random bytes) is binary even though Latin-1 would "decode" it.
    static func looksLikeText(_ data: Data) -> Bool {
        !data.contains { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C }
    }

    /// UTF-8 (BOM allowed) or, failing that, Latin-1 text.
    static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func csvKind(_ text: String) -> ImportFormat {
        isHolidaysHeader(headerOf(csvText: text)) ? .holidaysCSV : .csv
    }

    /// `date,name` in either order; empty (trailing-comma) columns do not count.
    static func isHolidaysHeader(_ header: [String]) -> Bool {
        let named = header.filter { !$0.isEmpty }
        return named.count == 2 && Set(named) == ["date", "name"]
    }

    /// Normalised header fields of the first CSV record.
    static func headerOf(csvText: String) -> [String] {
        // Only the first record matters; avoid parsing a large file twice.
        let firstLineEnd = csvText.firstIndex { $0 == "\n" || $0 == "\r" || $0 == "\r\n" } ?? csvText.endIndex
        let firstLine = String(csvText[..<firstLineEnd])
        return (CSV.parse(firstLine).first ?? []).map { ExchangeFormat.headerKey($0) }
    }
}
