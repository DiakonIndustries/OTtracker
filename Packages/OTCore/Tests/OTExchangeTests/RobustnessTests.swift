import XCTest
import OTModels
import OTXLSX
@testable import OTExchange

/// Files that are not ours, garbage, odd names: the importer must report, never crash.
final class RobustnessTests: XCTestCase {
    let store = Store(settings: RichFixture.settings)

    func testForeignWorkbookGivesAnEmptyBundleWithoutCrashing() throws {
        let data = ForeignFileFixtures.openpyxlWorkbook
        XCTAssertEqual(data.count, 6240)
        // The OTXLSX reader copes with the file itself.
        let wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["Budget", "Sheet 2", "Presence"])
        XCTAssertEqual(wb.sheets[0].header, ["Item", "Qty", "Price", "When", "Note"])
        XCTAssertEqual(wb.sheets[0].rows[1][3], .date(RichFixture.date(2026, 10, 14, 7, 2)))
        XCTAssertTrue(wb.sheets[0].freezeHeader)

        for name in ["random.xlsx", "RANDOM.XLSX", "no-extension"] {
            XCTAssertEqual(ImportParser.detectFormat(data: data, filename: name), .xlsx, name)
            let b = try ImportParser.parse(data: data, filename: name, store: store)
            XCTAssertTrue(b.isEmpty, name)
            XCTAssertNil(b.settings)
            XCTAssertTrue(b.timeOffTypes.isEmpty && b.leaveBalances.isEmpty)
            // The "Presence" sheet exists but has none of our columns: its row is reported, not imported.
            XCTAssertEqual(b.invalid.map { $0.line }, [2], name)
            XCTAssertTrue(b.invalid[0].reason.hasPrefix("Presence row 2: missing location"), b.invalid[0].reason)
            let plan = Importer.plan(store: store, bundle: b, mode: .merge)
            XCTAssertEqual(plan.totalNew + plan.totalUpdated + plan.totalUnchanged, 0)
            var s = store
            Importer.apply(plan: plan, mode: .merge, to: &s)
            XCTAssertEqual(s, store)
        }
    }

    func testWorkbookWithoutAnyOfOurSheetsIsEmptyAndClean() throws {
        let data = try XLSXWriter.write(Workbook(sheets: [Worksheet(name: "Totals", rows: [[.string("a")], [.integer(1)]])]), timeZone: RichFixture.timeZone)
        let b = try ImportParser.parse(data: data, filename: "totals.xlsx", store: store)
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.invalid, [])
    }

    func testDetectFormatOnEmptyZipAndGarbage() {
        XCTAssertNil(ImportParser.detectFormat(data: Data(), filename: ""))
        XCTAssertNil(ImportParser.detectFormat(data: Data(), filename: "empty"))
        XCTAssertNil(ImportParser.detectFormat(data: Data(), filename: "empty.txt"))
        // Extensions win even on empty data (the parser then reports the problem).
        XCTAssertEqual(ImportParser.detectFormat(data: Data(), filename: "empty.csv"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: Data(), filename: "empty.xlsx"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: Data(), filename: "empty.json"), .json)

        // A zip that is not a workbook sniffs as xlsx (PK signature) and fails to read, cleanly.
        XCTAssertEqual(ImportParser.detectFormat(data: ForeignFileFixtures.plainZip, filename: "archive.zip"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: ForeignFileFixtures.plainZip, filename: "archive"), .xlsx)
        for name in ["archive.zip", "archive", "archive.xlsx", "Archive.XLSX"] {
            XCTAssertThrowsError(try ImportParser.parse(data: ForeignFileFixtures.plainZip, filename: name, store: store), name) {
                guard case .unreadable(let why)? = $0 as? ImportError else { return XCTFail("expected unreadable, got \($0)") }
                XCTAssertTrue(why.contains("Excel"), why)
            }
        }
        // A PK signature followed by junk.
        let fakeZip = Data([0x50, 0x4B, 0x03, 0x04]) + Data((0..<200).map { UInt8(($0 * 37) % 256) })
        XCTAssertEqual(ImportParser.detectFormat(data: fakeZip, filename: "x"), .xlsx)
        XCTAssertThrowsError(try ImportParser.parse(data: fakeZip, filename: "x", store: store))

        // Binary garbage of unknown shape is not a format at all.
        let garbage = Data((0..<512).map { UInt8(($0 * 131 + 7) % 256) })
        XCTAssertNil(ImportParser.detectFormat(data: garbage, filename: "blob"))
        XCTAssertNil(ImportParser.detectFormat(data: garbage, filename: "blob.bin"))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        XCTAssertNil(ImportParser.detectFormat(data: png, filename: "photo.png"))
        let nulls = Data(repeating: 0, count: 64)
        XCTAssertNil(ImportParser.detectFormat(data: nulls, filename: "zeros"))
        XCTAssertThrowsError(try ImportParser.parse(data: garbage, filename: "blob", store: store)) {
            XCTAssertEqual($0 as? ImportError, .unrecognizedFormat)
        }
        // Garbage with a .csv name is parsed as CSV and reported on line 1, not crashed on.
        let b = try? ImportParser.parse(data: garbage, filename: "blob.csv", store: store)
        XCTAssertEqual(b?.isEmpty, true)
        XCTAssertEqual(b?.invalid.first?.line, 1)

        // Latin-1 text (not valid UTF-8) is still text.
        let latin1 = Data("record,date,start,end,location\npresence,2026-10-14,07:00,15:00,Caf".utf8) + Data([0xE9]) + Data("\n".utf8)
        XCTAssertEqual(ImportParser.detectFormat(data: latin1, filename: "x"), .csv)
        XCTAssertEqual((try? ImportParser.parse(data: latin1, filename: "x", store: store))?.presence.first?.locationName, "Café")
    }

    func testFilenamesWithUppercaseOrOddExtensions() throws {
        let csv = Data(ExportBuilder.csvTemplate().utf8)
        let json = try ExportBuilder.json(store: RichFixture.store())
        let xlsx = try RichFixture.xlsx()
        XCTAssertEqual(ImportParser.detectFormat(data: csv, filename: "Template.CSV"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: csv, filename: "template.Csv"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: json, filename: "Backup.Json"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: json, filename: "BACKUP.JSON"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: xlsx, filename: "Export.XLSX"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: xlsx, filename: "export.Xlsx"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: xlsx, filename: "/Users/me/Downloads/OTtracker 2026-10.XLSX"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: csv, filename: "my.data.v2.CSV"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: csv, filename: ".csv"), .csv)        // sniffed: a dotfile has no extension
        XCTAssertEqual(ImportParser.detectFormat(data: xlsx, filename: "export.xlsx.bak"), .xlsx)   // sniffed
        XCTAssertEqual(ImportParser.detectFormat(data: csv, filename: "import.txt"), .csv)   // sniffed
        XCTAssertEqual(try ImportParser.parse(data: xlsx, filename: "Export.XLSX", store: store).presence.count, RichFixture.counts["presence"]!)
        XCTAssertEqual(try ImportParser.parse(data: json, filename: "Backup.Json", store: store).fullStore, RichFixture.store())
        XCTAssertEqual(try ImportParser.parse(data: csv, filename: "Template.CSV", store: store).presence.count, 1)
    }

    func testWrongContentBehindAKnownExtensionIsReportedNotCrashed() throws {
        let csv = Data(ExportBuilder.csvTemplate().utf8)
        let json = try ExportBuilder.json(store: RichFixture.store())
        XCTAssertThrowsError(try ImportParser.parse(data: csv, filename: "notreally.json", store: store)) {
            guard case .unreadable? = $0 as? ImportError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try ImportParser.parse(data: csv, filename: "notreally.xlsx", store: store)) {
            guard case .unreadable? = $0 as? ImportError else { return XCTFail("\($0)") }
        }
        let b = try ImportParser.parse(data: json, filename: "notreally.csv", store: store)
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.invalid.map { $0.line }, [1])
    }

    func testTruncatedWorkbookIsUnreadableNotACrash() throws {
        let xlsx = try RichFixture.xlsx()
        for cut in [10, 100, 1000, xlsx.count / 2, xlsx.count - 10] {
            XCTAssertThrowsError(try ImportParser.parse(data: xlsx.prefix(cut), filename: "cut.xlsx", store: store), "\(cut)") {
                guard case .unreadable? = $0 as? ImportError else { return XCTFail("cut \(cut): \($0)") }
            }
        }
    }

    func testHugeOrAbsurdValuesInOurOwnSheetsAreRejectedPerRow() throws {
        let wb = Workbook(sheets: [
            Fixtures.sheet("Presence", ExportBuilder.presenceHeader, [
                [.empty, .string("Plant A"), .number(1e300), .empty, .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .number(-5), .empty, .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .string(""), .empty, .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .bool(true), .empty, .empty, .empty, .empty, .empty],
            ]),
            Fixtures.sheet("TimeOff", ExportBuilder.timeOffHeader, [
                [.empty, .string("2026-10-20"), .string("PTO"), .string("eight"), .empty, .empty],
                [.empty, .string("2026-10-20"), .string("PTO"), .number(-1), .empty, .empty],
                [.empty, .number(1e300), .string("PTO"), .integer(1), .empty, .empty],
            ]),
            Fixtures.sheet("Locations", ExportBuilder.locationsHeader, [
                [.empty, .string("Nowhere"), .string("north"), .number(0), .number(0), .bool(true)],
            ]),
            Fixtures.sheet("Settings", ExportBuilder.settingsHeader, [
                [.string("graceMinutes"), .string("five")],
                [.string("bankStartingAsOf"), .string("someday")],
                [.string("weekStartsOn"), .string("Funday")],
                [.string("manualCategories"), .string("")],
            ]),
        ])
        let b = ImportParser.parse(workbook: wb, store: store)
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.invalid.count, 12)
        XCTAssertNil(b.settings)
        for row in b.invalid { XCTAssertFalse(row.reason.contains("Optional"), row.reason) }
    }
}
