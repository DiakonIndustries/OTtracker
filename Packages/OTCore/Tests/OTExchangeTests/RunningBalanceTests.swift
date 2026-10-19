import XCTest
import OTModels
import OTLedger
import OTXLSX
@testable import OTExchange

/// The Days sheet's running balance continues the real bank balance for ranged exports.
final class RunningBalanceTests: XCTestCase {
    private let cal = RichFixture.calendar
    private var runningColumn: Int { ExportBuilder.daysHeader.firstIndex(of: "Running Balance (hours)")! }
    private var deltaColumn: Int { ExportBuilder.daysHeader.firstIndex(of: "Delta (hours)")! }

    private func hours(_ cell: Cell?) -> Double { cell?.doubleValue ?? .nan }

    func testRangedExportContinuesTheBankBalance() throws {
        let store = RichFixture.store()
        let now = RichFixture.now
        let allFrom = Ledger.trackingStart(store: store, now: now)
        let through = DayKey(now, calendar: cal)
        let from = allFrom.adding(days: 10, calendar: cal)
        XCTAssertLessThan(from, through)

        let results = Ledger.dayResults(store: store, from: from, through: through, now: now)
        let opening = Ledger.balance(store: store, asOf: from.adding(days: -1, calendar: cal), now: now)
        let wb = ExportBuilder.workbook(store: store, dayResults: results, from: from, through: through, now: now,
                                        openingBalanceSeconds: opening)
        let days = wb.sheet(named: "Days")!
        let firstRow = days.rows[1]
        let expectedFirst = Double(Ledger.balance(store: store, asOf: from, now: now)) / 3600
        XCTAssertEqual(hours(firstRow[runningColumn]), expectedFirst, accuracy: 0.0001)
        let lastRow = days.rows[days.rows.count - 1]
        let expectedLast = Double(Ledger.balance(store: store, asOf: through, now: now)) / 3600
        XCTAssertEqual(hours(lastRow[runningColumn]), expectedLast, accuracy: 0.0001)
        XCTAssertEqual(hours(lastRow[runningColumn]), Double(Ledger.summary(store: store, now: now).balanceSeconds) / 3600, accuracy: 0.0001)
    }

    func testDaysBeforeTrackingStartShowDeltaButDoNotMoveTheBalance() throws {
        var store = RichFixture.store()
        let now = RichFixture.now
        let trackingStart = Ledger.trackingStart(store: store, now: now)
        store.settings.bankStartingAsOf = trackingStart.adding(days: 5, calendar: cal)
        store.settings.bankStartingSeconds = 3600
        let newStart = Ledger.trackingStart(store: store, now: now)
        XCTAssertEqual(newStart, store.settings.bankStartingAsOf)

        let from = trackingStart
        let through = newStart.adding(days: 3, calendar: cal)
        let results = Ledger.dayResults(store: store, from: from, through: through, now: now)
        let wb = ExportBuilder.workbook(store: store, dayResults: results, from: from, through: through, now: now)
        let days = wb.sheet(named: "Days")!
        // Rows before bankStartingAsOf keep the starting balance even when their delta is non-zero.
        var sawNonZeroDeltaBefore = false
        for (i, r) in results.enumerated() where r.day < newStart {
            let row = days.rows[i + 1]
            if r.deltaSeconds != 0 { sawNonZeroDeltaBefore = true }
            XCTAssertEqual(hours(row[runningColumn]), 1.0, accuracy: 0.0001, "\(r.day)")
        }
        XCTAssertTrue(sawNonZeroDeltaBefore, "fixture should have activity before the new start")
        let last = days.rows[days.rows.count - 1]
        XCTAssertEqual(hours(last[runningColumn]), Double(Ledger.balance(store: store, asOf: through, now: now)) / 3600, accuracy: 0.0001)
    }

    func testDefaultOpeningIsTheStartingBalance() throws {
        let store = RichFixture.store()
        let now = RichFixture.now
        let from = Ledger.trackingStart(store: store, now: now)
        let through = DayKey(now, calendar: cal)
        let results = Ledger.dayResults(store: store, from: from, through: through, now: now)
        let wb = ExportBuilder.workbook(store: store, dayResults: results, from: from, through: through, now: now)
        let days = wb.sheet(named: "Days")!
        let first = days.rows[1]
        let expected = Double(store.settings.bankStartingSeconds + results[0].deltaSeconds) / 3600
        XCTAssertEqual(hours(first[runningColumn]), expected, accuracy: 0.0001)
    }
}
