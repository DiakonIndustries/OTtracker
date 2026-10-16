import Foundation

/// RFC 4180 CSV. Handles quoted fields, embedded commas/newlines/quotes, CRLF, BOM.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        fatalError("OTCSV.parse not implemented yet")
    }

    public static func serialize(_ rows: [[String]]) -> String {
        fatalError("OTCSV.serialize not implemented yet")
    }
}
