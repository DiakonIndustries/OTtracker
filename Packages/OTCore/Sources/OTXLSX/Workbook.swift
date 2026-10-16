import Foundation
import OTZip

/// One cell. Dates are instants; the writer converts them to the wall clock of the
/// time zone it is given, which is how Excel thinks about dates.
public enum Cell: Hashable, Sendable {
    case empty
    case string(String)
    case number(Double)
    case integer(Int)
    case date(Date)
    case dateOnly(Date)       // formatted yyyy-mm-dd, no time
    case bool(Bool)
    case formula(String)      // without leading '='

    /// Display text for text-like cells; nil for dates and empty cells.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return String(d)
        case .integer(let i): return String(i)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .formula(let f): return "=" + f
        case .date, .dateOnly, .empty: return nil
        }
    }

    /// Numeric value, parsing numeric strings; nil for non-numeric cells.
    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The instant of a `.date` or `.dateOnly` cell.
    public var dateValue: Date? {
        switch self {
        case .date(let d), .dateOnly(let d): return d
        default: return nil
        }
    }
}

/// One sheet: a name, row-major cells, optional column widths and a frozen header flag.
public struct Worksheet: Hashable, Sendable {
    public var name: String
    /// Row-major. The first row is treated as the header when `freezeHeader` is true.
    public var rows: [[Cell]]
    /// Column widths in characters, keyed by zero-based column index. nil → auto.
    public var columnWidths: [Int: Double]
    public var freezeHeader: Bool

    public init(name: String, rows: [[Cell]] = [], columnWidths: [Int: Double] = [:], freezeHeader: Bool = true) {
        self.name = name
        self.rows = rows
        self.columnWidths = columnWidths
        self.freezeHeader = freezeHeader
    }

    /// The first row rendered as text (empty strings for non-text cells).
    public var header: [String] { rows.first?.map { $0.stringValue ?? "" } ?? [] }

    /// Rows after the header as dictionaries keyed by header text.
    public var records: [[String: Cell]] {
        let h = header
        return rows.dropFirst().map { row in
            var d: [String: Cell] = [:]
            for (i, key) in h.enumerated() where i < row.count { d[key] = row[i] }
            return d
        }
    }
}

/// An ordered collection of worksheets.
public struct Workbook: Hashable, Sendable {
    public var sheets: [Worksheet]

    public init(sheets: [Worksheet] = []) {
        self.sheets = sheets
    }

    /// Case-insensitive lookup by sheet name.
    public func sheet(named name: String) -> Worksheet? {
        sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Reader failures: not a zip/workbook, a required part missing, or unparseable XML.
public enum XLSXError: Error, Equatable {
    case notAWorkbook
    case missingPart(String)
    case malformed(String)
}

/// Writes OOXML workbooks (inline strings, five fixed cell styles, stored zip entries).
public enum XLSXWriter {
    /// Serialises to `.xlsx` bytes. `timeZone` decides the wall-clock of date cells; trailing empty cells in a row are not written.
    public static func write(_ workbook: Workbook, timeZone: TimeZone) throws -> Data {
        let entries = parts(for: workbook, timeZone: timeZone).map { ZipEntry(path: $0.0, data: $0.1) }
        return ZipWriter.archive(entries)
    }
}

/// Reads OOXML workbooks from Excel, Numbers, Google Sheets, openpyxl/XlsxWriter and this app.
public enum XLSXReader {
    /// Parses `.xlsx` bytes (from this app, Excel, Numbers or Google Sheets).
    /// Date-styled numeric cells become `.date` interpreted in `timeZone`.
    public static func read(_ data: Data, timeZone: TimeZone) throws -> Workbook {
        try readWorkbook(data, timeZone: timeZone)
    }
}
