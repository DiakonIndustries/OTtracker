import XCTest
import OTModels
import OTXLSX
import OTCSV
@testable import OTExchange

final class ExportBuilderTests: XCTestCase {
    let cal = Fixtures.calendar

    func testExactlyTwelveSheetsInSpecOrderWithSpecHeaders() {
        let wb = Fixtures.workbook()
        XCTAssertEqual(wb.sheets.map { $0.name },
                       ["Summary", "Days", "Presence", "Manual", "TimeOff", "Holidays", "Locations", "Schedule", "Overrides", "Adjustments", "Events", "Settings"])
        XCTAssertEqual(wb.sheets[0].header, ["Item", "Value", "Hours", "Accrued (h)", "Used (h)"])
        XCTAssertEqual(wb.sheets[1].header, ["Date", "Weekday", "Kind", "Sched Start", "Sched End", "Expected (h)", "First In", "Last Out",
                                             "Presence", "Extra After", "Extra Before", "Early Counted", "Gaps Deducted", "Gaps Work",
                                             "Late Arrival", "Early Exit", "Manual Extra", "Manual Regular", "Time Off", "Flex Spent",
                                             "Adjustments", "Delta (h:mm)", "Delta (hours)", "Running Balance (hours)", "Flags"])
        XCTAssertEqual(wb.sheets[2].header, ["ID", "Location", "Entered", "Exited", "Duration", "Source", "Gap After", "Note"])
        XCTAssertEqual(wb.sheets[3].header, ["ID", "Category", "Counts As", "Started", "Stopped", "Active Duration", "Segments", "Note"])
        XCTAssertEqual(wb.sheets[4].header, ["ID", "Date", "Type", "Hours", "Minutes", "Note"])
        XCTAssertEqual(wb.sheets[5].header, ["ID", "Date", "Name"])
        XCTAssertEqual(wb.sheets[6].header, ["ID", "Name", "Latitude", "Longitude", "Radius (m)", "Active"])
        XCTAssertEqual(wb.sheets[7].header, ["Effective From", "Weekday", "Workday", "Start", "End", "Break (min)", "Version ID"])
        XCTAssertEqual(wb.sheets[8].header, ["ID", "Date", "Kind", "Start", "End", "Break", "Count Early", "Excused", "Note"])
        XCTAssertEqual(wb.sheets[9].header, ["ID", "Date", "Seconds", "Hours", "Reason"])
        XCTAssertEqual(wb.sheets[10].header, ["ID", "Location", "Kind", "Time", "Source"])
        XCTAssertEqual(wb.sheets[11].header, ["Key", "Value"])
        for sheet in wb.sheets { XCTAssertTrue(sheet.freezeHeader, sheet.name) }
    }

    func testDefaultedTrailingParametersKeepOldCallsCompiling() {
        let wb = ExportBuilder.workbook(store: Fixtures.store(), dayResults: [], from: Fixtures.rangeFrom, through: Fixtures.rangeThrough, now: Fixtures.now)
        XCTAssertEqual(wb.sheets.count, 12)
        XCTAssertEqual(wb.sheets[1].rows.count, 1)
    }

    func testSummarySheet() {
        let rows = Fixtures.workbook().sheets[0].rows
        XCTAssertEqual(rows[1][0], .string("Generated"))
        XCTAssertEqual(rows[1][1], .date(Fixtures.now))
        XCTAssertEqual(rows[2].texts.prefix(2), ["Range", "2026-01-01 – 2026-12-31"])
        XCTAssertEqual(rows[3][0], .string("Balance"))
        XCTAssertEqual(rows[3][1], .string("+1:30"))
        XCTAssertCell(rows[3][2], .number(1.5))
        XCTAssertEqual(rows[4][0], .string("This month gross extra"))
        XCTAssertEqual(rows[4][1], .string("+2:00"))
        XCTAssertEqual(rows[5][0], .string("Month delta"))
        XCTAssertEqual(rows[5][1], .string("+1:45"))
        XCTAssertEqual(rows[6][0], .string("Week delta"))
        XCTAssertEqual(rows[6][1], .string("-0:15"))
        XCTAssertEqual(rows[7][0], .string("YTD delta"))
        XCTAssertEqual(rows[7][1], .string("+0:30"))
        // One row per leave balance: name, remaining h:mm, remaining hours, accrued, used.
        XCTAssertEqual(rows[8][0], .string("Leave: PTO"))
        XCTAssertEqual(rows[8][1], .string("+109:45"))   // 120h − 10h15m30s, rounded to the minute
        let usedSeconds: Int = 36930                 // 10h15m30s
        let remainingSeconds: Int = 432000 - usedSeconds
        XCTAssertCell(rows[8][2], .number(Double(remainingSeconds) / 3600.0))
        XCTAssertCell(rows[8][3], .number(80))
        XCTAssertCell(rows[8][4], .number(Double(usedSeconds) / 3600.0))
        XCTAssertEqual(rows[9][0], .string("Leave: Personal"))
        XCTAssertEqual(rows.count, 10)
    }

    func testDaysSheetRows() {
        let rows = Fixtures.workbook().sheets[1].rows
        XCTAssertEqual(rows.count, 5)
        let r1 = rows[1]
        XCTAssertEqual(r1[0], .dateOnly(Fixtures.day(2026, 3, 9).start(in: cal)))
        XCTAssertEqual(r1[1], .string("Monday"))
        XCTAssertEqual(r1[2], .string("workday"))
        XCTAssertEqual(r1[3], .string("07:00"))
        XCTAssertEqual(r1[4], .string("15:30"))
        XCTAssertCell(r1[5], .number(8.5))
        XCTAssertEqual(r1[6], .date(Fixtures.date(2026, 3, 9, 7, 0, 30)))
        XCTAssertEqual(r1[7], .date(Fixtures.date(2026, 3, 9, 15, 35, 15)))
        XCTAssertEqual(r1[8], .string("8:35"))          // 8h34m45s presence, h:mm
        XCTAssertEqual(r1[9], .string("0:05"))          // extra after
        XCTAssertEqual(r1[10], .string("0:00"))         // extra before
        XCTAssertEqual(r1[11], .string("0:00"))         // early counted
        XCTAssertEqual(r1[20], .string("0:00"))         // adjustments
        XCTAssertEqual(r1[21], .string("+0:05"))        // delta h:mm
        XCTAssertCell(r1[22], .number(315.0 / 3600.0))
        XCTAssertCell(r1[23], .number(3915.0 / 3600.0))   // bank start 3600 + running delta 315
        XCTAssertEqual(r1[24], .string("graceApplied"))

        let r2 = rows[2]
        XCTAssertEqual(r2[12], .string("1:30"))         // gaps deducted
        XCTAssertEqual(r2[21], .string("-1:00"))
        XCTAssertCell(r2[23], .number(315.0 / 3600.0))
        XCTAssertEqual(r2[24], .string("gapUndecided"))

        let r3 = rows[3]
        XCTAssertEqual(r3[18], .string("8:00"))         // time off
        XCTAssertEqual(r3[6], .empty)                   // no first in
        XCTAssertEqual(r3[7], .empty)

        let r4 = rows[4]
        XCTAssertEqual(r4[1], .string("Sunday"))
        XCTAssertEqual(r4[2], .string("weekend"))
        XCTAssertEqual(r4[3], .empty)
        XCTAssertEqual(r4[4], .empty)
        XCTAssertCell(r4[5], .number(0))
        XCTAssertEqual(r4[21], .string("+2:00"))
        XCTAssertCell(r4[23], .number(5715.0 / 3600.0))
        XCTAssertEqual(r4[24], .string(""))
    }

    func testDaysSheetFlagsAreCommaSeparatedRawValues() {
        let result = DayResult(day: Fixtures.day(2026, 3, 8), kind: .weekend, flags: [.openPresence, .inProgress])
        let wb = ExportBuilder.workbook(store: Fixtures.store(), dayResults: [result], from: Fixtures.rangeFrom, through: Fixtures.rangeThrough, now: Fixtures.now)
        XCTAssertEqual(wb.sheets[1].rows[1][24], .string("openPresence, inProgress"))
    }

    func testPresenceSheet() {
        let rows = Fixtures.workbook().sheets[2].rows
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[1].texts[0], Fixtures.uuid(20).uuidString)
        XCTAssertEqual(rows[1][1], .string("Plant A"))
        XCTAssertEqual(rows[1][2], .date(Fixtures.date(2026, 3, 8, 6, 55)))
        XCTAssertEqual(rows[1][3], .date(Fixtures.date(2026, 3, 8, 16, 10)))
        XCTAssertEqual(rows[1][4], .string("9:15"))
        XCTAssertEqual(rows[1][5], .string("geofence"))
        XCTAssertEqual(rows[1][6], .string(""))
        // Gap decisions as text.
        XCTAssertEqual(rows[3][6], .string("personal"))
        XCTAssertEqual(rows[3][7], .string("dentist"))
        XCTAssertEqual(rows[4][1], .string("Plant B"))
        XCTAssertEqual(rows[4][6], .string("work"))
        XCTAssertEqual(rows[4][5], .string("manual"))
        // Open session: no exit, no duration.
        XCTAssertEqual(rows[6][3], .empty)
        XCTAssertEqual(rows[6][4], .empty)
    }

    func testManualSheetAndSegmentsText() {
        let rows = Fixtures.workbook().sheets[3].rows
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[1][1], .string("After hours"))
        XCTAssertEqual(rows[1][2], .string("extra"))
        XCTAssertEqual(rows[1][3], .date(Fixtures.date(2026, 3, 9, 19, 0)))
        XCTAssertEqual(rows[1][4], .date(Fixtures.date(2026, 3, 9, 20, 15)))
        XCTAssertEqual(rows[1][5], .string("1:15"))
        XCTAssertEqual(rows[1][6], .string("19:00–20:15"))
        XCTAssertEqual(rows[1][7], .string("emails"))
        // Multi-segment with seconds, regular.
        XCTAssertEqual(rows[2][2], .string("regular"))
        XCTAssertEqual(rows[2][6], .string("09:00–10:30:20; 11:00:05–12:15; 13:00–14:00"))
        XCTAssertEqual(rows[2][4], .date(Fixtures.date(2026, 3, 11, 14, 0)))
        // Midnight crossing block.
        XCTAssertEqual(rows[3][6], .string("23:00–00:30"))
        // Paused: closed segment, no Stopped.
        XCTAssertEqual(rows[4][4], .empty)
        XCTAssertEqual(rows[4][6], .string("18:00–18:45"))
        // Running: open segment ends with a dash; active duration counted to now.
        XCTAssertEqual(rows[5][4], .empty)
        XCTAssertEqual(rows[5][6], .string("20:00–"))
        XCTAssertEqual(rows[5][5], .string("1:00"))
    }

    func testTimeOffSheetHoursMinutes() {
        let rows = Fixtures.workbook().sheets[4].rows
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1][1], .dateOnly(Fixtures.day(2026, 3, 12).start(in: cal)))
        XCTAssertEqual(rows[1][2], .string("PTO"))
        XCTAssertEqual(rows[1][3], .integer(8))
        XCTAssertEqual(rows[1][4], .integer(0))
        XCTAssertEqual(rows[2][2], .string("Flex (from bank)"))
        XCTAssertEqual(rows[3][2], .string("Comp"))
        XCTAssertEqual(rows[3][3], .integer(1))
        XCTAssertEqual(rows[3][4], .integer(30))
        XCTAssertEqual(rows[3][5], .string("half"))
        // Odd seconds survive as fractional minutes.
        XCTAssertEqual(rows[4][3], .integer(2))
        XCTAssertCell(rows[4][4], .number(15.5))
    }

    func testHolidaysLocationsAdjustmentsEvents() {
        let wb = Fixtures.workbook()
        let holidays = wb.sheets[5].rows
        XCTAssertEqual(holidays.count, 3)
        XCTAssertEqual(holidays[1][1], .dateOnly(Fixtures.day(2026, 11, 26).start(in: cal)))
        XCTAssertEqual(holidays[1][2], .string("Thanksgiving"))

        let locations = wb.sheets[6].rows
        XCTAssertEqual(locations.count, 3)
        XCTAssertEqual(locations[1].texts[0], Fixtures.plantA.uuidString)
        XCTAssertEqual(locations[1][1], .string("Plant A"))
        XCTAssertCell(locations[1][2], .number(40.7128))
        XCTAssertCell(locations[1][3], .number(-74.006))
        XCTAssertCell(locations[1][4], .number(300))
        XCTAssertEqual(locations[1][5], .bool(true))

        let adjustments = wb.sheets[9].rows
        XCTAssertEqual(adjustments.count, 3)
        XCTAssertEqual(adjustments[1][2], .integer(5400))
        XCTAssertCell(adjustments[1][3], .number(1.5))
        XCTAssertEqual(adjustments[1][4], .string("carry-over"))
        XCTAssertEqual(adjustments[2][2], .integer(-2700))

        let events = wb.sheets[10].rows
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[1][1], .string("Plant A"))
        XCTAssertEqual(events[1][2], .string("enter"))
        XCTAssertEqual(events[1][3], .date(Fixtures.date(2026, 3, 8, 6, 55)))
        XCTAssertEqual(events[1][4], .string("geofence"))
        XCTAssertEqual(events[3][1], .string("Plant B"))
        XCTAssertEqual(events[3][4], .string("manual"))
    }

    func testScheduleSheetHasOneRowPerVersionAndWeekday() {
        let rows = Fixtures.workbook().sheets[7].rows
        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(rows[1][0], .dateOnly(Fixtures.day(2026, 1, 4).start(in: cal)))
        XCTAssertEqual(rows[1][1], .string("Sunday"))
        XCTAssertEqual(rows[1][2], .bool(false))
        XCTAssertEqual(rows[2][1], .string("Monday"))
        XCTAssertEqual(rows[2][2], .bool(true))
        XCTAssertEqual(rows[2][3], .string("07:00"))
        XCTAssertEqual(rows[2][4], .string("15:30"))
        XCTAssertEqual(rows[2][5], .integer(0))
        XCTAssertEqual(rows[2].texts[6], Fixtures.scheduleV1.uuidString)
        XCTAssertEqual(rows[9][1], .string("Monday"))
        XCTAssertEqual(rows[9][3], .string("06:30"))
        XCTAssertEqual(rows[9][5], .integer(30))
        XCTAssertEqual(rows[9].texts[6], Fixtures.scheduleV2.uuidString)
        XCTAssertEqual(rows[13][1], .string("Friday"))
        XCTAssertEqual(rows[13][2], .bool(false))
    }

    func testOverridesSheet() {
        let rows = Fixtures.workbook().sheets[8].rows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[1][2], .string("dayOff"))
        XCTAssertEqual(rows[1][3], .empty)
        XCTAssertEqual(rows[1][8], .string("moving"))
        XCTAssertEqual(rows[2][2], .string("schedule"))
        XCTAssertEqual(rows[2][3], .string("08:00"))
        XCTAssertEqual(rows[2][4], .string("16:30"))
        XCTAssertEqual(rows[2][5], .integer(30))
        XCTAssertEqual(rows[2][6], .bool(true))
        XCTAssertEqual(rows[2][7], .bool(false))
        XCTAssertEqual(rows[3][2], .string("none"))
        XCTAssertEqual(rows[3][7], .bool(true))
    }

    func testSettingsSheetKeys() {
        let store = Fixtures.store()
        let rows = Fixtures.workbook(store: store).sheets[11].rows
        let keys = rows.dropFirst().map { $0.texts[0] }
        let byKey = Dictionary(uniqueKeysWithValues: rows.dropFirst().map { ($0.texts[0], $0[1]) })
        for key in ExportBuilder.settingsKeys { XCTAssertTrue(keys.contains(key), key) }
        XCTAssertTrue(keys.contains("schemaVersion"))
        XCTAssertEqual(byKey["graceMinutes"], .integer(7))
        XCTAssertEqual(byKey["weekStartsOn"], .string("Sunday"))
        XCTAssertEqual(byKey["bankStartingSeconds"], .integer(3600))
        XCTAssertEqual(byKey["bankStartingAsOf"], .dateOnly(Fixtures.day(2026, 1, 1).start(in: cal)))
        XCTAssertEqual(byKey["manualCategories"], .string("[\"Home work\",\"After hours\",\"Travel\",\"Other\",\"Call\"]"))
        XCTAssertEqual(byKey["defaultManualCategory"], .string("After hours"))
        XCTAssertEqual(byKey["exportEmail"], .string("me@example.com"))
        XCTAssertEqual(byKey["timeZoneIdentifier"], .string("America/New_York"))
        XCTAssertEqual(byKey["onboardingCompleted"], .bool(true))
        XCTAssertEqual(byKey["schemaVersion"], .integer(Store.currentSchemaVersion))
        for b in store.leaveBalances {
            XCTAssertNotNil(byKey["leave." + b.typeID.uuidString], b.typeID.uuidString)
        }
        for t in store.timeOffTypes {
            XCTAssertNotNil(byKey["timeOffType." + t.id.uuidString], t.name)
        }
        XCTAssertEqual(rows.count, 1 + ExportBuilder.settingsKeys.count + 1 + store.leaveBalances.count + store.timeOffTypes.count)
    }

    func testDateRangeLimitsFactSheetsButNotReferenceSheets() {
        let wb = ExportBuilder.workbook(store: Fixtures.store(), dayResults: [], from: Fixtures.day(2026, 3, 1), through: Fixtures.day(2026, 3, 31), now: Fixtures.now)
        XCTAssertEqual(wb.sheets[2].rows.count, 5)      // 4 March presence sessions
        XCTAssertEqual(wb.sheets[3].rows.count, 3)      // 2 March manual sessions
        XCTAssertEqual(wb.sheets[4].rows.count, 3)      // PTO + flex in March
        XCTAssertEqual(wb.sheets[5].rows.count, 1)      // no March holidays
        XCTAssertEqual(wb.sheets[6].rows.count, 3)      // locations always complete
        XCTAssertEqual(wb.sheets[7].rows.count, 15)     // schedules always complete
        XCTAssertEqual(wb.sheets[8].rows.count, 4)
        XCTAssertEqual(wb.sheets[9].rows.count, 2)      // only the March correction
        XCTAssertEqual(wb.sheets[10].rows.count, 4)
    }

    func testMidnightCrossingSessionBelongsToBothDays() {
        let wb1 = ExportBuilder.workbook(store: Fixtures.store(), dayResults: [], from: Fixtures.day(2026, 11, 1), through: Fixtures.day(2026, 11, 1), now: Fixtures.now)
        let wb2 = ExportBuilder.workbook(store: Fixtures.store(), dayResults: [], from: Fixtures.day(2026, 11, 2), through: Fixtures.day(2026, 11, 2), now: Fixtures.now)
        XCTAssertEqual(wb1.sheets[2].rows.dropFirst().map { $0.texts[0] }, [Fixtures.uuid(24).uuidString])
        XCTAssertEqual(wb2.sheets[2].rows.dropFirst().map { $0.texts[0] }, [Fixtures.uuid(24).uuidString])
    }

    func testCSVTemplateMatchesSpec() {
        let text = ExportBuilder.csvTemplate()
        XCTAssertTrue(text.hasSuffix("\r\n"))
        XCTAssertEqual(text.components(separatedBy: "\r\n"), [
            "record,date,start,end,location,category,type,hours,minutes,name,note,id",
            "presence,2026-10-14,07:02,17:42,Plant A,,,,,,,",
            "manual,2026-10-14,19:00,20:15,,After hours,,,,,emails,",
            "timeoff,2026-10-20,,,,,PTO,8,0,,,",
            "holiday,2026-11-26,,,,,,,,Thanksgiving,,",
            "adjustment,2026-10-01,,,,,,1,30,,carry-over from old sheet,",
            "",
        ])
    }

    func testJSONBackupIsStoreCodecOutput() throws {
        let store = Fixtures.store()
        let data = try ExportBuilder.json(store: store)
        XCTAssertEqual(try StoreCodec.decode(data), store)
    }
}
