import XCTest
import OTZip
@testable import OTXLSX

// MARK: - Helpers

enum XLSXTestSupport {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let utc = TimeZone(identifier: "UTC")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = newYork
        return c
    }

    /// Wall-clock instant in America/New_York.
    static func ny(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    static func parts(_ data: Data) throws -> [String: String] {
        var out: [String: String] = [:]
        for e in try ZipReader.entries(from: data) { out[e.path] = String(decoding: e.data, as: UTF8.self) }
        return out
    }

    /// A compact workbook exercising every cell case; shared by the round-trip and re-zip tests.
    static func sampleWorkbook() -> Workbook {
        let days = Worksheet(
            name: "Days",
            rows: [
                [.string("Date"), .string("First In"), .string("Hours"), .string("Count"), .string("Flag"), .string("Note"), .string("Total")],
                [.dateOnly(ny(2026, 10, 14)), .date(ny(2026, 10, 14, 7, 2, 30)), .number(8.75), .integer(3), .bool(true),
                 .string("Late & <early> \"quoted\" 'single'"), .formula("C2*2")],
                [.dateOnly(ny(2026, 11, 1)), .date(ny(2026, 11, 1, 15, 0, 0)), .number(-1.25), .empty, .bool(false),
                 .string("line1\nline2\ttabbed"), .formula("SUM(C2:C3)")],
                [.dateOnly(ny(2026, 3, 8)), .date(ny(2026, 3, 8, 10, 30, 0)), .number(1e-05), .integer(0), .empty,
                 .string(""), .integer(-7)],
            ],
            columnWidths: [0: 14, 5: 30],
            freezeHeader: true)
        let lookup = Worksheet(
            name: "Lookup",
            rows: [[.string("ID"), .string("Name")], [.integer(1), .string("Plant A")], [.integer(2), .string("Plant B")]],
            freezeHeader: false)
        return Workbook(sheets: [days, lookup])
    }

    static func assertSheetsEqual(_ got: Worksheet, _ want: Worksheet, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.name, want.name, file: file, line: line)
        XCTAssertEqual(got.rows.count, want.rows.count, "row count in \(want.name)", file: file, line: line)
        for (r, (g, w)) in zip(got.rows, want.rows).enumerated() {
            XCTAssertEqual(g.count, w.count, "\(want.name) row \(r + 1) width", file: file, line: line)
            for (c, (gc, wc)) in zip(g, w).enumerated() {
                XCTAssertEqual(gc, wc, "\(want.name) \(ColumnReference.letters(forIndex: c))\(r + 1)", file: file, line: line)
            }
        }
        XCTAssertEqual(got.freezeHeader, want.freezeHeader, "\(want.name) freezeHeader", file: file, line: line)
    }
}

// MARK: - Support types

final class ColumnReferenceTests: XCTestCase {
    func testLetters() {
        XCTAssertEqual(ColumnReference.letters(forIndex: 0), "A")
        XCTAssertEqual(ColumnReference.letters(forIndex: 25), "Z")
        XCTAssertEqual(ColumnReference.letters(forIndex: 26), "AA")
        XCTAssertEqual(ColumnReference.letters(forIndex: 51), "AZ")
        XCTAssertEqual(ColumnReference.letters(forIndex: 52), "BA")
        XCTAssertEqual(ColumnReference.letters(forIndex: 199), "GR")
        XCTAssertEqual(ColumnReference.letters(forIndex: 701), "ZZ")
        XCTAssertEqual(ColumnReference.letters(forIndex: 702), "AAA")
        XCTAssertEqual(ColumnReference.letters(forIndex: 16383), "XFD")
    }

    func testParsing() {
        XCTAssertEqual(ColumnReference.index(ofReference: "A1"), 0)
        XCTAssertEqual(ColumnReference.index(ofReference: "Z99"), 25)
        XCTAssertEqual(ColumnReference.index(ofReference: "AA2"), 26)
        XCTAssertEqual(ColumnReference.index(ofReference: "GR2"), 199)
        XCTAssertEqual(ColumnReference.index(ofReference: "aaa7"), 702)
        XCTAssertNil(ColumnReference.index(ofReference: "12"))
        XCTAssertNil(ColumnReference.index(ofReference: ""))
        XCTAssertEqual(ColumnReference.row(ofReference: "GR2"), 2)
        XCTAssertEqual(ColumnReference.row(ofReference: "A1048576"), 1_048_576)
        XCTAssertNil(ColumnReference.row(ofReference: "A"))
    }

    func testRoundTripOfManyIndexes() {
        for i in 0..<20_000 {
            XCTAssertEqual(ColumnReference.index(ofReference: ColumnReference.letters(forIndex: i) + "1"), i)
        }
    }
}

final class ExcelDateTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testKnownSerials() {
        XCTAssertEqual(ExcelDate.serial(from: XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30), timeZone: ny), 46309.29340277778, accuracy: 1e-9)
        XCTAssertEqual(ExcelDate.serial(from: XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0), timeZone: ny), 46327.625)
        XCTAssertEqual(ExcelDate.serial(from: XLSXTestSupport.ny(2026, 3, 8, 10, 30, 0), timeZone: ny), 46089.4375)
        XCTAssertEqual(ExcelDate.serial(from: XLSXTestSupport.ny(2026, 10, 14, 23, 59, 59), timeZone: ny, dateOnly: true), 46309)
        XCTAssertEqual(ExcelDate.serial(from: XLSXTestSupport.ny(1970, 1, 1), timeZone: ny), 25569)
    }

    func testSerialIsWallClockNotUTC() {
        // 15:00 New York on 2026-11-01 is 20:00 UTC (EST); wall clock must win.
        let date = XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0)
        XCTAssertEqual(ExcelDate.serial(from: date, timeZone: ny), 46327.625)
        XCTAssertEqual(ExcelDate.serial(from: date, timeZone: XLSXTestSupport.utc), 46327 + 20.0 / 24.0)
    }

    func testDSTDaysDoNotShiftTheTimePart() {
        // Spring forward: 2026-03-08 has 23 hours in New York; fall back: 2026-11-01 has 25.
        for (date, expected) in [(XLSXTestSupport.ny(2026, 3, 8, 10, 30), 0.4375),
                                 (XLSXTestSupport.ny(2026, 3, 8, 23, 0), 23.0 / 24.0),
                                 (XLSXTestSupport.ny(2026, 11, 1, 0, 30), 0.5 / 24.0),
                                 (XLSXTestSupport.ny(2026, 11, 1, 15, 0), 0.625),
                                 (XLSXTestSupport.ny(2026, 11, 1, 23, 59, 59), 86399.0 / 86400.0)] {
            let serial = ExcelDate.serial(from: date, timeZone: ny)
            XCTAssertEqual(serial - serial.rounded(.down), expected, accuracy: 1e-9, "\(date)")
            XCTAssertEqual(ExcelDate.date(fromSerial: serial, timeZone: ny), date)
        }
    }

    func testRoundTripOfSecondsAcrossADay() {
        var date = XLSXTestSupport.ny(2026, 3, 8, 0, 0, 0)
        let end = XLSXTestSupport.ny(2026, 3, 9, 0, 0, 0)
        while date < end {
            let serial = ExcelDate.serial(from: date, timeZone: ny)
            XCTAssertEqual(ExcelDate.date(fromSerial: serial, timeZone: ny), date, "\(date)")
            date = date.addingTimeInterval(733)
        }
    }

    func testExcel1900LeapYearBug() {
        let utc = XLSXTestSupport.utc
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { c.date(from: DateComponents(year: y, month: m, day: d))! }
        XCTAssertEqual(ExcelDate.serial(from: day(1900, 1, 1), timeZone: utc), 1)
        XCTAssertEqual(ExcelDate.serial(from: day(1900, 2, 28), timeZone: utc), 59)
        XCTAssertEqual(ExcelDate.serial(from: day(1900, 3, 1), timeZone: utc), 61)
        XCTAssertEqual(ExcelDate.date(fromSerial: 1, timeZone: utc), day(1900, 1, 1))
        XCTAssertEqual(ExcelDate.date(fromSerial: 59, timeZone: utc), day(1900, 2, 28))
        XCTAssertEqual(ExcelDate.date(fromSerial: 61, timeZone: utc), day(1900, 3, 1))
    }

    func testWholeDayDetection() {
        XCTAssertTrue(ExcelDate.isWholeDay(46309))
        XCTAssertTrue(ExcelDate.isWholeDay(46309.0000000001))
        XCTAssertFalse(ExcelDate.isWholeDay(46309.5))
        XCTAssertFalse(ExcelDate.isWholeDay(46309.00001157))   // one second
        XCTAssertFalse(ExcelDate.isWholeDay(.nan))
        XCTAssertNil(ExcelDate.date(fromSerial: .infinity, timeZone: ny))
        XCTAssertNil(ExcelDate.date(fromSerial: 1e12, timeZone: ny))
    }

    func testCivilDayArithmetic() {
        XCTAssertEqual(ExcelDate.daysFromCivil(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(ExcelDate.daysFromCivil(year: 2000, month: 3, day: 1), 11017)
        for days in stride(from: -800_000, through: 800_000, by: 997) {
            let c = ExcelDate.civilFromDays(days)
            XCTAssertEqual(ExcelDate.daysFromCivil(year: c.year, month: c.month, day: c.day), days)
        }
    }
}

final class XMLTextTests: XCTestCase {
    func testEscaping() {
        XCTAssertEqual(XMLText.escape("a & b < c > d \" e ' f"), "a &amp; b &lt; c &gt; d &quot; e &apos; f")
        XCTAssertEqual(XMLText.escape("line\r\nnext\ttab"), "line&#13;\nnext\ttab")
        XCTAssertEqual(XMLText.escape("bell\u{07}gone"), "bellgone")
        XCTAssertEqual(XMLText.escape("日本 ✓ café"), "日本 ✓ café")
    }
}

// MARK: - Writer

final class XLSXWriterTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testPackageHasEveryPartInOrder() throws {
        let data = try XLSXWriter.write(XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        let paths = try ZipReader.entries(from: data).map { $0.path }
        XCTAssertEqual(paths, ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                               "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"])
        let parts = try XLSXTestSupport.parts(data)
        XCTAssertTrue(parts["[Content_Types].xml"]!.contains("PartName=\"/xl/worksheets/sheet2.xml\""))
        XCTAssertTrue(parts["_rels/.rels"]!.contains("Target=\"xl/workbook.xml\""))
        XCTAssertTrue(parts["xl/workbook.xml"]!.contains("<sheet name=\"Days\" sheetId=\"1\" r:id=\"rId1\"/>"))
        XCTAssertTrue(parts["xl/workbook.xml"]!.contains("<sheet name=\"Lookup\" sheetId=\"2\" r:id=\"rId2\"/>"))
        XCTAssertTrue(parts["xl/_rels/workbook.xml.rels"]!.contains("Target=\"worksheets/sheet2.xml\""))
        XCTAssertTrue(parts["xl/_rels/workbook.xml.rels"]!.contains("Target=\"styles.xml\""))
    }

    func testStylesTable() throws {
        let styles = XLSXWriter.stylesXML()
        XCTAssertTrue(styles.contains("<numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd hh:mm\"/>"))
        XCTAssertTrue(styles.contains("<numFmt numFmtId=\"165\" formatCode=\"yyyy-mm-dd\"/>"))
        XCTAssertTrue(styles.contains("<cellXfs count=\"5\">"))
        let xfs = styles.components(separatedBy: "<xf ").dropFirst(2)   // skip the cellStyleXfs entry
        XCTAssertEqual(xfs.count, 5)
        XCTAssertTrue(xfs[xfs.startIndex].hasPrefix("numFmtId=\"0\" fontId=\"0\""))
        XCTAssertTrue(xfs[xfs.startIndex + 1].hasPrefix("numFmtId=\"0\" fontId=\"1\""), "bold header")
        XCTAssertTrue(xfs[xfs.startIndex + 2].hasPrefix("numFmtId=\"164\""), "date-time")
        XCTAssertTrue(xfs[xfs.startIndex + 3].hasPrefix("numFmtId=\"165\""), "date-only")
        XCTAssertTrue(xfs[xfs.startIndex + 4].hasPrefix("numFmtId=\"2\""), "0.00")
        XCTAssertTrue(styles.contains("<font><b/>"))
    }

    func testWorksheetXMLDetails() throws {
        let sheet = XLSXTestSupport.sampleWorkbook().sheets[0]
        let xml = XLSXWriter.worksheetXML(sheet, timeZone: ny, isFirst: true)
        XCTAssertTrue(xml.contains("<dimension ref=\"A1:G4\"/>"))
        XCTAssertTrue(xml.contains("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        XCTAssertTrue(xml.contains("<c r=\"A1\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">Date</t></is></c>"), "bold header")
        XCTAssertTrue(xml.contains("<c r=\"A2\" s=\"3\"><v>46309</v></c>"), "date-only serial is a whole number")
        XCTAssertTrue(xml.contains("<c r=\"B2\" s=\"2\"><v>46309.29340277778</v></c>"), "date-time serial")
        XCTAssertTrue(xml.contains("<c r=\"C2\" s=\"4\"><v>8.75</v></c>"), "number style")
        XCTAssertTrue(xml.contains("<c r=\"D2\"><v>3</v></c>"), "integer")
        XCTAssertTrue(xml.contains("<c r=\"E2\" t=\"b\"><v>1</v></c>"), "bool")
        XCTAssertTrue(xml.contains("<c r=\"G2\"><f>C2*2</f></c>"), "formula")
        XCTAssertTrue(xml.contains("Late &amp; &lt;early&gt; &quot;quoted&quot; &apos;single&apos;"), "escaping")
        XCTAssertFalse(xml.contains("r=\"D3\""), "empty cell is not written")
        XCTAssertTrue(xml.contains("<c r=\"E3\" t=\"b\"><v>0</v></c>"), "cell after an empty one keeps its column")
        XCTAssertTrue(xml.contains("<col min=\"1\" max=\"1\" width=\"14.0\" customWidth=\"1\"/>"), "custom width")
        XCTAssertTrue(xml.contains("<col min=\"6\" max=\"6\" width=\"30.0\" customWidth=\"1\"/>"), "custom width")
        XCTAssertTrue(xml.contains("<col min=\"2\" max=\"2\" width=\"18.0\" customWidth=\"1\"/>"), "auto width = 16 + 2 for date-time")
        XCTAssertTrue(xml.contains("tabSelected=\"1\""))
    }

    func testNoFreezeMeansNoPaneAndNoBold() {
        let sheet = Worksheet(name: "S", rows: [[.string("h")], [.string("v")]], freezeHeader: false)
        let xml = XLSXWriter.worksheetXML(sheet, timeZone: ny, isFirst: false)
        XCTAssertFalse(xml.contains("<pane"))
        XCTAssertFalse(xml.contains("s=\"1\""))
        XCTAssertFalse(xml.contains("tabSelected"))
    }

    func testAutoWidthIsClamped() {
        let sheet = Worksheet(name: "W", rows: [
            [.string("ab"), .string(String(repeating: "x", count: 20)), .string(String(repeating: "y", count: 200)), .string("multi\n" + String(repeating: "z", count: 12))],
        ], freezeHeader: false)
        XCTAssertEqual(XLSXWriter.autoWidth(sheet: sheet, column: 0), 8, "minimum")
        XCTAssertEqual(XLSXWriter.autoWidth(sheet: sheet, column: 1), 22)
        XCTAssertEqual(XLSXWriter.autoWidth(sheet: sheet, column: 2), 60, "maximum")
        XCTAssertEqual(XLSXWriter.autoWidth(sheet: sheet, column: 3), 14, "longest line counts")
        XCTAssertEqual(XLSXWriter.autoWidth(sheet: sheet, column: 9), 8, "column with no cells")
    }

    func testSheetNameSanitising() {
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["Time Off: [2026]/Q4?*\\"]), ["Time Off 2026Q4"])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames([String(repeating: "a", count: 40)]), [String(repeating: "a", count: 31)])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["Data", "data", "DATA"]), ["Data", "data (2)", "DATA (3)"])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["", "[]", "ok"]), ["Sheet1", "Sheet2", "ok"])
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames(["'quoted'", " padded "]), ["quoted", "padded"])
        let long = String(repeating: "b", count: 31)
        XCTAssertEqual(XLSXWriter.sanitisedSheetNames([long, long]), [long, String(repeating: "b", count: 27) + " (2)"])
    }

    func testZeroSheetsWritesOneEmptySheet() throws {
        let data = try XLSXWriter.write(Workbook(), timeZone: ny)
        let back = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(back.sheets.map { $0.name }, ["Sheet1"])
        XCTAssertEqual(back.sheets[0].rows, [])
        let parts = try XLSXTestSupport.parts(data)
        XCTAssertTrue(parts["xl/worksheets/sheet1.xml"]!.contains("<dimension ref=\"A1\"/>"))
        XCTAssertTrue(parts["xl/worksheets/sheet1.xml"]!.contains("<sheetData></sheetData>"))
    }

    func testNonFiniteNumbersBecomeText() throws {
        let sheet = Worksheet(name: "S", rows: [[.number(.nan), .number(.infinity)]], freezeHeader: false)
        let xml = XLSXWriter.worksheetXML(sheet, timeZone: ny, isFirst: true)
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">nan</t>"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">inf</t>"))
    }

    func testArchiveEntriesAreStored() throws {
        let data = try XLSXWriter.write(XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        XCTAssertEqual(Int(data[8]) | Int(data[9]) << 8, 0, "first local header method is stored")
    }
}

// MARK: - Round trips

final class XLSXRoundTripTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testEveryCellCaseRoundTrips() throws {
        let wb = XLSXTestSupport.sampleWorkbook()
        let data = try XLSXWriter.write(wb, timeZone: ny)
        let back = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(back.sheets.count, 2)
        for (g, w) in zip(back.sheets, wb.sheets) { XLSXTestSupport.assertSheetsEqual(g, w) }
        XCTAssertEqual(back.sheets[0].columnWidths[0], 14)
        XCTAssertEqual(back.sheets[0].columnWidths[5], 30)
        XCTAssertEqual(back.sheets[0].columnWidths[1], 18, "auto width was written and read back")
        XCTAssertEqual(back.sheets[1].columnWidths[1], 9, "\"Plant A\" is 7 characters + 2")
        XCTAssertEqual(back.sheet(named: "lookup")?.records.first?["Name"], .string("Plant A"))
    }

    func testDatesOnDSTDaysRoundTripAtSecondPrecision() throws {
        let dates: [Date] = [
            XLSXTestSupport.ny(2026, 3, 8, 0, 0, 0), XLSXTestSupport.ny(2026, 3, 8, 1, 59, 59), XLSXTestSupport.ny(2026, 3, 8, 3, 0, 0),
            XLSXTestSupport.ny(2026, 3, 8, 10, 30, 0), XLSXTestSupport.ny(2026, 3, 8, 23, 59, 59),
            XLSXTestSupport.ny(2026, 11, 1, 0, 0, 0), XLSXTestSupport.ny(2026, 11, 1, 0, 59, 59), XLSXTestSupport.ny(2026, 11, 1, 3, 0, 1),
            XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0), XLSXTestSupport.ny(2026, 11, 1, 23, 59, 59),
            XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30), XLSXTestSupport.ny(1999, 12, 31, 23, 59, 59), XLSXTestSupport.ny(2100, 6, 15, 12, 0, 0),
        ]
        let rows: [[Cell]] = dates.map { [.date($0), .dateOnly($0)] }
        let wb = Workbook(sheets: [Worksheet(name: "D", rows: rows, freezeHeader: false)])
        let back = try XLSXReader.read(try XLSXWriter.write(wb, timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows.count, dates.count)
        for (row, date) in zip(back.sheets[0].rows, dates) {
            let dayStart = XLSXTestSupport.calendar.startOfDay(for: date)
            // A serial with no time part always reads back as date-only, so midnight instants do too.
            XCTAssertEqual(row[0], date == dayStart ? .dateOnly(date) : .date(date), "\(date)")
            XCTAssertEqual(row[1], .dateOnly(dayStart), "\(date) as date-only")
        }
    }

    func testDateReadInAnotherZoneKeepsWallClock() throws {
        // Written as 15:00 New York; a reader in Tokyo sees 15:00 Tokyo. That is how Excel dates behave.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        let wb = Workbook(sheets: [Worksheet(name: "D", rows: [[.date(XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0))]], freezeHeader: false)])
        let back = try XLSXReader.read(try XLSXWriter.write(wb, timeZone: ny), timeZone: tokyo)
        XCTAssertEqual(back.sheets[0].rows[0][0], .date(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15))!))
    }

    func testThreeSheetsAndTwoHundredColumns() throws {
        let header: [Cell] = (1...200).map { .string("Col \($0)") }
        let numbers: [Cell] = (1...200).map { .integer($0 * 3) }
        let doubles: [Cell] = (1...200).map { .number(Double($0) + 0.5) }
        let wide = Worksheet(name: "Wide", rows: [header, numbers, doubles], freezeHeader: true)
        let escaped = Worksheet(name: "Esc & <Chars>", rows: [
            [.string("h")],
            [.string("& < > \" ' \n \r\n \t end")],
            [.string("<is><t>not xml</t></is>")],
            [.string("日本語 ✓ café")],
            [.formula("IF(A1<B1,\"x&y\",'S'!A1)")],
        ])
        let third = Worksheet(name: "Third", rows: [[.string("only header")]], freezeHeader: true)
        let wb = Workbook(sheets: [wide, escaped, third])
        let data = try XLSXWriter.write(wb, timeZone: ny)

        let xml = try XLSXTestSupport.parts(data)["xl/worksheets/sheet1.xml"]!
        XCTAssertTrue(xml.contains("<c r=\"AA1\" s=\"1\""))
        XCTAssertTrue(xml.contains("<c r=\"GR2\"><v>600</v></c>"))
        XCTAssertTrue(xml.contains("<dimension ref=\"A1:GR3\"/>"))

        let back = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(back.sheets.map { $0.name }, ["Wide", "Esc & <Chars>", "Third"])
        XLSXTestSupport.assertSheetsEqual(back.sheets[0], wide)
        XLSXTestSupport.assertSheetsEqual(back.sheets[1], escaped)
        XLSXTestSupport.assertSheetsEqual(back.sheets[2], third)
        XCTAssertEqual(back.sheets[0].rows[2][199], .number(200.5))
        XCTAssertEqual(back.sheets[0].columnWidths.count, 200)
    }

    func testTrailingEmptyCellsAreDroppedButInnerOnesKept() throws {
        let sheet = Worksheet(name: "S", rows: [[.string("a"), .empty, .empty, .string("d"), .empty, .empty]], freezeHeader: false)
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [sheet]), timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows, [[.string("a"), .empty, .empty, .string("d")]])
    }

    func testEmptyRowsKeepTheirPosition() throws {
        let sheet = Worksheet(name: "S", rows: [[.string("h")], [], [], [.integer(4)]], freezeHeader: true)
        let back = try XLSXReader.read(try XLSXWriter.write(Workbook(sheets: [sheet]), timeZone: ny), timeZone: ny)
        XCTAssertEqual(back.sheets[0].rows, [[.string("h")], [], [], [.integer(4)]])
    }
}

// MARK: - Reader

final class XLSXReaderTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testNotAWorkbook() {
        XCTAssertThrowsError(try XLSXReader.read(Data(), timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }
        XCTAssertThrowsError(try XLSXReader.read(Data("<html></html>".utf8), timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }
        var corrupt = try! XLSXWriter.write(XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        corrupt[30 + "[Content_Types].xml".utf8.count + 5] ^= 0xFF   // inside the first entry's payload → CRC mismatch
        XCTAssertThrowsError(try XLSXReader.read(corrupt, timeZone: ny)) { XCTAssertEqual($0 as? XLSXError, .notAWorkbook) }
    }

    func testMissingParts() throws {
        let full = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        func archive(without path: String) -> Data {
            ZipWriter.archive(full.filter { $0.0 != path }.map { ZipEntry(path: $0.0, data: $0.1) })
        }
        XCTAssertThrowsError(try XLSXReader.read(archive(without: "xl/workbook.xml"), timeZone: ny)) {
            XCTAssertEqual($0 as? XLSXError, .missingPart("xl/workbook.xml"))
        }
        XCTAssertThrowsError(try XLSXReader.read(archive(without: "xl/_rels/workbook.xml.rels"), timeZone: ny)) {
            XCTAssertEqual($0 as? XLSXError, .missingPart("xl/_rels/workbook.xml.rels"))
        }
        XCTAssertThrowsError(try XLSXReader.read(archive(without: "xl/worksheets/sheet2.xml"), timeZone: ny)) {
            XCTAssertEqual($0 as? XLSXError, .missingPart("xl/worksheets/sheet2.xml"))
        }
        // Optional parts: styles may be missing (dates then read as numbers); root rels may be missing.
        let noStyles = try XLSXReader.read(archive(without: "xl/styles.xml"), timeZone: ny)
        XCTAssertEqual(noStyles.sheets[0].rows[1][1], .number(46309.29340277778))
        XCTAssertEqual(noStyles.sheets[0].rows[1][0], .integer(46309))
        let noRootRels = try XLSXReader.read(archive(without: "_rels/.rels"), timeZone: ny)
        XCTAssertEqual(noRootRels.sheets.count, 2)
    }

    func testUnterminatedXMLIsReported() {
        var parts = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        parts[2] = ("xl/workbook.xml", Data("<workbook><sheets><sheet name='x'".utf8))
        let data = ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) })
        XCTAssertThrowsError(try XLSXReader.read(data, timeZone: ny)) { error in
            guard case .malformed(let what)? = error as? XLSXError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.hasPrefix("xl/workbook.xml"))
        }
    }

    func testMalformedXMLIsReported() {
        var parts = XLSXWriter.parts(for: XLSXTestSupport.sampleWorkbook(), timeZone: ny)
        parts[2] = ("xl/workbook.xml", Data("<workbook><sheets><sheet name='x'/></workbook>".utf8))   // mismatched end tag
        let data = ZipWriter.archive(parts.map { ZipEntry(path: $0.0, data: $0.1) })
        XCTAssertThrowsError(try XLSXReader.read(data, timeZone: ny)) { error in
            guard case .malformed(let what)? = error as? XLSXError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.hasPrefix("xl/workbook.xml"))
        }
    }

    func testHandWrittenPackageCoversEveryCellType() throws {
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="/xl/book.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:workbook xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <x:sheets><x:sheet name="First" sheetId="1" r:id="rId7"/><x:sheet name="Second" sheetId="2" r:id="rId9"/></x:sheets>
        </x:workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/../data/two.xml"/>
        <Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/data/one.xml"/>
        <Relationship Id="rId8" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="strings.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        let sharedStrings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
        <si><t>plain</t></si>
        <si><r><rPr><b/></rPr><t xml:space="preserve">rich </t></r><r><t>text</t></r><rPh sb="0" eb="1"><t>PHONETIC</t></rPh><phoneticPr fontId="1"/></si>
        <si><t>has_x000D_cr and _x0009_tab</t></si>
        </sst>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="3"><numFmt numFmtId="164" formatCode="0.0"/><numFmt numFmtId="165" formatCode="d-mmm-yy"/><numFmt numFmtId="166" formatCode="&quot;Year&quot; 0"/></numFmts>
        <cellStyleXfs count="2"><xf numFmtId="14"/><xf numFmtId="14"/></cellStyleXfs>
        <cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="166"/></cellXfs>
        </styleSheet>
        """
        let one = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="2" topLeftCell="A3" state="frozen"/></sheetView></sheetViews>
        <cols><col min="2" max="4" width="11.5" customWidth="1"/></cols>
        <sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>2</v></c></row>
        <row r="3">
          <c r="B3" t="str"><f>A1&amp;"x"</f><v>cached</v></c>
          <c r="C3"><f>1+1</f></c>
          <c r="D3"><v></v></c>
          <c r="E3" t="e"><v>#DIV/0!</v></c>
          <c r="F3" t="d"><v>2026-10-14T07:02:30</v></c>
          <c r="G3" t="d"><v>2026-10-14</v></c>
          <c r="H3" s="1"><v>46309.29340277778</v></c>
          <c r="I3" s="1"><v>46309</v></c>
          <c r="J3" s="2"><v>46309</v></c>
          <c r="K3" t="b"><v>true</v></c>
          <c r="L3" t="s"><v>99</v></c>
          <c r="M3" t="inlineStr"><is><r><t>in</t></r><r><t>line</t></r></is></c>
          <c r="N3"><v>  12  </v></c>
          <c r="O3" s="3"><v>46327.625</v></c>
          <c r="P3" s="4"><v>2026</v></c>
          <c r="Q3" s="1"/>
          <c r="R3"><v>1e3</v></c>
          <c r="S3"><v>abc</v></c>
          <c r="T3" t="s"><v>2</v></c>
        </row>
        <row r="4"><c t="b"><v>0</v></c><c><v>7</v></c></row>
        </sheetData>
        </worksheet>
        """
        let two = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c><v>5</v></c></row></sheetData></worksheet>
        """
        let data = ZipWriter.archive([
            ZipEntry(path: "_rels/.rels", data: Data(rels.utf8)),
            ZipEntry(path: "xl/book.xml", data: Data(workbook.utf8)),
            ZipEntry(path: "xl/_rels/book.xml.rels", data: Data(workbookRels.utf8)),
            ZipEntry(path: "xl/strings.xml", data: Data(sharedStrings.utf8)),
            ZipEntry(path: "xl/styles.xml", data: Data(styles.utf8)),
            ZipEntry(path: "xl/data/one.xml", data: Data(one.utf8)),
            ZipEntry(path: "xl/data/two.xml", data: Data(two.utf8)),
        ])
        let wb = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["First", "Second"])
        let first = wb.sheets[0]
        XCTAssertTrue(first.freezeHeader)
        XCTAssertEqual(first.columnWidths, [1: 11.5, 2: 11.5, 3: 11.5])
        XCTAssertEqual(first.rows.count, 4)
        XCTAssertEqual(first.rows[0], [.string("plain"), .empty, .string("rich text"), .string("has\rcr and \ttab")])
        XCTAssertEqual(first.rows[1], [], "skipped row keeps its position")
        let r3 = first.rows[2]
        XCTAssertEqual(r3.count, 20)
        XCTAssertEqual(r3[0], .empty)
        XCTAssertEqual(r3[1], .string("cached"), "cached string result wins over the formula")
        XCTAssertEqual(r3[2], .formula("1+1"), "no cached value → formula")
        XCTAssertEqual(r3[3], .empty, "empty <v>")
        XCTAssertEqual(r3[4], .string("#DIV/0!"))
        XCTAssertEqual(r3[5], .date(XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30)), "ISO date-time")
        XCTAssertEqual(r3[6], .dateOnly(XLSXTestSupport.ny(2026, 10, 14)), "ISO date")
        XCTAssertEqual(r3[7], .date(XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30)), "built-in date style 14")
        XCTAssertEqual(r3[8], .dateOnly(XLSXTestSupport.ny(2026, 10, 14)), "whole serial → date only")
        XCTAssertEqual(r3[9], .integer(46309), "custom 0.0 is not a date")
        XCTAssertEqual(r3[10], .bool(true))
        XCTAssertEqual(r3[11], .empty, "out-of-range shared string")
        XCTAssertEqual(r3[12], .string("inline"))
        XCTAssertEqual(r3[13], .integer(12), "whitespace trimmed")
        XCTAssertEqual(r3[14], .date(XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0)), "custom d-mmm-yy is a date")
        XCTAssertEqual(r3[15], .integer(2026), "quoted \"Year\" does not make a date format")
        XCTAssertEqual(r3[16], .empty, "styled cell without a value")
        XCTAssertEqual(r3[17], .number(1000), "exponent → number")
        XCTAssertEqual(r3[18], .string("abc"), "unparseable numeric text is kept")
        XCTAssertEqual(r3[19], .string("has\rcr and \ttab"))
        XCTAssertEqual(first.rows[3], [.bool(false), .integer(7)], "cells without r= are sequential")
        XCTAssertEqual(wb.sheets[1].rows, [[.integer(5)]])
        XCTAssertFalse(wb.sheets[1].freezeHeader)
    }

    func testDateFormatCodeDetection() {
        let yes = ["yyyy-mm-dd", "yyyy-mm-dd hh:mm", "d-mmm-yy", "h:mm AM/PM", "[$-409]mmm d, yyyy", "dd \"of\" mmmm yyyy",
                   "mm:ss", "[h]:mm:ss", "yyyy\\-mm\\-dd", "m/d/yy;@"]
        let no = ["0.00", "General", "#,##0", "\"Year\" 0", "[Red]0", "@", "0.00E+00", "\"hours\" 0.0 \"mins\"", "0%", "#,##0_);(#,##0)",
                  "* #,##0", "", "[$€-407]#,##0.00"]
        for code in yes { XCTAssertTrue(StylesParser.isDateFormatCode(code), code) }
        for code in no { XCTAssertFalse(StylesParser.isDateFormatCode(code), code) }
        for id in [14, 15, 22, 27, 36, 45, 47, 50, 58] { XCTAssertTrue(StylesParser.isDateFormat(id: id, customFormats: [:]), "\(id)") }
        for id in [0, 1, 2, 9, 10, 13, 23, 26, 37, 44, 48, 49, 59, 164] { XCTAssertFalse(StylesParser.isDateFormat(id: id, customFormats: [:]), "\(id)") }
        XCTAssertTrue(StylesParser.isDateFormat(id: 164, customFormats: [164: "yyyy"]))
        XCTAssertFalse(StylesParser.isDateFormat(id: 14, customFormats: [14: "0.00"]), "custom definition overrides the built-in id")
    }

    func testEscapeDecoding() {
        XCTAssertEqual(XLSXReader.decodeEscapes("a_x000D_b"), "a\rb")
        XCTAssertEqual(XLSXReader.decodeEscapes("_x0041__x0042_"), "AB")
        XCTAssertEqual(XLSXReader.decodeEscapes("_x00ZZ_ keep"), "_x00ZZ_ keep")
        XCTAssertEqual(XLSXReader.decodeEscapes("plain"), "plain")
        XCTAssertEqual(XLSXReader.decodeEscapes("_x"), "_x")
    }

    func testISODateParsing() {
        XCTAssertEqual(XLSXReader.parseISODate("2026-03-08T10:30:00", timeZone: ny), .date(XLSXTestSupport.ny(2026, 3, 8, 10, 30)))
        XCTAssertEqual(XLSXReader.parseISODate("2026-03-08T10:30:15.250Z", timeZone: ny), .date(XLSXTestSupport.ny(2026, 3, 8, 10, 30, 15)))
        XCTAssertEqual(XLSXReader.parseISODate("2026-11-01", timeZone: ny), .dateOnly(XLSXTestSupport.ny(2026, 11, 1)))
        XCTAssertNil(XLSXReader.parseISODate("2026-13-01", timeZone: ny))
        XCTAssertNil(XLSXReader.parseISODate("yesterday", timeZone: ny))
        XCTAssertNil(XLSXReader.parseISODate("2026-11-01T25:00", timeZone: ny))
    }

    func testPathNormalisation() {
        XCTAssertEqual(XLSXPackage.normalise("/xl/workbook.xml"), "xl/workbook.xml")
        XCTAssertEqual(XLSXPackage.normalise("xl/worksheets/../sharedStrings.xml"), "xl/sharedStrings.xml")
        XCTAssertEqual(XLSXPackage.normalise("./a//b\\c"), "a/b/c")
        XCTAssertEqual(XLSXPackage.resolve(target: "worksheets/sheet1.xml", baseDirectory: "xl"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XLSXPackage.resolve(target: "/xl/styles.xml", baseDirectory: "xl"), "xl/styles.xml")
        XCTAssertEqual(XLSXPackage.resolve(target: "xl/workbook.xml", baseDirectory: ""), "xl/workbook.xml")
        XCTAssertEqual(XLSXPackage.relsPath(for: "xl/workbook.xml"), "xl/_rels/workbook.xml.rels")
        XCTAssertEqual(XLSXPackage.relsPath(for: "book.xml"), "_rels/book.xml.rels")
    }
}

// MARK: - Real-world fixtures

final class XLSXFixtureTests: XCTestCase {
    let ny = XLSXTestSupport.newYork

    func testOpenpyxlWorkbook() throws {
        let wb = try XLSXReader.read(WorkbookFixtures.data(WorkbookFixtures.openpyxl), timeZone: ny)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["Data", "Second (sheet)"])
        let data = wb.sheets[0]
        XCTAssertTrue(data.freezeHeader)
        XCTAssertEqual(data.columnWidths[0], 22.5)
        XCTAssertEqual(data.rows.count, 4)
        XCTAssertEqual(data.rows[0], ["Name", "When", "Day", "Count", "Ratio", "Flag", "Total", "Note"].map { Cell.string($0) })
        XCTAssertEqual(data.rows[1], [
            .string("Plant A"), .date(XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30)), .dateOnly(XLSXTestSupport.ny(2026, 11, 26)),
            .integer(42), .number(3.75), .bool(true), .formula("D2*E2"), .string("café & <tags> \"quoted\" 'single'"),
        ])
        XCTAssertEqual(data.rows[2], [
            .string("Plant B"), .empty, .dateOnly(XLSXTestSupport.ny(2026, 3, 8)), .empty, .number(-0.5), .empty, .bool(false), .string("Plant A"),
        ])
        XCTAssertEqual(data.rows[3], [
            .string("Bold and plain"), .date(XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0)), .string("styled"), .integer(0), .number(1e-05),
            .empty, .empty, .string("line1\nline2"),
        ])
        let second = wb.sheets[1]
        XCTAssertFalse(second.freezeHeader)
        XCTAssertEqual(second.rows, [
            [.string("K"), .string("V")],
            [.string("alpha"), .integer(1)],
            [.string("beta"), .number(2.5)],
            [.string("gamma"), .date(XLSXTestSupport.ny(2026, 3, 8, 10, 30, 0))],
        ])
        XCTAssertEqual(data.records[0]["Count"], .integer(42))
    }

    func testXlsxWriterWorkbookWithSharedStrings() throws {
        let wb = try XLSXReader.read(WorkbookFixtures.data(WorkbookFixtures.xlsxwriter), timeZone: ny)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["Days", "Lookup"])
        let days = wb.sheets[0]
        XCTAssertTrue(days.freezeHeader)
        XCTAssertEqual(days.columnWidths[0] ?? 0, 14.7109375, accuracy: 1e-9)
        XCTAssertEqual(days.rows.count, 4)
        XCTAssertEqual(days.rows[0], ["Date", "Weekday", "Kind", "First In", "Hours", "Count", "Flag", "Note", "Total"].map { Cell.string($0) })
        XCTAssertEqual(days.rows[1], [
            .dateOnly(XLSXTestSupport.ny(2026, 10, 14)), .string("Wednesday"), .string("Workday"), .date(XLSXTestSupport.ny(2026, 10, 14, 7, 2, 30)),
            .number(8.75), .integer(3), .bool(true), .string("Late stay & <extra>"), .number(17.5),
        ])
        XCTAssertEqual(days.rows[2], [
            .dateOnly(XLSXTestSupport.ny(2026, 11, 1)), .empty, .string("Workday"), .empty, .number(-1.25), .empty, .empty, .string("Wednesday"),
        ])
        XCTAssertEqual(days.rows[3], [
            .dateOnly(XLSXTestSupport.ny(2026, 3, 8)), .empty, .empty, .date(XLSXTestSupport.ny(2026, 11, 1, 15, 0, 0)),
            .date(XLSXTestSupport.ny(2026, 3, 8, 10, 30, 0)), .integer(0), .bool(false), .string("tab\tand \"quotes\" and 'apostrophe'"),
        ])
        XCTAssertEqual(wb.sheets[1].rows, [
            [.string("ID"), .string("Name")], [.integer(1), .string("Plant A")], [.integer(2), .string("Plant B")],
        ])
        XCTAssertFalse(wb.sheets[1].freezeHeader)
    }

    func testOurOutputRezippedWithDeflateReadsBack() throws {
        let data = WorkbookFixtures.data(WorkbookFixtures.rezippedDeflate)
        XCTAssertFalse(data.isEmpty, "fixture present")
        // Every entry is method 8 (deflate), so this exercises Inflate end to end through the reader.
        let methods = try ZipReader.entries(from: data).count
        XCTAssertEqual(methods, 7)
        XCTAssertEqual(Int(data[8]) | Int(data[9]) << 8, 8, "first entry is deflated")
        let wb = try XLSXReader.read(data, timeZone: ny)
        let want = XLSXTestSupport.sampleWorkbook()
        XCTAssertEqual(wb.sheets.count, want.sheets.count)
        for (g, w) in zip(wb.sheets, want.sheets) { XLSXTestSupport.assertSheetsEqual(g, w) }
    }
}
