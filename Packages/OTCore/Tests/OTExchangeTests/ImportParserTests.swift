import XCTest
import OTModels
import OTXLSX
import OTCSV
@testable import OTExchange

final class ImportParserFormatTests: XCTestCase {
    func testDetectByExtension() {
        XCTAssertEqual(ImportParser.detectFormat(data: Data("x".utf8), filename: "Export.XLSX"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("x".utf8), filename: "backup.json"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("record,date\n".utf8), filename: "import.csv"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("Date,Name\r\n2026-11-26,X\r\n".utf8), filename: "holidays.CSV"), .holidaysCSV)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("record,date\n".utf8), filename: "/a/b/import.csv"), .csv)
    }

    func testDetectBySniffing() {
        XCTAssertEqual(ImportParser.detectFormat(data: Data([0x50, 0x4B, 0x03, 0x04, 0x00]), filename: "whatever"), .xlsx)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("  \n{\"schemaVersion\":1}".utf8), filename: "noext"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8), filename: ""), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("record,date,start\npresence,2026-10-14,07:00\n".utf8), filename: "file.txt"), .csv)
        XCTAssertEqual(ImportParser.detectFormat(data: Data(" date , name \n".utf8), filename: "file.txt"), .holidaysCSV)
        XCTAssertEqual(ImportParser.detectFormat(data: Data("\u{FEFF}date,name\n".utf8), filename: "x"), .holidaysCSV)
        XCTAssertNil(ImportParser.detectFormat(data: Data(), filename: "empty"))
    }

    func testParseDataDispatchesAndThrows() throws {
        let store = Store(settings: Fixtures.settings)
        let bundle = try ImportParser.parse(data: Data(ExportBuilder.csvTemplate().utf8), filename: "template.csv", store: store)
        XCTAssertEqual(bundle.presence.count, 1)
        let holidays = try ImportParser.parse(data: Data("date,name\n2026-11-26,Thanksgiving\n".utf8), filename: "h.csv", store: store)
        XCTAssertEqual(holidays.holidays.map { $0.name }, ["Thanksgiving"])
        XCTAssertThrowsError(try ImportParser.parse(data: Data(), filename: "", store: store)) { XCTAssertEqual($0 as? ImportError, .unrecognizedFormat) }
        XCTAssertThrowsError(try ImportParser.parse(data: Data("{ nope".utf8), filename: "bad.json", store: store)) {
            guard case .unreadable = $0 as? ImportError else { return XCTFail("expected unreadable, got \($0)") }
        }
    }
}

final class ImportParserCSVTests: XCTestCase {
    let store = Store(settings: Fixtures.settings)
    let header = "record,date,start,end,location,category,type,hours,minutes,name,note,id"

    func testTemplateParsesToTheFiveExampleRows() {
        let b = ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence, [ImportBundle.PresenceRow(id: nil, locationName: "Plant A", enteredAt: Fixtures.date(2026, 10, 14, 7, 2),
                                                             exitedAt: Fixtures.date(2026, 10, 14, 17, 42), source: .imported, followingGapIsWork: nil, note: "")])
        XCTAssertEqual(b.manual.count, 1)
        let m = b.manual[0]
        XCTAssertEqual(m.category, "After hours")
        XCTAssertEqual(m.note, "emails")
        XCTAssertEqual(m.countsAs, .extra)
        XCTAssertTrue(m.isStopped)
        XCTAssertEqual(m.segments, [ManualSegment(start: Fixtures.date(2026, 10, 14, 19, 0), end: Fixtures.date(2026, 10, 14, 20, 15))])
        XCTAssertEqual(m.createdAt, Fixtures.date(2026, 10, 14, 19, 0))
        XCTAssertEqual(b.timeOff, [ImportBundle.TimeOffRow(id: nil, day: Fixtures.day(2026, 10, 20), typeName: "PTO", seconds: 8 * 3600, note: "")])
        XCTAssertEqual(b.holidays.map { ($0.day, $0.name) }.map { "\($0.0) \($0.1)" }, ["2026-11-26 Thanksgiving"])
        XCTAssertEqual(b.adjustments.count, 1)
        XCTAssertEqual(b.adjustments[0].day, Fixtures.day(2026, 10, 1))
        XCTAssertEqual(b.adjustments[0].seconds, 5400)
        XCTAssertEqual(b.adjustments[0].reason, "carry-over from old sheet")
        XCTAssertEqual(b.locations, [])
        XCTAssertNil(b.settings)
        XCTAssertNil(b.fullStore)
    }

    func testShorthandRowsMeanTimeOffOfThatType() {
        let text = """
        \(header)
        pto,2026-10-21,,,,,,4,0,,,
        personal,2026-10-22,,,,,,0,30,,,
        flex,2026-10-23,,,,,,8,,,,
        pto,2026-10-24,,,,,Vacation,1,,,,
        timeoff,2026-10-25,,,,,Comp,,45,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.timeOff.map { $0.typeName }, ["PTO", "Personal", "Flex (from bank)", "Vacation", "Comp"])
        XCTAssertEqual(b.timeOff.map { $0.seconds }, [14400, 1800, 28800, 3600, 2700])
    }

    func testManualDefaultsAndTypeColumn() {
        let text = """
        \(header)
        manual,2026-10-14,09:00,12:00,,,regular,,,,home,
        manual,2026-10-14,13:00,14:00,,Travel,,,,,,
        manual,2026-10-14,15:00,16:00,,Travel,bogus,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.manual.count, 2)
        XCTAssertEqual(b.manual[0].category, store.settings.defaultManualCategory)
        XCTAssertEqual(b.manual[0].countsAs, .regular)
        XCTAssertEqual(b.manual[1].category, "Travel")
        XCTAssertEqual(b.manual[1].countsAs, .extra)
        XCTAssertEqual(b.invalid.map { $0.line }, [4])
    }

    func testEndBeforeStartEndsNextDay() {
        let text = """
        \(header)
        presence,2026-11-01,22:00,01:30,Plant A,,,,,,,
        manual,2026-11-01,23:00,00:30,,Other,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence[0].enteredAt, Fixtures.date(2026, 11, 1, 22, 0))
        XCTAssertEqual(b.presence[0].exitedAt, Fixtures.date(2026, 11, 2, 1, 30))
        XCTAssertEqual(Int(b.presence[0].exitedAt!.timeIntervalSince(b.presence[0].enteredAt)), 12600)
        XCTAssertEqual(b.manual[0].segments.first?.end, Fixtures.date(2026, 11, 2, 0, 30))
    }

    func testTimesAreWallClockAcrossDSTChanges() {
        let text = """
        \(header)
        presence,2026-03-08,01:30,03:30,Plant A,,,,,,,
        presence,2026-11-01,00:30,02:30,Plant A,,,,,,,
        presence,2026-03-08,07:00,15:30,Plant A,,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        let seconds = b.presence.map { Int($0.exitedAt!.timeIntervalSince($0.enteredAt)) }
        XCTAssertEqual(seconds, [3600, 10800, 30600])   // spring forward loses an hour, fall back gains one
        XCTAssertEqual(b.presence[2].enteredAt, Fixtures.date(2026, 3, 8, 7, 0))
    }

    func testInvalidRowsCarryLineNumbersAndReasons() {
        let text = """
        \(header)
        bogus,2026-10-14,07:00,15:00,Plant A,,,,,,,
        presence,,07:00,15:00,Plant A,,,,,,,
        presence,2026-10-14,7h,15:00,Plant A,,,,,,,
        presence,2026-10-14,07:00,15:00,,,,,,,,
        holiday,2026-10-14,,,,,,,,X,,not-a-uuid
        timeoff,2026-10-14,,,,,,8,0,,,
        adjustment,2026-10-14,,,,,,,,,,
        presence,2026-02-30,07:00,15:00,Plant A,,,,,,,
        presence,2026-10-14,07:00,07:00,Plant A,,,,,,,
        timeoff,2026-10-14,,,,,PTO,0,0,,,
        presence,2026-10-14,07:00,15:00,Plant A,,,,,,,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid.map { $0.line }, Array(2...11))
        for row in b.invalid { XCTAssertTrue(row.reason.hasPrefix("line \(row.line): "), row.reason) }
        XCTAssertTrue(b.invalid[0].reason.contains("unknown record kind 'bogus'"))
        XCTAssertTrue(b.invalid[1].reason.contains("missing date"))
        XCTAssertTrue(b.invalid[2].reason.contains("bad start time"))
        XCTAssertTrue(b.invalid[3].reason.contains("missing location"))
        XCTAssertTrue(b.invalid[4].reason.contains("bad id"))
        XCTAssertTrue(b.invalid[5].reason.contains("missing type"))
        XCTAssertTrue(b.invalid[6].reason.contains("hours/minutes"))
        XCTAssertTrue(b.invalid[7].reason.contains("bad date"))
        XCTAssertTrue(b.invalid[8].reason.contains("differ"))
        XCTAssertTrue(b.invalid[9].reason.contains("greater than 0"))
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.holidays.count, 0)
        XCTAssertEqual(b.timeOff.count, 0)
    }

    func testHolidaysOnlyCSV() {
        let b = ImportParser.parse(csvText: "date,name\r\n2026-11-26,Thanksgiving\r\n2026-12-25,\r\nnope,Bad\r\n", store: store)
        XCTAssertEqual(b.holidays.map { $0.name }, ["Thanksgiving", "Holiday"])
        XCTAssertEqual(b.holidays.map { $0.day }, [Fixtures.day(2026, 11, 26), Fixtures.day(2026, 12, 25)])
        XCTAssertEqual(b.invalid.map { $0.line }, [4])
    }

    func testBOMBlankLinesColumnOrderAndIDs() {
        let id = Fixtures.uuid(99)
        let text = "\u{FEFF}date,record,location,start,end,id\r\n\r\n2026-10-14,presence,Plant A,07:00,15:00,\(id.uuidString)\r\n  \r\n"
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 1)
        XCTAssertEqual(b.presence[0].id, id)
        XCTAssertEqual(b.presence[0].locationName, "Plant A")
    }

    func testMissingRecordColumnIsReportedOnLineOne() {
        let b = ImportParser.parse(csvText: "foo,bar\n1,2\n", store: store)
        XCTAssertEqual(b.invalid.count, 1)
        XCTAssertEqual(b.invalid[0].line, 1)
        XCTAssertTrue(b.isEmpty)
        XCTAssertTrue(ImportParser.parse(csvText: "", store: store).isEmpty)
    }

    func testAdjustmentSignAndSlashDates() {
        let text = """
        \(header)
        adjustment,10/01/2026,,,,,,-1,30,,fix,
        adjustment,2026-10-02,,,,,,,-15,,fix2,
        adjustment,2026-10-03,,,,,,0.5,,,fix3,
        """
        let b = ImportParser.parse(csvText: text, store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.adjustments.map { $0.seconds }, [-5400, -900, 1800])
        XCTAssertEqual(b.adjustments[0].day, Fixtures.day(2026, 10, 1))
    }
}

final class ImportParserWorkbookTests: XCTestCase {
    let cal = Fixtures.calendar

    func testExportedWorkbookParsesEverySheet() {
        let store = Fixtures.store()
        let b = ImportParser.parse(workbook: Fixtures.workbook(store: store), store: store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertNil(b.fullStore)

        XCTAssertEqual(b.presence.count, 6)
        XCTAssertEqual(b.presence[0].id, Fixtures.uuid(20))
        XCTAssertEqual(b.presence[0].locationName, "Plant A")
        XCTAssertEqual(b.presence[0].enteredAt, Fixtures.date(2026, 3, 8, 6, 55))
        XCTAssertEqual(b.presence[0].source, .geofence)
        XCTAssertNil(b.presence[0].followingGapIsWork)
        XCTAssertEqual(b.presence[1].enteredAt, Fixtures.date(2026, 3, 9, 7, 0, 30))
        XCTAssertEqual(b.presence[2].followingGapIsWork, false)
        XCTAssertEqual(b.presence[2].note, "dentist")
        XCTAssertEqual(b.presence[3].followingGapIsWork, true)
        XCTAssertEqual(b.presence[3].source, .manual)
        XCTAssertNil(b.presence[5].exitedAt)

        XCTAssertEqual(b.manual.count, 5)
        XCTAssertEqual(b.manual[1].segments, store.manualSession(id: Fixtures.uuid(31))?.segments)
        XCTAssertEqual(b.manual[1].countsAs, .regular)
        XCTAssertTrue(b.manual[1].isStopped)
        XCTAssertEqual(b.manual[3].state, .paused)
        XCTAssertEqual(b.manual[4].state, .running)
        XCTAssertEqual(b.manual[4].segments, [ManualSegment(start: Fixtures.date(2026, 11, 15, 20, 0), end: nil)])

        XCTAssertEqual(b.timeOff.count, 4)
        XCTAssertEqual(b.timeOff[2].typeName, "Comp")
        XCTAssertEqual(b.timeOff[2].seconds, 5400)
        XCTAssertEqual(b.timeOff[3].seconds, 2 * 3600 + 15 * 60 + 30)

        XCTAssertEqual(b.holidays, store.holidays)
        XCTAssertEqual(b.adjustments, store.adjustments)
        XCTAssertEqual(b.locations.map { $0.id }, [Fixtures.plantA, Fixtures.plantB])
        XCTAssertEqual(b.locations[0].latitude, 40.7128)
        XCTAssertEqual(b.locations[0].radiusMeters, 300)
        XCTAssertEqual(b.locations[0].createdAt, Fixtures.date(2026, 3, 8, 6, 55))   // earliest related instant in the file
        XCTAssertEqual(b.overrides, store.overrides)
        XCTAssertEqual(b.schedules.count, 2)
        XCTAssertEqual(b.schedules[0].id, Fixtures.scheduleV1)
        XCTAssertEqual(b.schedules[0].days, store.schedules[0].days)
        XCTAssertEqual(b.schedules[1].days, store.schedules[1].days)
        XCTAssertEqual(b.schedules[1].note, "")   // not carried by the sheet
        XCTAssertEqual(b.events, store.locationEvents)
        XCTAssertEqual(Set(b.timeOffTypes), Set(store.timeOffTypes))
        XCTAssertEqual(Set(b.leaveBalances), Set(store.leaveBalances))
        XCTAssertEqual(b.settings, store.settings)
    }

    func testColumnsMayBeReorderedRenamedOrMissingAndSheetsSkipped() {
        let wb = Workbook(sheets: [
            Fixtures.sheet("presence", ["note", "exited", "location", "entered"], [
                [.string("x"), .date(Fixtures.date(2026, 10, 14, 15, 0)), .string("Plant A"), .date(Fixtures.date(2026, 10, 14, 7, 0))],
                [.empty, .empty, .string("Plant B"), .date(Fixtures.date(2026, 10, 15, 7, 0))],
            ]),
            Fixtures.sheet("TimeOff", ["Type", "Date", "Hours"], [[.string("pto"), .dateOnly(Fixtures.day(2026, 10, 20).start(in: cal)), .integer(4)]]),
            Fixtures.sheet("Unrelated", ["A"], [[.string("1")]]),
        ])
        let b = ImportParser.parse(workbook: wb, store: Store(settings: Fixtures.settings))
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 2)
        XCTAssertEqual(b.presence[0].note, "x")
        XCTAssertEqual(b.presence[0].source, .imported)
        XCTAssertNil(b.presence[0].id)
        XCTAssertNil(b.presence[1].exitedAt)
        XCTAssertEqual(b.timeOff, [ImportBundle.TimeOffRow(day: Fixtures.day(2026, 10, 20), typeName: "pto", seconds: 14400)])
        XCTAssertEqual(b.holidays, [])
        XCTAssertEqual(b.manual, [])
    }

    func testInvalidRowsNameSheetAndRowNumber() {
        let wb = Workbook(sheets: [
            Fixtures.sheet("Presence", ExportBuilder.presenceHeader, [
                [.empty, .empty, .date(Fixtures.now), .empty, .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .string("yesterday"), .empty, .empty, .empty, .empty, .empty],
                [.string("not-a-uuid"), .string("Plant A"), .date(Fixtures.now), .empty, .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .date(Fixtures.now), .date(Fixtures.now.addingTimeInterval(-60)), .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .date(Fixtures.now), .empty, .empty, .string("teleport"), .empty, .empty],
                [.empty, .string("Plant A"), .date(Fixtures.now), .empty, .empty, .empty, .string("maybe"), .empty],
            ]),
            Fixtures.sheet("Events", ExportBuilder.eventsHeader, [
                [.empty, .string("Nowhere"), .string("enter"), .date(Fixtures.now), .empty],
                [.empty, .string("Plant A"), .string("teleport"), .date(Fixtures.now), .empty],
            ]),
            Fixtures.sheet("TimeOff", ExportBuilder.timeOffHeader, [
                [.empty, .dateOnly(Fixtures.now), .string("PTO"), .integer(0), .integer(0), .empty],
            ]),
            Fixtures.sheet("Overrides", ExportBuilder.overridesHeader, [
                [.empty, .dateOnly(Fixtures.now), .string("vacation"), .empty, .empty, .empty, .empty, .empty, .empty],
                [.empty, .dateOnly(Fixtures.now), .string("schedule"), .string("09:00"), .string("08:00"), .empty, .empty, .empty, .empty],
            ]),
            Fixtures.sheet("Schedule", ExportBuilder.scheduleHeader, [
                [.dateOnly(Fixtures.now), .string("Funday"), .bool(true), .string("07:00"), .string("15:00"), .integer(0), .empty],
                [.dateOnly(Fixtures.now), .string("Monday"), .bool(true), .empty, .string("15:00"), .integer(0), .empty],
            ]),
        ])
        let b = ImportParser.parse(workbook: wb, store: Fixtures.store())
        let reasons = b.invalid.map { $0.reason }
        XCTAssertEqual(b.invalid.filter { $0.reason.hasPrefix("Presence") }.map { $0.line }, [2, 3, 4, 5, 6, 7])
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 2: missing location") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 3: missing or bad Entered") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 4: bad ID") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 5: Exited is before Entered") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 6: unknown source") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Presence row 7: Gap After") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Events row 2: unknown location 'Nowhere'") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Events row 3: Kind") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("TimeOff row 2: hours/minutes must be greater than 0") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Overrides row 2: Kind") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Overrides row 3: Start must be before End") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Schedule row 2: bad weekday") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Schedule row 3: a workday needs Start and End") })
        XCTAssertEqual(b.invalid.count, 13)
        XCTAssertTrue(b.isEmpty)
    }

    func testManualSegmentsAreRebuiltFromText() {
        let wb = Workbook(sheets: [
            Fixtures.sheet("Manual", ExportBuilder.manualHeader, [
                [.empty, .string("Home work"), .string("regular"), .date(Fixtures.date(2026, 3, 11, 9, 0)), .date(Fixtures.date(2026, 3, 11, 14, 0)),
                 .empty, .string("09:00–10:30:20; 11:00:05–12:15; 13:00–14:00"), .string("remote")],
                [.empty, .string("Call"), .empty, .date(Fixtures.date(2026, 11, 15, 20, 0)), .empty, .empty, .string("20:00–"), .empty],
                [.empty, .string("Other"), .empty, .date(Fixtures.date(2026, 11, 1, 23, 0)), .date(Fixtures.date(2026, 11, 2, 2, 0)),
                 .empty, .string("23:00-00:30; 01:00-02:00"), .empty],
                [.empty, .string("Travel"), .empty, .date(Fixtures.date(2026, 11, 14, 18, 0)), .date(Fixtures.date(2026, 11, 14, 18, 45, 7)), .empty, .empty, .empty],
                [.empty, .string("Travel"), .empty, .date(Fixtures.date(2026, 11, 14, 18, 0)), .empty, .empty, .string("18:00–18:45"), .empty],
                [.empty, .string("Travel"), .empty, .date(Fixtures.date(2026, 11, 14, 18, 0)), .empty, .empty, .string("garbage"), .empty],
            ]),
        ])
        let b = ImportParser.parse(workbook: wb, store: Store(settings: Fixtures.settings))
        XCTAssertEqual(b.invalid.map { $0.line }, [7])
        XCTAssertEqual(b.manual.count, 5)
        XCTAssertEqual(b.manual[0].segments, [
            ManualSegment(start: Fixtures.date(2026, 3, 11, 9, 0), end: Fixtures.date(2026, 3, 11, 10, 30, 20)),
            ManualSegment(start: Fixtures.date(2026, 3, 11, 11, 0, 5), end: Fixtures.date(2026, 3, 11, 12, 15)),
            ManualSegment(start: Fixtures.date(2026, 3, 11, 13, 0), end: Fixtures.date(2026, 3, 11, 14, 0)),
        ])
        XCTAssertTrue(b.manual[0].isStopped)
        XCTAssertEqual(b.manual[0].countsAs, .regular)
        XCTAssertEqual(b.manual[0].createdAt, Fixtures.date(2026, 3, 11, 9, 0))
        XCTAssertEqual(b.manual[1].state, .running)
        XCTAssertEqual(b.manual[1].segments, [ManualSegment(start: Fixtures.date(2026, 11, 15, 20, 0), end: nil)])
        XCTAssertEqual(b.manual[2].segments, [
            ManualSegment(start: Fixtures.date(2026, 11, 1, 23, 0), end: Fixtures.date(2026, 11, 2, 0, 30)),
            ManualSegment(start: Fixtures.date(2026, 11, 2, 1, 0), end: Fixtures.date(2026, 11, 2, 2, 0)),
        ])
        // No Segments text: one block from Started to Stopped (exact seconds kept).
        XCTAssertEqual(b.manual[3].segments, [ManualSegment(start: Fixtures.date(2026, 11, 14, 18, 0), end: Fixtures.date(2026, 11, 14, 18, 45, 7))])
        XCTAssertTrue(b.manual[3].isStopped)
        // Closed segment without Stopped = paused.
        XCTAssertEqual(b.manual[4].state, .paused)
        XCTAssertEqual(b.manual[4].segments.first?.end, Fixtures.date(2026, 11, 14, 18, 45))
    }

    func testTextDatesAndExcelSerialsAreAccepted() {
        let wb = Workbook(sheets: [
            Fixtures.sheet("Presence", ExportBuilder.presenceHeader, [
                [.empty, .string("Plant A"), .string("2026-10-14 07:02"), .string("2026-10-14T21:42:00Z"), .empty, .empty, .empty, .empty],
                [.empty, .string("Plant A"), .string("2026-10-15T07:00:00-04:00"), .string("10/15/2026 3:30 pm"), .empty, .empty, .empty, .empty],
            ]),
            Fixtures.sheet("Holidays", ExportBuilder.holidaysHeader, [
                [.empty, .string("2026-11-26"), .string("Thanksgiving")],
                [.empty, .number(46352), .string("Serial")],
                [.empty, .string("12/25/2026"), .string("Christmas")],
            ]),
            Fixtures.sheet("Events", ExportBuilder.eventsHeader, [
                [.empty, .string(Fixtures.plantA.uuidString), .string("exit"), .number(46352.5), .string("geofence")],
            ]),
            Fixtures.sheet("Schedule", ExportBuilder.scheduleHeader, [
                [.string("2026-01-04"), .string("2"), .string("yes"), .number(7.0 / 24), .string("3:30 pm"), .string("15"), .empty],
            ]),
        ])
        let b = ImportParser.parse(workbook: wb, store: Store(settings: Fixtures.settings))
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence[0].enteredAt, Fixtures.date(2026, 10, 14, 7, 2))
        XCTAssertEqual(b.presence[0].exitedAt, Fixtures.date(2026, 10, 14, 17, 42))
        XCTAssertEqual(b.presence[1].enteredAt, Fixtures.date(2026, 10, 15, 7, 0))
        XCTAssertEqual(b.presence[1].exitedAt, Fixtures.date(2026, 10, 15, 15, 30))
        XCTAssertEqual(b.holidays.map { $0.day }, [Fixtures.day(2026, 11, 26), Fixtures.day(2026, 11, 26), Fixtures.day(2026, 12, 25)])
        XCTAssertEqual(b.events[0].at, Fixtures.date(2026, 11, 26, 12, 0))
        XCTAssertEqual(b.events[0].locationID, Fixtures.plantA)
        XCTAssertEqual(b.schedules.count, 1)
        XCTAssertEqual(b.schedules[0].effectiveFrom, Fixtures.day(2026, 1, 4))
        XCTAssertEqual(b.schedules[0][.monday], WeekdaySchedule(isWorkday: true, start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 15, minute: 30), unpaidBreakMinutes: 15))
        XCTAssertEqual(b.schedules[0][.tuesday], .off)
    }

    func testSettingsSheetIsTolerantAndReportsBadJSON() {
        let store = Fixtures.store()
        let pto = TimeOffType.ptoID
        let wb = Workbook(sheets: [
            Fixtures.sheet("Settings", ["Key", "Value"], [
                [.string("graceMinutes"), .integer(10)],
                [.string("weekStartsOn"), .string("Monday")],
                [.string("manualCategories"), .string("A; B")],
                [.string("bankStartingAsOf"), .string("2026-02-01")],
                [.string("exportEmail"), .empty],
                [.string("someFutureKey"), .integer(1)],
                [.string("leave.\(pto.uuidString)"), .string(ExchangeFormat.json(LeaveBalanceConfig(typeID: pto, startingSeconds: 7200, asOf: Fixtures.day(2026, 1, 1))))],
                [.string("leave.\(TimeOffType.personalID.uuidString)"), .string("not json")],
                [.string("timeOffType.\(Fixtures.compTypeID.uuidString)"), .string(ExchangeFormat.json(Fixtures.compType))],
                [.string("timeZoneIdentifier"), .string("Mars/Olympus")],
            ]),
        ])
        let b = ImportParser.parse(workbook: wb, store: store)
        XCTAssertEqual(b.invalid.map { $0.line }, [9, 11])
        XCTAssertTrue(b.invalid[0].reason.hasPrefix("Settings row 9: bad leave balance JSON"))
        XCTAssertTrue(b.invalid[1].reason.contains("time zone"))
        let s = b.settings!
        XCTAssertEqual(s.graceMinutes, 10)
        XCTAssertEqual(s.weekStartsOn, .monday)
        XCTAssertEqual(s.manualCategories, ["A", "B"])
        XCTAssertEqual(s.bankStartingAsOf, Fixtures.day(2026, 2, 1))
        XCTAssertNil(s.exportEmail)
        XCTAssertEqual(s.timeZoneIdentifier, "America/New_York")          // untouched by the bad row
        XCTAssertEqual(s.bankStartingSeconds, store.settings.bankStartingSeconds)   // unlisted keys keep the store's value
        XCTAssertEqual(b.leaveBalances, [LeaveBalanceConfig(typeID: pto, startingSeconds: 7200, asOf: Fixtures.day(2026, 1, 1))])
        XCTAssertEqual(b.timeOffTypes, [Fixtures.compType])
    }
}

final class ImportParserJSONTests: XCTestCase {
    func testJSONBackupGivesFullStoreAndFlattenedRows() throws {
        let store = Fixtures.store()
        let b = try ImportParser.parse(json: ExportBuilder.json(store: store))
        XCTAssertEqual(b.fullStore, store)
        XCTAssertEqual(b.invalid, [])
        XCTAssertEqual(b.presence.count, 6)
        XCTAssertEqual(b.presence[0].id, Fixtures.uuid(20))
        XCTAssertEqual(b.presence[0].locationName, "Plant A")
        XCTAssertEqual(b.presence[3].locationName, "Plant B")
        XCTAssertEqual(b.presence[3].source, .manual)
        XCTAssertEqual(b.manual, store.manual)
        XCTAssertEqual(b.timeOff.map { $0.typeName }, ["PTO", "Flex (from bank)", "Comp", "PTO"])
        XCTAssertEqual(b.timeOff.map { $0.id }, store.timeOff.map { $0.id })
        XCTAssertEqual(b.holidays, store.holidays)
        XCTAssertEqual(b.adjustments, store.adjustments)
        XCTAssertEqual(b.locations, store.locations)
        XCTAssertEqual(b.overrides, store.overrides)
        XCTAssertEqual(b.schedules, store.schedules)
        XCTAssertEqual(b.events, store.locationEvents)
        XCTAssertEqual(b.timeOffTypes, store.timeOffTypes)
        XCTAssertEqual(b.leaveBalances, store.leaveBalances)
        XCTAssertEqual(b.settings, store.settings)
    }

    func testBadJSONThrowsUnreadable() {
        XCTAssertThrowsError(try ImportParser.parse(json: Data("[1,2,3]".utf8))) {
            guard case .unreadable = $0 as? ImportError else { return XCTFail("expected unreadable, got \($0)") }
        }
    }
}
