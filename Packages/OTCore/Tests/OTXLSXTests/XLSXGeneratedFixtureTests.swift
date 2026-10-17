import XCTest
import OTZip
@testable import OTXLSX

/// Workbooks written by XlsxWriter and openpyxl (see `GeneratedWorkbookFixtures`), read back cell by cell.
final class XLSXGeneratedFixtureTests: XCTestCase {
    let ny = XLSXTestSupport.newYork
    typealias S = XLSXTestSupport

    /// Instant for a New York wall clock; nil when `Calendar` cannot place it.
    private func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date? {
        S.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = S.utc
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    // MARK: XlsxWriter: shared strings, rich text, cached formulas, merges, hidden sheet

    func testXlsxWriterFeaturesWorkbook() throws {
        let data = GeneratedWorkbookFixtures.data(GeneratedWorkbookFixtures.features)
        XCTAssertFalse(data.isEmpty, "fixture decodes")
        let wb = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(wb.sheets.map { $0.name }, ["Features", "Hidden", "Third"], "hidden sheets are listed in workbook order")

        let f = wb.sheets[0]
        XCTAssertTrue(f.freezeHeader)
        XCTAssertEqual(f.columnWidths.count, 2)
        XCTAssertEqual(f.columnWidths[0] ?? 0, 25.7109375, accuracy: 1e-9)
        XCTAssertEqual(f.columnWidths[2] ?? 0, 41.28515625, accuracy: 1e-9)
        XCTAssertEqual(f.rows.count, 14)
        XCTAssertEqual(f.rows[0], [.string("Label"), .string("Value"), .string("Note")])
        XCTAssertEqual(f.rows[1], [.string("Bold and plain"), .string("plain shared"), .bool(true)], "rich-text runs are concatenated")
        XCTAssertEqual(f.rows[2], [.number(12.5), .string("ab"), .bool(true)], "cached formula results win over the formula text")
        XCTAssertEqual(f.rows[3], [.string("Numbers"), .integer(5), .number(-2.25)])
        XCTAssertEqual(f.rows[4], [.string("More"), .number(7.5), .number(1e-05)], "upper-case exponent")
        XCTAssertEqual(f.rows[5], [], "blank row keeps its position")
        XCTAssertEqual(f.rows[6], [.date(S.ny(2026, 10, 14, 7, 2, 30)), .date(S.ny(2026, 11, 1, 15, 0, 0)), .date(S.ny(2026, 3, 8, 10, 30, 0))],
                       "XlsxWriter registers mm-dd-yy, d-mmm-yy and m/d/yy h:mm as custom codes 164-166")
        XCTAssertEqual(f.rows[7], [.date(S.ny(2026, 3, 8, 23, 59, 59)), .dateOnly(S.ny(2026, 11, 26)), .date(S.ny(1899, 12, 31, 7, 2, 30))],
                       "custom dd/mm/yyyy hh:mm:ss, [$-409]mmmm d, yyyy;@ and a time-only serial (day 0 = 1899-12-31)")
        XCTAssertEqual(f.rows[8], [.string("0042"), .number(3.5), .number(1234.5)], "text number stays text; @ and \"$\"#,##0.00 are not dates")
        XCTAssertEqual(f.rows[8][0].doubleValue, 42)
        XCTAssertEqual(f.rows[9], [.string("merged across three"), .empty, .empty], "merged range: value in the top-left, styled empties after")
        XCTAssertEqual(f.rows[10], [.bool(false), .bool(true), .string("last")])
        XCTAssertEqual(f.rows[11], [])
        XCTAssertEqual(f.rows[12], [])
        XCTAssertEqual(f.rows[13], [.empty, .empty, .empty, .empty, .empty, .string("plain shared")], "shared string reused by index")
        XCTAssertEqual(f.records[1]["Label"], .number(12.5))

        let hidden = wb.sheets[1]
        XCTAssertFalse(hidden.freezeHeader)
        XCTAssertEqual(hidden.rows, [[.string("secret"), .integer(99)]])

        let third = wb.sheets[2]
        XCTAssertEqual(third.rows, [[.string("x")], [.integer(1), .integer(0)], [.integer(2)]], "formula with a cached 0 reads as 0")
    }

    func testFeaturesReZippedWithDataDescriptorsReadsIdentically() throws {
        let plain = try XLSXReader.read(GeneratedWorkbookFixtures.data(GeneratedWorkbookFixtures.features), timeZone: ny)
        let data = GeneratedWorkbookFixtures.data(GeneratedWorkbookFixtures.featuresWithDataDescriptors)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(Int(data[6]) & 0x08, 0x08, "first local header has flag bit 3")
        XCTAssertEqual(Int(data[8]) | Int(data[9]) << 8, 8, "deflated")
        let viaDescriptors = try XLSXReader.read(data, timeZone: ny)
        XCTAssertEqual(viaDescriptors, plain)
    }

    // MARK: openpyxl: 1000 rows, built-in date ids, DST wall clocks

    func testOpenpyxlThousandRowsReadQuicklyAndExactly() throws {
        let data = GeneratedWorkbookFixtures.data(GeneratedWorkbookFixtures.thousandRows)
        XCTAssertFalse(data.isEmpty)
        let started = ProcessInfo.processInfo.systemUptime
        let wb = try XLSXReader.read(data, timeZone: ny)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 5, "1000 rows must not take seconds")

        XCTAssertEqual(wb.sheets.map { $0.name }, ["Rows", "Dates"])
        let rows = wb.sheets[0]
        XCTAssertFalse(rows.freezeHeader)
        XCTAssertTrue(rows.columnWidths.isEmpty)
        XCTAssertEqual(rows.rows.count, 1001)
        XCTAssertEqual(rows.rows[0], ["ID", "Name", "Day", "Amount", "Flag"].map { Cell.string($0) })
        var day = S.ny(2024, 1, 1)
        for i in 1...1000 {
            let row = rows.rows[i]
            XCTAssertEqual(row.count, 5, "row \(i + 1)")
            XCTAssertEqual(row[0], .integer(i), "row \(i + 1) id")
            XCTAssertEqual(row[1], .string("Item \(i)"), "row \(i + 1) name")
            XCTAssertEqual(row[2], .dateOnly(day), "row \(i + 1) day")
            let amount = Double(i) * 0.25
            XCTAssertEqual(row[3], i % 4 == 0 ? .integer(i / 4) : .number(amount), "row \(i + 1) amount")
            XCTAssertEqual(row[4], .bool(i % 3 == 0), "row \(i + 1) flag")
            day = S.calendar.date(byAdding: .day, value: 1, to: day)!
        }
        XCTAssertEqual(rows.records.count, 1000)
        XCTAssertEqual(rows.records[999]["Name"], .string("Item 1000"))

        let dates = wb.sheets[1]
        XCTAssertEqual(dates.rows.count, 3)
        XCTAssertEqual(dates.rows[0].count, 7)
        let r2 = dates.rows[1]
        XCTAssertEqual(r2[0], .date(S.ny(2026, 10, 14, 7, 2, 30)), "built-in 14 mm-dd-yy")
        XCTAssertEqual(r2[1], .date(S.ny(2026, 11, 1, 15, 0, 0)), "built-in 15 d-mmm-yy")
        XCTAssertEqual(r2[2], .date(S.ny(2026, 3, 8, 10, 30, 0)), "built-in 22 m/d/yy h:mm")
        XCTAssertEqual(r2[3], .date(S.ny(2026, 3, 8, 23, 59, 59)), "custom dd/mm/yyyy hh:mm:ss")
        XCTAssertEqual(r2[4], .date(S.ny(1899, 12, 31, 7, 2, 30)), "built-in 19 h:mm:ss AM/PM, time only")
        XCTAssertEqual(r2[5], .number(3.5), "built-in 49 @ is text format, not a date")
        XCTAssertEqual(r2[6], .dateOnly(S.ny(1900, 2, 15)), "serial 46 is before Excel's phantom 1900-02-29")

        let r3 = dates.rows[2]
        // 01:30 on 2026-11-01 happens twice in New York; the wall clock must survive whichever instant Calendar picks.
        guard case .date(let ambiguous) = r3[0] else { return XCTFail("\(r3[0])") }
        XCTAssertTrue([utc(2026, 11, 1, 5, 30), utc(2026, 11, 1, 6, 30)].contains(ambiguous), "\(ambiguous)")
        let c = S.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: ambiguous)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 1, 1, 30])
        // 02:30 on 2026-03-08 does not exist; Calendar resolves it to a neighbouring instant rather than failing.
        guard case .date(let missing) = r3[1] else { return XCTFail("\(r3[1])") }
        XCTAssertTrue([utc(2026, 3, 8, 6, 30), utc(2026, 3, 8, 7, 30)].contains(missing), "\(missing)")
        XCTAssertEqual(r3[2], .dateOnly(S.ny(2026, 11, 1)), "midnight with a date-time format is still a whole day")
    }
}
