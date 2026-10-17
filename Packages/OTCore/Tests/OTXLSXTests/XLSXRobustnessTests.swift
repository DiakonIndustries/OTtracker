import XCTest
import OTZip
@testable import OTXLSX

// MARK: - Reader edge cases

final class XLSXReaderRobustnessTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    /// Rebuilds the sample package with one part replaced (or added).
    private func package(replacing path: String, with xml: String) -> Data {
        var parts = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        if let i = parts.firstIndex(where: { $0.0 == path }) { parts[i] = (path, Data(xml.utf8)) } else { parts.append((path, Data(xml.utf8))) }
        return ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) })
    }

    private func sheet(_ body: String, prefix: String = "") -> String {
        let ns = prefix.isEmpty ? "xmlns=\"\(XLSXWriter.mainNamespace)\"" : "xmlns:\(prefix.dropLast())=\"\(XLSXWriter.mainNamespace)\""
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(prefix)worksheet \(ns)><\(prefix)sheetData>\(body)</\(prefix)sheetData></\(prefix)worksheet>"
    }

    func testSharedStringIndexOutOfRangeThrows() {
        let sst = "<sst xmlns=\"\(XLSXWriter.mainNamespace)\"><si><t>only</t></si></sst>"
        var parts = XLSXWriter.parts(for: Workbook(sheets: [Worksheet(name: "S", rows: [[.string("x")]])]), timeZone: ny)
        parts.append(("xl/sharedStrings.xml", Data(sst.utf8)))
        // The relationship to the shared strings part is what the reader follows.
        parts[3] = ("xl/_rels/workbook.xml.rels", Data("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
            </Relationships>
            """.utf8))
        for bad in ["1", "-1", "99999999999999999999", "abc", ""] {
            parts[5] = ("xl/worksheets/sheet1.xml", Data(sheet("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>\(bad)</v></c></row>").utf8))
            let data = ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) })
            XCTAssertThrowsError(try XLSXReader.read(data, timeZone: ny), "index \(bad)") { error in
                guard case .malformed(let what)? = error as? XLSXError else { return XCTFail("\(bad): \(error)") }
                XCTAssertTrue(what.hasPrefix("xl/worksheets/sheet1.xml"), what)
                XCTAssertTrue(what.contains("shared string"), what)
            }
        }
        parts[5] = ("xl/worksheets/sheet1.xml", Data(sheet("<row r=\"1\"><c r=\"A1\" t=\"s\"><v> 0 </v></c></row>").utf8))
        let ok = try? XLSXReader.read(ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) }), timeZone: ny)
        XCTAssertEqual(ok?.sheets[0].rows, [[.string("only")]], "in-range index with whitespace still resolves")
    }

    func testDateStyledCellWithoutAValueIsEmpty() throws {
        let styled = sheet("""
            <row r="1"><c r="A1" s="2"/><c r="B1" s="3"><v></v></c><c r="C1" s="2"><v>   </v></c><c r="D1" s="2"><f>NOW()</f></c><c r="E1" s="3"><v>46309</v></c></row>
            """)
        let wb = try XLSXReader.read(package(replacing: "xl/worksheets/sheet1.xml", with: styled), timeZone: ny)
        XCTAssertEqual(wb.sheets[0].rows[0], [.empty, .empty, .empty, .formula("NOW()"), .dateOnly(XLSXTestSupport.ny(2026, 10, 14))])
    }

    func testMissingWorksheetPartNamedInWorkbook() {
        let parts = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny).filter { $0.0 != "xl/worksheets/sheet1.xml" }
        XCTAssertThrowsError(try XLSXReader.read(ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) }), timeZone: ny)) {
            XCTAssertEqual($0 as? XLSXError, .missingPart("xl/worksheets/sheet1.xml"))
        }
        // A sheet whose r:id has no relationship is reported the same way.
        let workbook = "<workbook xmlns=\"\(XLSXWriter.mainNamespace)\" xmlns:r=\"\(XLSXWriter.relationshipsNamespace)\"><sheets><sheet name=\"Ghost\" sheetId=\"1\" r:id=\"rId77\"/></sheets></workbook>"
        XCTAssertThrowsError(try XLSXReader.read(package(replacing: "xl/workbook.xml", with: workbook), timeZone: ny)) {
            XCTAssertEqual($0 as? XLSXError, .missingPart("worksheet for sheet \"Ghost\""))
        }
    }

    func testDocxLikePackageIsNotAWorkbook() {
        let rels = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>
            """
        let docx = ZipWriter.archive([
            ZipEntry(path: "[Content_Types].xml", data: Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8)),
            ZipEntry(path: "_rels/.rels", data: Data(rels.utf8)),
            ZipEntry(path: "word/document.xml", data: Data(document.utf8)),
            ZipEntry(path: "word/_rels/document.xml.rels", data: Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>".utf8)),
        ])
        XCTAssertThrowsError(try XLSXReader.read(docx, timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }

        // A plain zip of unrelated files, with no relationships at all.
        let plain = ZipWriter.archive([ZipEntry(path: "readme.txt", data: Data("hi".utf8)), ZipEntry(path: "data/x.csv", data: Data("a,b".utf8))])
        XCTAssertThrowsError(try XLSXReader.read(plain, timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }

        // Root relationships naming a main document that is missing is a broken spreadsheet, not "not a workbook".
        let broken = ZipWriter.archive([ZipEntry(path: "_rels/.rels", data: Data(rels.utf8))])
        XCTAssertThrowsError(try XLSXReader.read(broken, timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .missingPart("word/document.xml")) }
    }

    func testPrefixedElementsEverywhereAreTolerated() throws {
        let ns = XLSXWriter.mainNamespace
        let workbook = "<x:workbook xmlns:x=\"\(ns)\" xmlns:r=\"\(XLSXWriter.relationshipsNamespace)\"><x:sheets><x:sheet name=\"P\" sheetId=\"1\" r:id=\"rId1\"/></x:sheets></x:workbook>"
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
            </Relationships>
            """
        let styles = "<x:styleSheet xmlns:x=\"\(ns)\"><x:numFmts count=\"1\"><x:numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/></x:numFmts><x:cellStyleXfs count=\"1\"><x:xf numFmtId=\"14\"/></x:cellStyleXfs><x:cellXfs count=\"2\"><x:xf numFmtId=\"0\"/><x:xf numFmtId=\"164\"/></x:cellXfs></x:styleSheet>"
        let sst = "<x:sst xmlns:x=\"\(ns)\"><x:si><x:t>shared</x:t></x:si><x:si><x:r><x:t>ri</x:t></x:r><x:r><x:t>ch</x:t></x:r></x:si></x:sst>"
        let sheet1 = "<x:worksheet xmlns:x=\"\(ns)\"><x:sheetViews><x:sheetView workbookViewId=\"0\"><x:pane ySplit=\"1\" topLeftCell=\"A2\" state=\"frozen\"/></x:sheetView></x:sheetViews><x:cols><x:col min=\"1\" max=\"1\" width=\"12\"/></x:cols><x:sheetData><x:row r=\"1\"><x:c r=\"A1\" t=\"s\"><x:v>0</x:v></x:c><x:c r=\"B1\" t=\"s\"><x:v>1</x:v></x:c><x:c r=\"C1\" s=\"1\"><x:v>46309</x:v></x:c><x:c r=\"D1\" t=\"inlineStr\"><x:is><x:t>inline</x:t></x:is></x:c><x:c r=\"E1\" t=\"b\"><x:v>1</x:v></x:c><x:c r=\"F1\"><x:f>1+1</x:f><x:v>2</x:v></x:c></x:row></x:sheetData></x:worksheet>"
        let data = ZipWriter.archive([
            ZipEntry(path: "_rels/.rels", data: Data(XLSXWriter.rootRelationships().utf8)),
            ZipEntry(path: "xl/workbook.xml", data: Data(workbook.utf8)),
            ZipEntry(path: "xl/_rels/workbook.xml.rels", data: Data(rels.utf8)),
            ZipEntry(path: "xl/styles.xml", data: Data(styles.utf8)),
            ZipEntry(path: "xl/sharedStrings.xml", data: Data(sst.utf8)),
            ZipEntry(path: "xl/worksheets/sheet1.xml", data: Data(sheet1.utf8)),
        ])
        let wb = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["P"])
        XCTAssertTrue(wb.sheets[0].freezeHeader)
        XCTAssertEqual(wb.sheets[0].columnWidths, [0: 12])
        XCTAssertEqual(wb.sheets[0].rows, [[.string("shared"), .string("rich"), .dateOnly(XLSXTestSupport.ny(2026, 10, 14)), .string("inline"), .bool(true), .integer(2)]])
    }

    func testAbsurdReferencesNeitherTrapNorHang() throws {
        let started = ProcessInfo.processInfo.systemUptime
        let body = """
            <row r="2000000000"><c r="A2000000000"><v>1</v></c></row>
            <row r="3"><c r="ZZZZZZZZZZZZZZZZZZZZZZZZZZZZ3"><v>2</v></c><c r="XFE3"><v>3</v></c><c r="B3"><v>4</v></c></row>
            <row r="0"><c r="A0"><v>5</v></c></row>
            <row r="-5"><c><v>6</v></c></row>
            """
        let wb = try XLSXReader.read(package(replacing: "xl/worksheets/sheet1.xml", with: sheet(body)), timeZone: ny)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        let rows = wb.sheets[0].rows
        XCTAssertEqual(rows.count, 5, "a row number past Excel's limit is appended, not padded to")
        XCTAssertEqual(rows[0], [.integer(1)])
        XCTAssertEqual(rows[1], [], "row 3 is still padded to its own position")
        // References past XFD fall back to sequential placement (columns A then B); the real B3 then overwrites B.
        XCTAssertEqual(rows[2], [.integer(2), .integer(4)])
        XCTAssertEqual(rows[3], [.integer(5)])
        XCTAssertEqual(rows[4], [.integer(6)])
    }

    func testColumnReferenceOverflowIsNil() {
        XCTAssertNil(ColumnReference.index(ofReference: String(repeating: "Z", count: 40) + "1"))
        XCTAssertNil(ColumnReference.index(ofReference: String(repeating: "A", count: 15) + "1"), "Σ 26^k for 15 letters overflows Int64")
        XCTAssertEqual(ColumnReference.index(ofReference: String(repeating: "A", count: 14) + "1"), 2_580_398_988_131_886_038, "14 letters still fit")
        XCTAssertEqual(ColumnReference.index(ofReference: "XFD1"), 16383)
        XCTAssertEqual(ColumnReference.index(ofReference: "XFE1"), 16384)
        XCTAssertNil(ColumnReference.row(ofReference: "A" + String(repeating: "9", count: 30)))
    }

    func testRowsWithoutNumbersAndCellsWithoutReferencesStaySequential() throws {
        let body = "<row><c><v>1</v></c><c t=\"b\"><v>1</v></c></row><row><c r=\"C2\"><v>3</v></c><c><v>4</v></c></row>"
        let wb = try XLSXReader.read(package(replacing: "xl/worksheets/sheet1.xml", with: sheet(body)), timeZone: ny)
        XCTAssertEqual(wb.sheets[0].rows, [[.integer(1), .bool(true)], [.empty, .empty, .integer(3), .integer(4)]])
    }

    func testConditionalFormatNumFmtsDoNotPoisonTheStyleTable() throws {
        let styles = """
            <styleSheet xmlns="\(XLSXWriter.mainNamespace)">
            <numFmts count="1"><numFmt numFmtId="164" formatCode="0.00"/></numFmts>
            <cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs>
            <dxfs count="1"><dxf><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="14" formatCode="0"/></dxf></dxfs>
            </styleSheet>
            """
        let body = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>46309.5</v></c></row>"
        var parts = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        parts[4] = ("xl/styles.xml", Data(styles.utf8))
        parts[5] = ("xl/worksheets/sheet1.xml", Data(sheet(body).utf8))
        let wb = try XLSXReader.read(ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) }), timeZone: ny)
        XCTAssertEqual(wb.sheets[0].rows[0], [.number(46309.5)], "custom 164 is 0.00 in the shared table; the dxf copy is ignored")
    }

    func testWhitespaceOnlyStringsSurviveTheRoundTrip() throws {
        let texts = [" ", "\n", "\t", "a\n", " a", "a ", "  ", "\n\n", "\r"]
        let sheet = Worksheet(name: "W", rows: [texts.map { Cell.string($0) }], freezeHeader: false)
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [sheet]), timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows[0], texts.map { Cell.string($0) })
    }

    func testPrefixedAttributeFallbackIsDeterministic() {
        XCTAssertEqual(PartParser.attribute("id", in: ["r:id": "rId1", "x:id": "rId2"]), "rId1")
        XCTAssertEqual(PartParser.attribute("id", in: ["x:id": "rId2", "r:id": "rId1"]), "rId1")
        XCTAssertEqual(PartParser.attribute("id", in: ["id": "plain", "r:id": "rId1"]), "plain")
        XCTAssertNil(PartParser.attribute("id", in: ["name": "x"]))
    }

    func testCorruptEntryInsideTheZipIsNotAWorkbook() {
        var data = try! XLSXWriter.write(XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        // Flip a byte just before the central directory, i.e. inside the last entry's payload (sheet2.xml):
        // its CRC fails, so the package cannot be opened at all.
        let eocd = data.count - 22
        let centralOffset = Int(data[eocd + 16]) | Int(data[eocd + 17]) << 8 | Int(data[eocd + 18]) << 16 | Int(data[eocd + 19]) << 24
        data[centralOffset - 10] ^= 0x55
        XCTAssertThrowsError(try XLSXReader.read(data, timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }
    }
}

// MARK: - Writer edge cases

final class XLSXWriterRobustnessTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testLeadingEqualsInFormulaIsDropped() throws {
        let sheet = Worksheet(name: "F", rows: [[.formula("=SUM(A2:A3)"), .formula("A2+1")]], freezeHeader: false)
        let xml = XLSXWriter.worksheetXML(sheet, timeZone: ny, isFirst: true)
        XCTAssertTrue(xml.contains("<c r=\"A1\"><f>SUM(A2:A3)</f></c>"), xml)
        XCTAssertTrue(xml.contains("<c r=\"B1\"><f>A2+1</f></c>"))
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [sheet]), timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows, [[.formula("SUM(A2:A3)"), .formula("A2+1")]])
    }

    func testWorkbookAsksForRecalculationOnLoad() {
        XCTAssertTrue(XLSXWriter.workbookXML(names: ["A"]).contains("</sheets><calcPr fullCalcOnLoad=\"1\"/></workbook>"))
    }

    func testReservedAndTruncatedSheetNames() {
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["History", "history"]), ["History_", "history_ (2)"])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames([String(repeating: "a", count: 30) + " b"]), [String(repeating: "a", count: 30)],
                       "truncation at 31 must not leave a trailing space")
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames([String(repeating: "a", count: 30) + "'b"]), [String(repeating: "a", count: 30)],
                       "truncation at 31 must not leave a trailing apostrophe")
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["'''", "   "]), ["Sheet1", "Sheet2"])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["a\nb", "tab\tok"]), ["ab", "tab\tok"])
    }

    func testControlCharactersAndSurrogatesNeverReachTheXML() throws {
        var s = ""
        for v in 0..<0x20 where v != 9 && v != 10 && v != 13 { s.unicodeScalars.append(UnicodeScalar(UInt8(v))) }
        let text = "a" + s + "b\u{FFFE}c\u{FFFF}d\u{1F600}e\u{E000}f"
        let sheet = Worksheet(name: "C", rows: [[.string(text)]], freezeHeader: false)
        let xml = XLSXWriter.worksheetXML(sheet, timeZone: ny, isFirst: true)
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">abcd\u{1F600}e\u{E000}f</t>"))
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [sheet]), timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows[0][0], .string("abcd\u{1F600}e\u{E000}f"))
    }

    func testExtremeNumbersRoundTrip() throws {
        let values: [Cell] = [.integer(Int.max), .integer(Int.min), .number(1e300), .number(-1e-300), .number(Double.leastNonzeroMagnitude), .number(0), .number(-0.0),
                              .number(123456789.123456789), .integer(1 << 53), .number(0.1 + 0.2)]
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [Worksheet(name: "N", rows: [values], freezeHeader: false)]), timeZone: ny), timeZone: ny)
        let row = back.sheets[0].rows[0]
        XCTAssertEqual(row[0], .integer(Int.max))
        XCTAssertEqual(row[1], .integer(Int.min))
        XCTAssertEqual(row[2], .number(1e300))
        XCTAssertEqual(row[3], .number(-1e-300))
        XCTAssertEqual(row[4], .number(Double.leastNonzeroMagnitude))
        XCTAssertEqual(row[5], .number(0))
        XCTAssertEqual(row[6].doubleValue, 0)
        XCTAssertEqual(row[7], .number(123456789.123456789))
        XCTAssertEqual(row[8], .integer(1 << 53))
        XCTAssertEqual(row[9], .number(0.1 + 0.2))
    }

    func testOutputIsDeterministic() throws {
        let wb = XLSXTestSupport.sampleWorkbook()
        XCTAssertEqual(try XLSXWriter.write(wb, timeZone: ny), try XLSXWriter.write(wb, timeZone: ny))
    }
}

// MARK: - Sample for external validation (openpyxl, strict XML)

/// Builds a large workbook that uses every `Cell` case, round-trips it through our own reader and, when a
/// `.verify-out` directory exists next to `Package.swift`, writes `sample.xlsx` plus `sample.expected.json`
/// so a host-side script can open the file with openpyxl and a strict XML parser and compare every cell.
final class XLSXExternalSampleTests: XCTestCase {
    let ny = XLSXTestSupport.newYork
    typealias S = XLSXTestSupport

    static let columns = 32
    static let dataRows = 200

    static func sampleCell(row r: Int, column c: Int) -> Cell {
        switch (r * 7 + c) % 9 {
        case 0:
            if r % 47 == 0 { return .string("") }
            if r % 41 == 0 { return .string("  padded  ") }
            if r % 31 == 0 { return .string("日本 ✓ café — naïve") }
            if r % 23 == 0 { return .string("line1\nline2\ttabbed\r\nthird") }
            if r % 17 == 0 { return .string("Late & <early> \"quoted\" 'single' = not formula") }
            if r % 13 == 0 { return .string("=1+1") }
            return .string("R\(r)C\(c) text")
        case 1:
            if r == 1 { return .integer(1 << 40) }
            return .integer(r * 1000 - c * 37)
        case 2:
            if r % 29 == 0 { return .number(1e15) }
            if r % 19 == 0 { return .number(-123456.789) }
            if r % 13 == 0 { return .number(1e-7) }
            return .number(Double(r) / 7.0 + Double(c))
        case 3:
            switch r {
            case 2: return .date(S.ny(2026, 3, 8, 1, 59, 59))
            case 3: return .date(S.ny(2026, 3, 8, 3, 0, 0))
            case 4: return .date(S.ny(2026, 11, 1, 0, 30, 0))
            case 5: return .date(S.ny(2026, 11, 1, 1, 30, 0))
            case 6: return .date(S.ny(2026, 11, 1, 23, 59, 59))
            case 7: return .date(S.ny(2026, 10, 14, 0, 0, 0))
            case 8: return .date(S.ny(1999, 12, 31, 23, 59, 59))
            default: return .date(S.ny(2026, 1 + r % 12, 1 + (r + c) % 28, c % 24, r % 60, (r * c) % 60))
            }
        case 4:
            return .dateOnly(S.ny(2025 + r % 3, 1 + (r + c) % 12, 1 + (r * 3 + c) % 28))
        case 5:
            return .bool((r + c) % 2 == 0)
        case 6:
            if r % 11 == 0 { return .formula("CONCATENATE(\"a&b\",\"<c>\")") }
            if r % 7 == 0 { return .formula("IF(\(r)>\(c),\"yes\",\"no\")") }
            return .formula("\(r)+\(c)")
        case 7:
            return .empty
        default:
            return .number(Double(r) * 0.25)
        }
    }

    static func sampleWorkbook() -> Workbook {
        var header: [Cell] = (0..<columns).map { .string("Col \($0 + 1)") }
        header[5] = .string("Notes & <Stuff>")
        header[6] = .string("  spaced  ")
        var rows: [[Cell]] = [header]
        for r in 1...dataRows { rows.append((0..<columns).map { sampleCell(row: r, column: $0) }) }
        rows.append([.string("last row short")])
        let days = Worksheet(name: "Days", rows: rows, columnWidths: [0: 14, 5: 40, 31: 8.5], freezeHeader: true)
        let lookup = Worksheet(name: "Lookup", rows: [
            [.string("ID"), .string("Name"), .string("Active")],
            [.integer(1), .string("Plant A"), .bool(true)],
            [.integer(2), .string("Plant B"), .bool(false)],
            [.empty, .empty, .empty],
            [.number(2.5), .formula("SUM(A2:A3)"), .dateOnly(S.ny(2026, 11, 26))],
        ], freezeHeader: false)
        let odd = Worksheet(name: "Time Off: [2026]/Q4?*\\ with a very long name", rows: [[.string("h1"), .string("h2")], [.date(S.ny(2026, 11, 1, 15, 0, 0)), .number(.nan)]], freezeHeader: true)
        let empty = Worksheet(name: "Empty", rows: [], freezeHeader: true)
        let blankRows = Worksheet(name: "Blank Rows", rows: [[], [], [.string("c3")]], freezeHeader: false)
        return Workbook(sheets: [days, lookup, odd, empty, blankRows])
    }

    /// `<package>/.verify-out`, or nil when the host did not create it (the normal case in CI).
    static var verifyDirectory: URL? {
        let here = URL(fileURLWithPath: #filePath)   // Tests/OTXLSXTests/XLSXRobustnessTests.swift
        let package = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = package.appendingPathComponent(".verify-out", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    private func json(_ cell: Cell) -> [String: Any] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ny
        f.calendar = Calendar(identifier: .gregorian)
        switch cell {
        case .empty: return ["t": "e"]
        case .string(let s): return ["t": "s", "v": s]
        case .integer(let i): return ["t": "i", "v": i]
        case .number(let d): return d.isFinite ? ["t": "n", "v": d] : ["t": "s", "v": String(d)]
        case .bool(let b): return ["t": "b", "v": b]
        case .formula(let x): return ["t": "f", "v": x]
        case .date(let d):
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return ["t": "d", "v": f.string(from: d)]
        case .dateOnly(let d):
            f.dateFormat = "yyyy-MM-dd"
            return ["t": "D", "v": f.string(from: d)]
        }
    }

    func testSampleRoundTripsAndIsWrittenForExternalValidation() throws {
        let wb = XLSXExternalSampleTests.sampleWorkbook()
        let data = try XLSXWriter.write(wb, timeZone: ny)
        let names = XLSXWriter.sanitisedSheetNames(wb.sheets.map { $0.name })
        XCTAssertEqual(names, ["Days", "Lookup", "Time Off 2026Q4 with a very lon", "Empty", "Blank Rows"])
        XCTAssertEqual(names[2].count, 31)

        let back = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(back.sheets.map { $0.name }, names)
        for (g, w) in zip(back.sheets, wb.sheets) {
            XCTAssertEqual(g.rows.count, w.rows.count, w.name)
            for (r, (gr, wr)) in zip(g.rows, w.rows).enumerated() {
                // Trailing empties are dropped by the writer; everything before them must match exactly.
                var want = wr
                while want.last == .empty { want.removeLast() }
                var expected: [Cell] = want.map { cell in
                    // A serial with no time part always reads back as date-only, so midnight instants do too.
                    if case .date(let d) = cell, d == XLSXTestSupport.calendar.startOfDay(for: d) { return .dateOnly(d) }
                    return cell
                }
                if w.name == "Time Off: [2026]/Q4?*\\ with a very long name", r == 1 { expected[1] = .string("nan") }
                XCTAssertEqual(gr, expected, "\(w.name) row \(r + 1)")
            }
            XCTAssertEqual(g.freezeHeader, w.freezeHeader, w.name)
        }

        guard let dir = XLSXExternalSampleTests.verifyDirectory else { return }
        try data.write(to: dir.appendingPathComponent("sample.xlsx"))
        let sheets: [[String: Any]] = zip(names, wb.sheets).map { name, sheet in
            var widths: [String: Double] = [:]
            let columnCount = sheet.rows.map { $0.count }.max() ?? 0
            for c in 0..<columnCount { widths[String(c)] = sheet.columnWidths[c] ?? XLSXWriter.autoWidth(sheet: sheet, column: c) }
            return ["name": name, "freeze": sheet.freezeHeader, "widths": widths,
                    "rows": sheet.rows.map { row in row.map { json($0) } }]
        }
        let doc = try JSONSerialization.data(withJSONObject: ["sheets": sheets], options: [.sortedKeys])
        try doc.write(to: dir.appendingPathComponent("sample.expected.json"))
    }
}
