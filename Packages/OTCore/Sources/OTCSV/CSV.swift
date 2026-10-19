import Foundation

/// RFC 4180 CSV. Handles quoted fields, embedded commas/newlines/quotes, CRLF, BOM.
public enum CSV {
    /// Parses CSV text into rows of fields.
    ///
    /// Rules: a leading UTF-8 BOM is ignored; records end at CRLF, LF or a lone CR; a trailing
    /// line break adds no row; a blank line is one empty field (`[""]`); fields that start with
    /// `"` may contain commas, quotes (`""`) and line breaks; ragged rows are kept as they are;
    /// empty input gives `[]`. Text after a closing quote is kept literally (tolerant).
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false      // a character of the current field has been consumed
        var rowStarted = false        // anything at all has been consumed on this line

        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var i = 0
        if n > 0 && scalars[0] == "\u{FEFF}" { i = 1 }

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
            rowStarted = false
        }

        while i < n {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < n && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case "\"":
                if fieldStarted {
                    field.append(c)   // stray quote inside an unquoted field: keep it
                } else {
                    inQuotes = true
                    fieldStarted = true
                }
                rowStarted = true
                i += 1
            case ",":
                endField()
                rowStarted = true
                i += 1
            case "\r":
                endRow()
                i += 1
                if i < n && scalars[i] == "\n" { i += 1 }
            case "\n":
                endRow()
                i += 1
            default:
                field.append(c)
                fieldStarted = true
                rowStarted = true
                i += 1
            }
        }
        if rowStarted || inQuotes { endRow() }
        return rows
    }

    /// Serialises rows as CSV: fields containing a comma, quote, CR, LF or a leading/trailing
    /// space are quoted (quotes doubled); records end with CRLF; the output ends with a line
    /// break when there is at least one row. `[]` gives `""`.
    public static func serialize(_ rows: [[String]]) -> String {
        var out = ""
        for row in rows {
            out += row.map(escape).joined(separator: ",")
            out += "\r\n"
        }
        return out
    }

    /// Quotes a single field when RFC 4180 (or a leading/trailing space) requires it.
    public static func escape(_ field: String) -> String {
        let needsQuotes = field.hasPrefix(" ") || field.hasSuffix(" ")
            || field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
