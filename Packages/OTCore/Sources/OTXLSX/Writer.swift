import Foundation
import OTZip

/// Cell style indexes in the `cellXfs` table the writer emits.
enum CellStyle {
    static let normal = 0
    static let boldHeader = 1
    static let dateTime = 2
    static let dateOnly = 3
    static let number = 4

    static let dateTimeFormatID = 164
    static let dateOnlyFormatID = 165
    static let dateTimeFormat = "yyyy-mm-dd hh:mm"
    static let dateOnlyFormat = "yyyy-mm-dd"
}

extension XLSXWriter {
    static let minColumnWidth = 8.0
    static let maxColumnWidth = 60.0
    static let maxSheetNameLength = 31
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// Serialises the workbook and returns the parts in archive order (path → XML bytes).
    static func parts(for workbook: Workbook, timeZone: TimeZone) -> [(String, Data)] {
        var sheets = workbook.sheets
        if sheets.isEmpty { sheets = [Worksheet(name: "Sheet1")] }
        let names = sanitisedSheetNames(sheets.map { $0.name })

        var parts: [(String, Data)] = []
        parts.append(("[Content_Types].xml", Data(contentTypes(sheetCount: sheets.count).utf8)))
        parts.append(("_rels/.rels", Data(rootRelationships().utf8)))
        parts.append(("xl/workbook.xml", Data(workbookXML(names: names).utf8)))
        parts.append(("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheetCount: sheets.count).utf8)))
        parts.append(("xl/styles.xml", Data(stylesXML().utf8)))
        for (i, sheet) in sheets.enumerated() {
            parts.append(("xl/worksheets/sheet\(i + 1).xml",
                          Data(worksheetXML(sheet, timeZone: timeZone, isFirst: i == 0).utf8)))
        }
        return parts
    }

    // MARK: Package parts

    static func contentTypes(sheetCount: Int) -> String {
        var s = xmlHeader
        s += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...max(1, sheetCount) {
            s += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        s += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        s += "</Types>"
        return s
    }

    static func rootRelationships() -> String {
        xmlHeader
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>"
    }

    static func workbookXML(names: [String]) -> String {
        var s = xmlHeader
        s += "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipsNamespace)\">"
        s += "<bookViews><workbookView activeTab=\"0\"/></bookViews>"
        s += "<sheets>"
        for (i, name) in names.enumerated() {
            s += "<sheet name=\"\(XMLText.escape(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        s += "</sheets>"
        // Formula cells carry no cached value; this asks Excel and LibreOffice to compute them on open.
        s += "<calcPr fullCalcOnLoad=\"1\"/>"
        s += "</workbook>"
        return s
    }

    static func workbookRelationships(sheetCount: Int) -> String {
        var s = xmlHeader
        s += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...max(1, sheetCount) {
            s += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        s += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        s += "</Relationships>"
        return s
    }

    /// cellXfs: 0 default · 1 bold header · 2 date-time · 3 date-only · 4 number `0.00`.
    static func stylesXML() -> String {
        var s = xmlHeader
        s += "<styleSheet xmlns=\"\(mainNamespace)\">"
        s += "<numFmts count=\"2\">"
        s += "<numFmt numFmtId=\"\(CellStyle.dateTimeFormatID)\" formatCode=\"\(CellStyle.dateTimeFormat)\"/>"
        s += "<numFmt numFmtId=\"\(CellStyle.dateOnlyFormatID)\" formatCode=\"\(CellStyle.dateOnlyFormat)\"/>"
        s += "</numFmts>"
        s += "<fonts count=\"2\">"
        s += "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        s += "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        s += "</fonts>"
        s += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        s += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"5\">"
        s += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        s += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        s += "<xf numFmtId=\"\(CellStyle.dateTimeFormatID)\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        s += "<xf numFmtId=\"\(CellStyle.dateOnlyFormatID)\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        s += "<xf numFmtId=\"2\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        s += "</cellXfs>"
        s += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        s += "</styleSheet>"
        return s
    }

    // MARK: Worksheet

    static func worksheetXML(_ sheet: Worksheet, timeZone: TimeZone, isFirst: Bool) -> String {
        let columnCount = sheet.rows.map { $0.count }.max() ?? 0
        let rowCount = sheet.rows.count

        var s = xmlHeader
        s += "<worksheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipsNamespace)\">"
        if rowCount > 0 && columnCount > 0 {
            s += "<dimension ref=\"A1:\(ColumnReference.letters(forIndex: columnCount - 1))\(rowCount)\"/>"
        } else {
            s += "<dimension ref=\"A1\"/>"
        }
        s += "<sheetViews><sheetView workbookViewId=\"0\"\(isFirst ? " tabSelected=\"1\"" : "")>"
        if sheet.freezeHeader {
            s += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            s += "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
        }
        s += "</sheetView></sheetViews>"
        s += "<sheetFormatPr defaultRowHeight=\"15\"/>"

        if columnCount > 0 {
            s += "<cols>"
            for col in 0..<columnCount {
                let width = sheet.columnWidths[col] ?? autoWidth(sheet: sheet, column: col)
                s += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(formatNumber(width))\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }

        s += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            s += "<row r=\"\(r + 1)\">"
            let isHeader = r == 0 && sheet.freezeHeader
            for (c, cell) in row.enumerated() {
                s += cellXML(cell, reference: "\(ColumnReference.letters(forIndex: c))\(r + 1)", header: isHeader, timeZone: timeZone)
            }
            s += "</row>"
        }
        s += "</sheetData>"
        s += "</worksheet>"
        return s
    }

    /// One `<c>` element; `.empty` produces nothing so later references still line up.
    static func cellXML(_ cell: Cell, reference: String, header: Bool, timeZone: TimeZone) -> String {
        func styleAttr(_ style: Int) -> String { style == CellStyle.normal ? "" : " s=\"\(style)\"" }
        let textStyle = header ? CellStyle.boldHeader : CellStyle.normal
        switch cell {
        case .empty:
            return ""
        case .string(let text):
            return "<c r=\"\(reference)\"\(styleAttr(textStyle)) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(text))</t></is></c>"
        case .integer(let i):
            return "<c r=\"\(reference)\"\(styleAttr(textStyle))><v>\(i)</v></c>"
        case .number(let d):
            guard d.isFinite else {
                return "<c r=\"\(reference)\"\(styleAttr(textStyle)) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(String(d)))</t></is></c>"
            }
            return "<c r=\"\(reference)\"\(styleAttr(header ? CellStyle.boldHeader : CellStyle.number))><v>\(formatNumber(d))</v></c>"
        case .bool(let b):
            return "<c r=\"\(reference)\"\(styleAttr(textStyle)) t=\"b\"><v>\(b ? 1 : 0)</v></c>"
        case .formula(let f):
            // `<f>` holds the formula without the leading `=`; tolerate callers that include it.
            let body = f.hasPrefix("=") ? String(f.dropFirst()) : f
            return "<c r=\"\(reference)\"\(styleAttr(textStyle))><f>\(XMLText.escape(body))</f></c>"
        case .date(let date):
            let serial = ExcelDate.serial(from: date, timeZone: timeZone)
            return "<c r=\"\(reference)\"\(styleAttr(CellStyle.dateTime))><v>\(formatSerial(serial))</v></c>"
        case .dateOnly(let date):
            let serial = ExcelDate.serial(from: date, timeZone: timeZone, dateOnly: true)
            return "<c r=\"\(reference)\"\(styleAttr(CellStyle.dateOnly))><v>\(formatSerial(serial))</v></c>"
        }
    }

    /// Shortest round-trip decimal text; integral values keep a `.0` so the reader sees a Double.
    static func formatNumber(_ d: Double) -> String {
        String(d)
    }

    /// Date serials: whole days are written as integers (as Excel does), otherwise shortest decimal text.
    static func formatSerial(_ d: Double) -> String {
        if d == d.rounded(.down), abs(d) < 1e12 { return String(Int(d)) }
        return String(d)
    }

    /// Auto width = longest text in the column + 2, clamped to 8…60.
    static func autoWidth(sheet: Worksheet, column: Int) -> Double {
        var longest = 0
        for row in sheet.rows where column < row.count {
            longest = max(longest, displayLength(row[column]))
        }
        return min(max(Double(longest + 2), minColumnWidth), maxColumnWidth)
    }

    /// Approximate on-screen character count of a cell's display text.
    static func displayLength(_ cell: Cell) -> Int {
        switch cell {
        case .empty: return 0
        case .string(let s): return s.components(separatedBy: "\n").map { $0.count }.max() ?? 0
        case .integer(let i): return String(i).count
        case .number(let d): return d.isFinite ? String(format: "%.2f", d).count : 4
        case .bool: return 5
        case .formula(let f): return min(f.count + 1, 12)
        case .date: return CellStyle.dateTimeFormat.count
        case .dateOnly: return CellStyle.dateOnlyFormat.count
        }
    }

    // MARK: Sheet names

    /// Excel rules: ≤ 31 characters, none of `[]:*?/\`, not empty, not the reserved `History`, unique (case-insensitive).
    static func sanitisedSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for (i, raw) in names.enumerated() {
            var base = sanitiseSheetName(raw)
            if base.isEmpty { base = "Sheet\(i + 1)" }
            if base.lowercased() == "history" { base += "_" }
            var candidate = base
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                let room = maxSheetNameLength - suffix.count
                candidate = String(base.prefix(room)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }

    static func sanitiseSheetName(_ raw: String) -> String {
        let forbidden: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
        var s = String(raw.filter { !forbidden.contains($0) && !$0.isNewline })
        func trim() {
            s = s.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix("'") { s.removeFirst() }
            while s.hasSuffix("'") { s.removeLast() }
            s = s.trimmingCharacters(in: .whitespaces)
        }
        trim()
        if s.count > maxSheetNameLength {
            s = String(s.prefix(maxSheetNameLength))
            trim()   // truncation may expose a trailing space or apostrophe, which Excel rejects
        }
        return s
    }
}
