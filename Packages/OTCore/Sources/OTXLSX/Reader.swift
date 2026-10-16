import Foundation
import OTZip
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Package

/// The unzipped package: parts by normalised path.
struct XLSXPackage {
    var parts: [String: Data]
    private var lowercased: [String: String]

    init(zip data: Data) throws {
        let entries: [ZipEntry]
        do {
            entries = try ZipReader.entries(from: data)
        } catch {
            throw XLSXError.notAWorkbook
        }
        var parts: [String: Data] = [:]
        var lower: [String: String] = [:]
        for e in entries {
            let p = XLSXPackage.normalise(e.path)
            parts[p] = e.data
            lower[p.lowercased()] = p
        }
        guard !parts.isEmpty else { throw XLSXError.notAWorkbook }
        self.parts = parts
        self.lowercased = lower
    }

    /// Exact path first, then a case-insensitive match.
    func part(_ path: String) -> Data? {
        let p = XLSXPackage.normalise(path)
        if let d = parts[p] { return d }
        if let real = lowercased[p.lowercased()] { return parts[real] }
        return nil
    }

    func requiredPart(_ path: String) throws -> Data {
        guard let d = part(path) else { throw XLSXError.missingPart(XLSXPackage.normalise(path)) }
        return d
    }

    /// Collapses `.`/`..` segments, strips a leading slash and backslashes.
    static func normalise(_ path: String) -> String {
        var out: [Substring] = []
        for seg in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(seg)
        }
        return out.joined(separator: "/")
    }

    /// Resolves a relationship target against the directory of the part that owns the `.rels`.
    static func resolve(target: String, baseDirectory: String) -> String {
        if target.hasPrefix("/") { return normalise(target) }
        return normalise(baseDirectory.isEmpty ? target : baseDirectory + "/" + target)
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    static func relsPath(for partPath: String) -> String {
        let dir = directory(of: partPath)
        let file = partPath.split(separator: "/").last.map(String.init) ?? partPath
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
    }
}

// MARK: - XML plumbing

/// Base delegate: runs the parser, strips namespace prefixes, accumulates character data.
class PartParser: NSObject, XMLParserDelegate {
    let partName: String
    var text = ""
    var collectingText = false
    var failure: XLSXError?
    private var depth = 0

    init(partName: String) {
        self.partName = partName
    }

    func run(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let ok = parser.parse()
        if let failure { throw failure }
        if !ok {
            let reason = parser.parserError.map { String(describing: $0) } ?? "XML parse error"
            throw XLSXError.malformed("\(partName): \(reason)")
        }
        // Linux's XMLParser can accept a document that ends mid-element; treat that as malformed everywhere.
        guard depth == 0 else { throw XLSXError.malformed("\(partName): unterminated document") }
    }

    static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    static func attribute(_ name: String, in attributes: [String: String]) -> String? {
        if let v = attributes[name] { return v }
        for (k, v) in attributes where local(k) == name { return v }
        return nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if collectingText { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        start(PartParser.local(elementName), attributeDict)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        end(PartParser.local(elementName))
    }

    func start(_ element: String, _ attributes: [String: String]) {}
    func end(_ element: String) {}
}

/// `.rels` parts: relationship id → (type, target).
final class RelationshipsParser: PartParser {
    struct Relationship { var id: String; var type: String; var target: String }
    var relationships: [Relationship] = []

    override func start(_ element: String, _ a: [String: String]) {
        guard element == "Relationship" else { return }
        relationships.append(Relationship(id: PartParser.attribute("Id", in: a) ?? "",
                                          type: PartParser.attribute("Type", in: a) ?? "",
                                          target: PartParser.attribute("Target", in: a) ?? ""))
    }

    func byID(_ id: String) -> Relationship? { relationships.first { $0.id == id } }
    func first(typeSuffix: String) -> Relationship? { relationships.first { $0.type.hasSuffix(typeSuffix) } }
}

/// `xl/workbook.xml`: sheet names with their relationship ids, in order.
final class WorkbookPartParser: PartParser {
    struct SheetRef { var name: String; var relationshipID: String? }
    var sheets: [SheetRef] = []

    override func start(_ element: String, _ a: [String: String]) {
        guard element == "sheet" else { return }
        sheets.append(SheetRef(name: PartParser.attribute("name", in: a) ?? "Sheet\(sheets.count + 1)",
                               relationshipID: PartParser.attribute("id", in: a)))
    }
}

/// `xl/sharedStrings.xml`: each `<si>` flattened to one string (rich-text runs concatenated, phonetics dropped).
final class SharedStringsParser: PartParser {
    var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var phoneticDepth = 0

    override func start(_ element: String, _ a: [String: String]) {
        switch element {
        case "si": inItem = true; current = ""
        case "rPh": phoneticDepth += 1
        case "t": if inItem && phoneticDepth == 0 { text = ""; collectingText = true }
        default: break
        }
    }

    override func end(_ element: String) {
        switch element {
        case "t":
            if collectingText { current += text; collectingText = false; text = "" }
        case "rPh": phoneticDepth = max(0, phoneticDepth - 1)
        case "si":
            strings.append(XLSXReader.decodeEscapes(current))
            inItem = false
        default: break
        }
    }
}

/// `xl/styles.xml`: which `cellXfs` indexes render as dates.
final class StylesParser: PartParser {
    var customFormats: [Int: String] = [:]
    var cellXfNumFmtIDs: [Int] = []
    private var inCellXfs = false

    override func start(_ element: String, _ a: [String: String]) {
        switch element {
        case "numFmt":
            if let idText = PartParser.attribute("numFmtId", in: a), let id = Int(idText) {
                customFormats[id] = PartParser.attribute("formatCode", in: a) ?? ""
            }
        case "cellXfs": inCellXfs = true
        case "xf":
            if inCellXfs {
                cellXfNumFmtIDs.append(Int(PartParser.attribute("numFmtId", in: a) ?? "") ?? 0)
            }
        default: break
        }
    }

    override func end(_ element: String) {
        if element == "cellXfs" { inCellXfs = false }
    }

    /// True when cell style `index` formats numbers as dates or times.
    func isDateStyle(_ index: Int) -> Bool {
        guard index >= 0, index < cellXfNumFmtIDs.count else { return false }
        return StylesParser.isDateFormat(id: cellXfNumFmtIDs[index], customFormats: customFormats)
    }

    static let builtInDateIDs: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    static func isDateFormat(id: Int, customFormats: [Int: String]) -> Bool {
        if let code = customFormats[id] { return isDateFormatCode(code) }
        return builtInDateIDs.contains(id)
    }

    /// A format code is a date when `y m d h` survive outside quotes/brackets/escapes and it is not General.
    static func isDateFormatCode(_ code: String) -> Bool {
        var stripped = ""
        var inQuote = false
        var inBracket = false
        var escapeNext = false
        var skipNext = false
        for ch in code {
            if skipNext { skipNext = false; continue }
            if escapeNext { escapeNext = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket { if ch == "]" { inBracket = false }; continue }
            switch ch {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\": escapeNext = true
            case "_", "*": skipNext = true
            default: stripped.append(ch)
            }
        }
        let lower = stripped.lowercased()
        if lower.contains("general") { return false }
        return lower.contains("y") || lower.contains("m") || lower.contains("d") || lower.contains("h")
    }
}

/// One `xl/worksheets/sheetN.xml` → rows of `Cell`, plus frozen header and column widths.
final class WorksheetParser: PartParser {
    let sharedStrings: [String]
    let styles: StylesParser?
    let timeZone: TimeZone

    var rows: [[Cell]] = []
    var freezeHeader = false
    var columnWidths: [Int: Double] = [:]

    private var inSheetData = false
    private var currentRow: [Cell] = []
    private var inRow = false
    private var inCell = false
    private var cellColumn = 0
    private var cellType: String?
    private var cellStyle: Int?
    private var value: String?
    private var formula: String?
    private var inlineText: String?
    private var phoneticDepth = 0
    private var inInline = false

    init(partName: String, sharedStrings: [String], styles: StylesParser?, timeZone: TimeZone) {
        self.sharedStrings = sharedStrings
        self.styles = styles
        self.timeZone = timeZone
        super.init(partName: partName)
    }

    override func start(_ element: String, _ a: [String: String]) {
        switch element {
        case "sheetData":
            inSheetData = true
        case "pane":
            if PartParser.attribute("state", in: a) == "frozen",
               let y = PartParser.attribute("ySplit", in: a), (Double(y) ?? 0) >= 1 {
                freezeHeader = true
            }
        case "col":
            if let minText = PartParser.attribute("min", in: a), let lo = Int(minText),
               let maxText = PartParser.attribute("max", in: a), let hi = Int(maxText),
               let widthText = PartParser.attribute("width", in: a), let width = Double(widthText),
               lo >= 1, hi >= lo {
                for col in lo...min(hi, lo + 1023) { columnWidths[col - 1] = width }
            }
        case "row":
            guard inSheetData else { return }
            if let rText = PartParser.attribute("r", in: a), let r = Int(rText), r >= 1 {
                while rows.count < r - 1 { rows.append([]) }
            }
            currentRow = []
            inRow = true
        case "c":
            guard inRow else { return }
            inCell = true
            cellType = PartParser.attribute("t", in: a)
            cellStyle = Int(PartParser.attribute("s", in: a) ?? "")
            value = nil
            formula = nil
            inlineText = nil
            if let ref = PartParser.attribute("r", in: a), let col = ColumnReference.index(ofReference: ref) {
                cellColumn = col
            } else {
                cellColumn = currentRow.count
            }
        case "v", "f":
            guard inCell else { return }
            text = ""
            collectingText = true
        case "is":
            guard inCell else { return }
            inInline = true
            inlineText = inlineText ?? ""
        case "rPh":
            phoneticDepth += 1
        case "t":
            guard inCell, inInline, phoneticDepth == 0 else { return }
            text = ""
            collectingText = true
        default:
            break
        }
    }

    override func end(_ element: String) {
        switch element {
        case "sheetData":
            inSheetData = false
        case "v":
            guard inCell else { return }
            value = text
            collectingText = false
            text = ""
        case "f":
            guard inCell else { return }
            formula = text
            collectingText = false
            text = ""
        case "t":
            guard inCell, inInline, collectingText else { return }
            inlineText = (inlineText ?? "") + text
            collectingText = false
            text = ""
        case "is":
            inInline = false
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "c":
            guard inCell else { return }
            inCell = false
            while currentRow.count < cellColumn { currentRow.append(.empty) }
            let cell = makeCell()
            if cellColumn < currentRow.count { currentRow[cellColumn] = cell } else { currentRow.append(cell) }
        case "row":
            guard inRow else { return }
            inRow = false
            rows.append(currentRow)
            currentRow = []
        default:
            break
        }
    }

    private func makeCell() -> Cell {
        let type = cellType ?? "n"
        switch type {
        case "inlineStr":
            return .string(XLSXReader.decodeEscapes(inlineText ?? ""))
        case "s":
            guard let v = value, let index = Int(v.trimmingCharacters(in: .whitespaces)),
                  index >= 0, index < sharedStrings.count else { return .empty }
            return .string(sharedStrings[index])
        case "b":
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return formulaOrEmpty() }
            return .bool(v == "1" || v.lowercased() == "true")
        case "str", "e":
            guard let v = value else { return formulaOrEmpty() }
            return .string(XLSXReader.decodeEscapes(v))
        case "d":
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return formulaOrEmpty() }
            return XLSXReader.parseISODate(v, timeZone: timeZone) ?? .string(v)
        default:
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return formulaOrEmpty() }
            guard let d = Double(v) else { return .string(v) }
            if let style = cellStyle, styles?.isDateStyle(style) == true,
               let date = ExcelDate.date(fromSerial: d, timeZone: timeZone) {
                return ExcelDate.isWholeDay(d) ? .dateOnly(date) : .date(date)
            }
            if !v.contains(".") && !v.contains("e") && !v.contains("E"), let i = Int(v) { return .integer(i) }
            return .number(d)
        }
    }

    private func formulaOrEmpty() -> Cell {
        if let f = formula, !f.isEmpty { return .formula(f) }
        return .empty
    }
}

// MARK: - Reader entry points

extension XLSXReader {
    /// Full read: locate the workbook via `_rels/.rels`, then sheets in workbook order.
    static func readWorkbook(_ data: Data, timeZone: TimeZone) throws -> Workbook {
        let package = try XLSXPackage(zip: data)

        var workbookPath = "xl/workbook.xml"
        if let rootRels = package.part("_rels/.rels") {
            let p = RelationshipsParser(partName: "_rels/.rels")
            try p.run(rootRels)
            if let office = p.first(typeSuffix: "/officeDocument") {
                workbookPath = XLSXPackage.resolve(target: office.target, baseDirectory: "")
            }
        }
        let workbookData = try package.requiredPart(workbookPath)
        let workbookDir = XLSXPackage.directory(of: workbookPath)

        let workbookParser = WorkbookPartParser(partName: workbookPath)
        try workbookParser.run(workbookData)

        let relsPath = XLSXPackage.relsPath(for: workbookPath)
        let rels = RelationshipsParser(partName: relsPath)
        try rels.run(try package.requiredPart(relsPath))

        var sharedStrings: [String] = []
        let sharedTarget = rels.first(typeSuffix: "/sharedStrings").map {
            XLSXPackage.resolve(target: $0.target, baseDirectory: workbookDir)
        } ?? (workbookDir.isEmpty ? "sharedStrings.xml" : workbookDir + "/sharedStrings.xml")
        if let ssData = package.part(sharedTarget) {
            let p = SharedStringsParser(partName: sharedTarget)
            try p.run(ssData)
            sharedStrings = p.strings
        }

        var styles: StylesParser?
        let stylesTarget = rels.first(typeSuffix: "/styles").map {
            XLSXPackage.resolve(target: $0.target, baseDirectory: workbookDir)
        } ?? (workbookDir.isEmpty ? "styles.xml" : workbookDir + "/styles.xml")
        if let stData = package.part(stylesTarget) {
            let p = StylesParser(partName: stylesTarget)
            try p.run(stData)
            styles = p
        }

        var sheets: [Worksheet] = []
        for ref in workbookParser.sheets {
            guard let rid = ref.relationshipID, let rel = rels.byID(rid) else {
                throw XLSXError.missingPart("worksheet for sheet \"\(ref.name)\"")
            }
            let path = XLSXPackage.resolve(target: rel.target, baseDirectory: workbookDir)
            let sheetData = try package.requiredPart(path)
            let p = WorksheetParser(partName: path, sharedStrings: sharedStrings, styles: styles, timeZone: timeZone)
            try p.run(sheetData)
            sheets.append(Worksheet(name: ref.name, rows: p.rows, columnWidths: p.columnWidths, freezeHeader: p.freezeHeader))
        }
        return Workbook(sheets: sheets)
    }

    /// Decodes Excel's `_xHHHH_` escapes for characters XML cannot carry.
    static func decodeEscapes(_ s: String) -> String {
        guard s.contains("_x") else { return s }
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "_", i + 6 < chars.count, chars[i + 1] == "x", chars[i + 6] == "_",
               let code = UInt32(String(chars[(i + 2)...(i + 5)]), radix: 16),
               let scalar = UnicodeScalar(code) {
                out.unicodeScalars.append(scalar)
                i += 7
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// Parses `yyyy-mm-dd` or `yyyy-mm-ddThh:mm:ss(.fff)(Z)` as wall-clock time in `timeZone`.
    static func parseISODate(_ raw: String, timeZone: TimeZone) -> Cell? {
        let trimmed = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
        let halves = trimmed.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard let datePart = halves.first else { return nil }
        let ymd = datePart.split(separator: "-")
        guard ymd.count == 3, let y = Int(ymd[0]), let m = Int(ymd[1]), let d = Int(ymd[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if halves.count == 2, !halves[1].isEmpty {
            let hms = halves[1].split(separator: ":")
            guard hms.count >= 2, let h = Int(hms[0]), let mi = Int(hms[1]), (0...23).contains(h), (0...59).contains(mi) else { return nil }
            let secondsText = hms.count > 2 ? hms[2].split(separator: ".").first.map(String.init) ?? "0" : "0"
            guard let s = Int(secondsText), (0...60).contains(s) else { return nil }
            c.hour = h
            c.minute = mi
            c.second = s
            guard let date = cal.date(from: c) else { return nil }
            return .date(date)
        }
        guard let date = cal.date(from: c) else { return nil }
        return .dateOnly(date)
    }
}
