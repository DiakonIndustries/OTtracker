import XCTest
import OTModels
import OTCSV
@testable import OTExchange

/// The CSV import template (SPEC §6.2, docs/IMPORT_TEMPLATE.md): every documented tolerance and every
/// documented rejection.
final class CSVTemplateTests: XCTestCase {
    let store = Store(settings: RichFixture.settings)
    let header = "record,date,start,end,location,category,type,hours,minutes,name,note,id"
    func d(_ y: Int, _ m: Int, _ dd: Int, _ h: Int = 0, _ min: Int = 0) -> Date { RichFixture.date(y, m, dd, h, min) }

    // MARK: The template itself

    func testTemplateParsesBackToTheFiveTypedRows() throws {
        let text = ExportBuilder.csvTemplate()
        XCTAssertEqual(CSV.parse(text).count, 6)
        XCTAssertEqual(CSV.parse(text)[0], ExportBuilder.csvTemplateHeader)
        XCTAssertEqual(ImportParser.detectFormat(data: Data(text.utf8), filename: "template.csv"), .csv)
        let b = try ImportParser.parse(data: Data(text.utf8), filename: "template.csv", store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.presence[0].locationName, "Plant A")
        XCTAssertEqual(b.presence[0].enteredAt, d(2026, 10, 14, 7, 2))
        XCTAssertEqual(b.presence[0].exitedAt, d(2026, 10, 14, 17, 42))
        XCTAssertEqual(b.presence[0].source, .imported)
        XCTAssertNil(b.presence[0].id)
        XCTAssertEqual(b.manual.count, 1)
        XCTAssertEqual(b.manual[0].category, "After hours")
        XCTAssertEqual(b.manual[0].countsAs, .extra)
        XCTAssertEqual(b.manual[0].note, "emails")
        XCTAssertEqual(b.manual[0].state, .stopped)
        XCTAssertEqual(b.manual[0].segments, [ManualSegment(start: d(2026, 10, 14, 19, 0), end: d(2026, 10, 14, 20, 15))])
        XCTAssertEqual(b.timeOff, [ImportBundle.TimeOffRow(day: RichFixture.day(2026, 10, 20), typeName: "PTO", seconds: 8 * 3600)])
        XCTAssertEqual(b.holidays.count, 1)
        XCTAssertEqual(b.holidays[0].day, RichFixture.day(2026, 11, 26))
        XCTAssertEqual(b.holidays[0].name, "Thanksgiving")
        XCTAssertEqual(b.adjustments.count, 1)
        XCTAssertEqual(b.adjustments[0].day, RichFixture.day(2026, 10, 1))
        XCTAssertEqual(b.adjustments[0].seconds, 5400)
        XCTAssertEqual(b.adjustments[0].reason, "carry-over from old sheet")
        XCTAssertTrue(b.locations.isEmpty && b.overrides.isEmpty && b.schedules.isEmpty && b.events.isEmpty)
        XCTAssertNil(b.settings)
        XCTAssertNil(b.fullStore)

        // Applying it yields the facts the template describes, once.
        var s = store
        let plan = Importer.plan(store: s, bundle: b, mode: .merge)
        XCTAssertEqual(plan.totalNew, 6)                                        // five rows + the Plant A placeholder
        Importer.apply(plan: plan, mode: .merge, to: &s)
        XCTAssertEqual(s.presence.count, 1)
        XCTAssertEqual(s.manual.count, 1)
        XCTAssertEqual(s.timeOff.first?.typeID, TimeOffType.ptoID)
        XCTAssertEqual(s.holidays.count, 1)
        XCTAssertEqual(s.adjustments.count, 1)
        XCTAssertEqual(s.locations.map { $0.name }, ["Plant A"])
    }

    // MARK: Tolerances from docs/IMPORT_TEMPLATE.md

    func testSlashDatesAndTwelveHourTimes() {
        let text = """
        \(header)
        presence,10/14/2026,7:02 am,5:42 pm,Plant A,,,,,,,
        presence,10/15/2026,7:02AM,5:42PM,Plant A,,,,,,,
        manual,1/5/2026,12:00 am,12:30 pm,,Call,,,,,,
        manual,2026-01-06,12:15 PM,11:59 PM,,Call,,,,,,
        manual,2026-01-07,7am,3 pm,,Call,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.map { $0.enteredAt }, [d(2026, 10, 14, 7, 2), d(2026, 10, 15, 7, 2)])
        XCTAssertEqual(b.presence.map { $0.exitedAt }, [d(2026, 10, 14, 17, 42), d(2026, 10, 15, 17, 42)])
        XCTAssertEqual(b.manual[0].segments, [ManualSegment(start: d(2026, 1, 5, 0, 0), end: d(2026, 1, 5, 12, 30))])
        XCTAssertEqual(b.manual[1].segments, [ManualSegment(start: d(2026, 1, 6, 12, 15), end: d(2026, 1, 6, 23, 59))])
        XCTAssertEqual(b.manual[2].segments, [ManualSegment(start: d(2026, 1, 7, 7, 0), end: d(2026, 1, 7, 15, 0))])
    }

    func testRecordKindsAreCaseInsensitiveAndShorthandsImplyTheType() {
        let text = """
        \(header)
        PRESENCE,2026-10-14,07:00,15:00,Plant A,,,,,,,
        Manual,2026-10-14,19:00,20:00,,,,,,,,
        TimeOff,2026-10-20,,,,,Comp,8,,,,
        PTO,2026-10-21,,,,,,4,,,half day,
        Personal,2026-10-22,,,,,,,30,,,
        FLEX,2026-10-23,,,,,,8,,,,
        Holiday,2026-11-26,,,,,,,,,,
        Adjustment,2026-10-01,,,,,,1,30,,carry,
        pto,2026-10-24,,,,,Vacation,1,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.manual.count, 1)
        XCTAssertEqual(b.manual[0].category, store.settings.defaultManualCategory)
        XCTAssertEqual(b.timeOff.map { $0.typeName }, ["Comp", "PTO", "Personal", "Flex (from bank)", "Vacation"])
        XCTAssertEqual(b.timeOff.map { $0.seconds }, [28800, 14400, 1800, 28800, 3600])
        XCTAssertEqual(b.timeOff[1].note, "half day")
        XCTAssertEqual(b.holidays.map { $0.name }, ["Holiday"])
        XCTAssertEqual(b.adjustments.map { $0.seconds }, [5400])

        var s = store
        Importer.apply(plan: Importer.plan(store: s, bundle: b, mode: .merge), mode: .merge, to: &s)
        XCTAssertEqual(s.timeOff.map { $0.typeID }.prefix(4).map { $0 },
                       [s.timeOffType(named: "Comp")!.id, TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID])
        XCTAssertEqual(s.timeOffType(named: "Comp")?.kind, .other)
        XCTAssertEqual(s.timeOffType(named: "Vacation")?.kind, .other)
    }

    func testEndBeforeStartWrapsToTheNextDayAndEqualTimesAreRejected() {
        let text = """
        \(header)
        presence,2026-11-01,22:00,01:30,Plant A,,,,,,night shift,
        manual,2026-11-01,23:00,00:30,,Other,,,,,,
        presence,2026-10-14,07:00,07:00,Plant A,,,,,,,
        manual,2026-10-14,23:59,00:00,,Other,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid.map { $0.line }, [4])
        XCTAssertTrue(b.invalid[0].reason.contains("end time must differ"))
        XCTAssertEqual(b.presence[0].enteredAt, d(2026, 11, 1, 22, 0))
        XCTAssertEqual(b.presence[0].exitedAt, d(2026, 11, 2, 1, 30))
        XCTAssertEqual(b.presence[0].note, "night shift")
        XCTAssertEqual(b.manual[0].segments.first?.end, d(2026, 11, 2, 0, 30))
        XCTAssertEqual(b.manual[1].segments.first?.end, d(2026, 10, 15, 0, 0))   // 23:59 → 00:00 is one minute
    }

    func testDecimalHoursMinutesOnlyAndNegativeAdjustments() {
        let text = """
        \(header)
        timeoff,2026-10-20,,,,,PTO,7.5,,,,
        pto,2026-10-21,,,,,,,90,,,
        pto,2026-10-22,,,,,,1.5,30,,,
        timeoff,2026-10-23,,,,,PTO,,0.5,,,
        adjustment,2026-10-01,,,,,,-1,30,,gave back,
        adjustment,2026-10-02,,,,,,,-15,,fix,
        adjustment,2026-10-03,,,,,,-0.5,,,fix,
        adjustment,2026-10-04,,,,,,0.25,,,fix,
        adjustment,2026-10-05,,,,,,-1,-30,,both signed,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.timeOff.map { $0.seconds }, [27000, 5400, 7200, 30])
        XCTAssertEqual(b.adjustments.map { $0.seconds }, [-5400, -900, -1800, 900, -5400])
        XCTAssertEqual(b.adjustments[0].reason, "gave back")
    }

    func testColumnsInAnyOrderExtraColumnsBlankRowsAndWhitespace() {
        let text = """
        comment,id,note,name,minutes,hours,type,category,location,end,start,date,record
        ignored,,, , ,,,, Plant A , 17:42 , 07:02 , 2026-10-14 , presence

        ,,,,  ,  8  ,  pto  ,,,,, 2026-10-20 , TIMEOFF
        ,,,,,,,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.presence[0].locationName, "Plant A")
        XCTAssertEqual(b.presence[0].enteredAt, d(2026, 10, 14, 7, 2))
        XCTAssertEqual(b.timeOff, [ImportBundle.TimeOffRow(day: RichFixture.day(2026, 10, 20), typeName: "pto", seconds: 28800)])
    }

    func testBOMAndCRLF() throws {
        let body = ExportBuilder.csvTemplate()                    // already CRLF
        XCTAssertTrue(body.contains("\r\n"))
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "template.csv"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "noext"), .csv)
        let b = try ImportParser.parse(data: data, filename: "template.csv", store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count + b.manual.count + b.timeOff.count + b.holidays.count + b.adjustments.count, 5)
        XCTAssertEqual(b.presence[0].locationName, "Plant A")      // BOM did not leak into the first header key
    }

    func testHeaderOnlyFilesGiveAnEmptyBundleWithoutComplaint() throws {
        for text in [header, header + "\n", header + "\r\n", "\u{FEFF}" + header + "\r\n\r\n", "date,name\n", "Date, Name\r\n"] {
            let b = try ImportParser.parse(data: Data(text.utf8), filename: "h.csv", store: store)
            XCTAssertTrue(b.isEmpty, text)
            XCTAssertEqual(b.invalid, [], text)
            let plan = Importer.plan(store: store, bundle: b, mode: .merge)
            XCTAssertEqual(plan.totalNew + plan.totalUpdated + plan.totalUnchanged, 0)
        }
    }

    func testQuotedCommasQuotesAndLineBreaksInNotesAndNames() {
        let text = "\(header)\r\n"
            + "presence,2026-10-14,07:02,17:42,\"Plant A, East\",,,,,,\"arrived, left\",\r\n"
            + "adjustment,2026-10-01,,,,,,1,30,,\"carry-over, from \"\"old\"\" sheet\",\r\n"
            + "holiday,2026-11-26,,,,,,,,\"Thanksgiving, Day\",,\r\n"
            + "manual,2026-10-14,19:00,20:15,,After hours,,,,,\"line one\r\nline two\",\r\n"
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence[0].locationName, "Plant A, East")
        XCTAssertEqual(b.presence[0].note, "arrived, left")
        XCTAssertEqual(b.adjustments[0].reason, "carry-over, from \"old\" sheet")
        XCTAssertEqual(b.holidays[0].name, "Thanksgiving, Day")
        XCTAssertEqual(b.manual[0].note, "line one\r\nline two")
    }

    func testIDsAreUsedWhenPresentAndRejectedWhenMalformed() {
        let id = RichFixture.uuid(77)
        let text = """
        \(header)
        presence,2026-10-14,07:00,15:00,Plant A,,,,,,,\(id.uuidString.lowercased())
        holiday,2026-11-26,,,,,,,,X,,\(id.uuidString)
        holiday,2026-11-27,,,,,,,,Y,,not-a-uuid
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.presence[0].id, id)
        XCTAssertEqual(b.holidays.map { $0.id }, [id])
        XCTAssertEqual(b.invalid.map { $0.line }, [4])
        XCTAssertTrue(b.invalid[0].reason.contains("bad id"))
    }

    // MARK: Rejections

    func testEveryMalformedRowIsReportedWithItsLineNumberAndAHumanReason() {
        let rows = [
            ("bogus,2026-10-14,07:00,15:00,Plant A,,,,,,,", "unknown record kind 'bogus'"),
            (",2026-10-14,07:00,15:00,Plant A,,,,,,,", "missing record kind"),
            ("presence,,07:00,15:00,Plant A,,,,,,,", "missing date"),
            ("presence,14.10.2026,07:00,15:00,Plant A,,,,,,,", "bad date '14.10.2026'"),
            ("presence,2026-13-01,07:00,15:00,Plant A,,,,,,,", "bad date"),
            ("presence,2026-02-30,07:00,15:00,Plant A,,,,,,,", "bad date"),
            ("presence,2026-10-14,,15:00,Plant A,,,,,,,", "missing start time"),
            ("presence,2026-10-14,07:00,,Plant A,,,,,,,", "missing end time"),
            ("presence,2026-10-14,7h,15:00,Plant A,,,,,,,", "bad start time '7h'"),
            ("presence,2026-10-14,07:00,25:00,Plant A,,,,,,,", "bad end time '25:00'"),
            ("presence,2026-10-14,07:60,15:00,Plant A,,,,,,,", "bad start time"),
            ("presence,2026-10-14,13:00 pm,15:00,Plant A,,,,,,,", "bad start time"),
            ("presence,2026-10-14,07:00,07:00,Plant A,,,,,,,", "end time must differ from start time"),
            ("presence,2026-10-14,07:00,15:00,,,,,,,,", "missing location"),
            ("manual,2026-10-14,,20:00,,Call,,,,,,", "missing start time"),
            ("manual,2026-10-14,19:00,20:00,,Call,bogus,,,,,", "manual type must be 'extra', 'regular' or empty"),
            ("timeoff,2026-10-14,,,,,,8,0,,,", "missing type"),
            ("timeoff,2026-10-14,,,,,PTO,,,,,", "missing hours/minutes"),
            ("timeoff,2026-10-14,,,,,PTO,eight,,,,", "missing hours/minutes"),
            ("timeoff,2026-10-14,,,,,PTO,0,0,,,", "hours/minutes must be greater than 0"),
            ("pto,2026-10-14,,,,,,-1,,,,", "hours/minutes must be greater than 0"),
            ("adjustment,2026-10-14,,,,,,,,,,", "missing hours/minutes"),
            ("adjustment,2026-10-14,,,,,,0,0,,zero,", "adjustment must not be zero"),
            ("adjustment,2026-10-14,,,,,,1.5h,,,,", "missing hours/minutes"),
            ("holiday,2026-10-14,,,,,,,,X,,not-a-uuid", "bad id 'not-a-uuid'"),
            ("holiday,10/14/26,,,,,,,,X,,", "bad date"),
        ]
        let text = ([header] + rows.map { $0.0 } + ["presence,2026-10-14,07:00,15:00,Plant A,,,,,,,"]).joined(separator: "\n")
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid.map { $0.line }, Array(2..<(2 + rows.count)))
        for (i, row) in rows.enumerated() {
            let r = b.invalid[i]
            XCTAssertTrue(r.reason.hasPrefix("line \(r.line): "), r.reason)
            XCTAssertTrue(r.reason.contains(row.1), "line \(r.line): expected '\(row.1)' in '\(r.reason)'")
            XCTAssertFalse(r.reason.contains("nil"), r.reason)
            XCTAssertFalse(r.reason.contains("Optional"), r.reason)
        }
        // The valid last row still imports.
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.manual.count, 0)
        XCTAssertEqual(b.timeOff.count, 0)
        XCTAssertEqual(b.holidays.count, 0)
        XCTAssertEqual(b.adjustments.count, 0)
    }

    func testInvalidRowsArePresentOnThePlan() {
        let text = "\(header)\nbogus,2026-10-14,,,,,,,,,,\npresence,2026-10-14,07:00,15:00,Plant A,,,,,,,\n"
        let b = ImportParser.parse(csvText: text, store: store)
        let plan = Importer.plan(store: store, bundle: b, mode: .merge)
        XCTAssertEqual(plan.invalid, b.invalid)
        XCTAssertEqual(plan.invalid.map { $0.line }, [2])
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: 1))
    }

    func testMissingRecordColumnIsOneInvalidRowOnLineOne() {
        let b = ImportParser.parse(csvText: "Date,Start,End\n2026-10-14,07:00,15:00\n", store: store)
        XCTAssertEqual(b.invalid.map { $0.line }, [1])
        XCTAssertTrue(b.invalid[0].reason.contains("record"))
        XCTAssertTrue(b.isEmpty)
    }

    // MARK: Holidays-only file (SPEC §6.2)

    func testHolidaysOnlyCSVWithCaseAndSpacingDifferencesInTheHeader() throws {
        for head in ["date,name", "Date, Name", " DATE , NAME ", "\u{FEFF}Date,Name", "Date,Name,"] {
            let text = head + "\r\n2026-11-26,Thanksgiving\r\n12/25/2026,Christmas\r\n2027-01-01,\r\n\r\nnope,Bad\r\n"
            let data = Data(text.utf8)
            XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "holidays.csv"), .holidaysCSV, head)
            XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "holidays"), .holidaysCSV, head)
            let b = try ImportParser.parse(data: data, filename: "Holidays.CSV", store: store)
            XCTAssertEqual(b.holidays.map { $0.name }, ["Thanksgiving", "Christmas", "Holiday"], head)
            XCTAssertEqual(b.holidays.map { $0.day }, [RichFixture.day(2026, 11, 26), RichFixture.day(2026, 12, 25), RichFixture.day(2027, 1, 1)], head)
            XCTAssertEqual(b.invalid.map { $0.line }, [6], head)
            XCTAssertTrue(b.invalid[0].reason.contains("bad date 'nope'"), head)
            XCTAssertTrue(b.presence.isEmpty && b.timeOff.isEmpty && b.adjustments.isEmpty)
            let plan = Importer.plan(store: store, bundle: b, mode: .merge)
            XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(new: 3))
            XCTAssertEqual(Set(plan.counts.keys), Set(ImportPlan.countKeys))
        }
    }

    func testHolidaysOnlyColumnsMayBeSwapped() throws {
        let data = Data("Name,Date\r\nThanksgiving,2026-11-26\r\n,2026-12-25\r\n".utf8)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "h.csv"), .holidaysCSV)
        let b = try ImportParser.parse(data: data, filename: "h.csv", store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.holidays.map { $0.name }, ["Thanksgiving", "Holiday"])
        XCTAssertEqual(b.holidays.map { $0.day }, [RichFixture.day(2026, 11, 26), RichFixture.day(2026, 12, 25)])
        // Three named columns is the full template's business, not a holidays file.
        XCTAssertEqual(ImportParser.detectFormat(data: Data("date,name,note\n".utf8), filename: "h.csv"), .csv)
    }

    func testHolidaysOnlyImportMergesByDayAndIsIdempotent() throws {
        var s = store
        s.holidays = [Holiday(id: RichFixture.uuid(1), day: RichFixture.day(2026, 11, 26), name: "Turkey")]
        let data = Data("date,name\n2026-11-26,Thanksgiving\n2026-12-25,Christmas\n".utf8)
        let plan = Importer.plan(store: s, bundle: try ImportParser.parse(data: data, filename: "h.csv", store: s), mode: .merge)
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(new: 1, updated: 1))
        Importer.apply(plan: plan, mode: .merge, to: &s)
        XCTAssertEqual(s.holidays.map { $0.name }, ["Thanksgiving", "Christmas"])
        XCTAssertEqual(s.holidays[0].id, RichFixture.uuid(1))
        let again = Importer.plan(store: s, bundle: try ImportParser.parse(data: data, filename: "h.csv", store: s), mode: .merge)
        XCTAssertEqual(again.counts["holidays"], ImportPlan.Counts(unchanged: 2))
    }

    // MARK: Performance

    func testTenThousandRowsParseInUnderTwoSeconds() {
        var lines = [header]
        lines.reserveCapacity(10_001)
        for i in 0..<10_000 {
            let day = RichFixture.day(2026, 1, 1).adding(days: i % 300, calendar: store.calendar).isoString
            switch i % 5 {
            case 0: lines.append("presence,\(day),07:0\(i % 10),15:3\(i % 10),Plant \(i % 3),,,,,,,")
            case 1: lines.append("manual,\(day),19:00,20:15,,After hours,,,,,emails \(i),")
            case 2: lines.append("pto,\(day),,,,,,\(1 + i % 8),\(i % 60),,,")
            case 3: lines.append("holiday,\(day),,,,,,,,Day \(i),,")
            default: lines.append("adjustment,\(day),,,,,,\(i % 2 == 0 ? "-" : "")1,\(i % 60),,reason \(i),")
            }
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        let started = Date()
        let b = ImportParser.parse(csvText: text, store: store)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count + b.manual.count + b.timeOff.count + b.holidays.count + b.adjustments.count, 10_000)
        XCTAssertLessThan(elapsed, 2.0, "parsing 10 000 rows took \(elapsed) s")
    }
}
