import XCTest
import OTModels
import OTLedger
import OTXLSX
@testable import OTExchange

/// Export → real `.xlsx` bytes → `XLSXReader` / `ImportParser` → `Importer`, against the real `Ledger`.
final class RoundTripTests: XCTestCase {
    let cal = RichFixture.calendar

    // MARK: 1(a) Sheets and headers after a real write/read

    func testTwelveSheetsInSpecOrderWithSpecHeadersSurviveTheBytes() throws {
        let data = try RichFixture.xlsx()
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        XCTAssertEqual(wb.sheets.map { $0.name }, ExportBuilder.sheetNames)
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
        for sheet in wb.sheets { XCTAssertTrue(sheet.freezeHeader, "\(sheet.name) header is not frozen") }

        // One row per day of the range on the Days sheet, with real Excel dates and ledger numbers.
        let days = wb.sheets[1]
        XCTAssertEqual(days.rows.count, 1 + 365)
        XCTAssertEqual(days.rows[1][0], .dateOnly(RichFixture.day(2026, 1, 1).start(in: cal)))
        XCTAssertEqual(days.rows[1][2], .string("holiday"))
        let mar9 = days.rows[1 + 67]
        XCTAssertEqual(mar9[0], .dateOnly(RichFixture.day(2026, 3, 9).start(in: cal)))
        XCTAssertEqual(mar9[6], .date(RichFixture.date(2026, 3, 9, 7, 0, 30)))
        XCTAssertEqual(mar9[7], .date(RichFixture.date(2026, 3, 9, 15, 35, 15)))
        XCTAssertEqual(mar9[24], .string("graceApplied"))

        // Fact sheets carry every record of the range (plus header).
        XCTAssertEqual(wb.sheets[2].rows.count, 1 + RichFixture.counts["presence"]!)
        XCTAssertEqual(wb.sheets[3].rows.count, 1 + RichFixture.counts["manual"]!)
        XCTAssertEqual(wb.sheets[4].rows.count, 1 + RichFixture.counts["timeOff"]!)
        XCTAssertEqual(wb.sheets[5].rows.count, 1 + RichFixture.counts["holidays"]!)
        XCTAssertEqual(wb.sheets[6].rows.count, 1 + RichFixture.counts["locations"]!)
        XCTAssertEqual(wb.sheets[7].rows.count, 1 + 7 * RichFixture.counts["schedules"]!)
        XCTAssertEqual(wb.sheets[8].rows.count, 1 + RichFixture.counts["overrides"]!)
        XCTAssertEqual(wb.sheets[9].rows.count, 1 + RichFixture.counts["adjustments"]!)
        XCTAssertEqual(wb.sheets[10].rows.count, 1 + RichFixture.counts["events"]!)
    }

    func testDateCellsComeBackAtWholeSecondPrecisionInTheExportZone() throws {
        let data = try RichFixture.xlsx()
        let wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        let presence = wb.sheets[2].records
        let byID = Dictionary(uniqueKeysWithValues: presence.map { ($0["ID"]!.stringValue!, $0) })
        let p21 = byID[RichFixture.uuid(21).uuidString]!
        XCTAssertEqual(p21["Entered"], .date(RichFixture.date(2026, 3, 9, 7, 0, 30)))
        XCTAssertEqual(p21["Exited"], .date(RichFixture.date(2026, 3, 9, 15, 35, 15)))
        let p27 = byID[RichFixture.uuid(27).uuidString]!
        XCTAssertEqual(p27["Entered"], .date(RichFixture.date(2026, 10, 31, 22, 0)))
        XCTAssertEqual(p27["Exited"], .date(RichFixture.date(2026, 11, 1, 3, 0)))
        XCTAssertEqual(p27["Duration"], .string("6:00"))
        let open = byID[RichFixture.uuid(29).uuidString]!
        XCTAssertNil(open["Exited"]?.dateValue)
        XCTAssertEqual(open["Note"], .string("still here"))
        XCTAssertEqual(byID[RichFixture.uuid(22).uuidString]!["Note"], .string(RichFixture.specialNote))
        XCTAssertEqual(byID[RichFixture.uuid(23).uuidString]!["Location"], .string("Plant B & Annex"))
    }

    // MARK: 1(b) Merging the export back into its own store changes nothing

    func testOwnExportBytesMergeBackAsAllUnchanged() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "x.xlsx"), .xlsx)
        let bundle = try ImportParser.parse(data: data, filename: "x.xlsx", store: store)
        XCTAssertEqual(bundle.invalid, [])
        XCTAssertNil(bundle.fullStore)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        for key in ImportPlan.countKeys {
            let c = plan.counts[key] ?? ImportPlan.Counts()
            XCTAssertEqual(c.new, 0, "\(key).new")
            XCTAssertEqual(c.updated, 0, "\(key).updated")
            XCTAssertEqual(c.unchanged, RichFixture.counts[key]!, "\(key).unchanged")
        }
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(plan.newLocationNames, [])
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
        XCTAssertEqual(plan.totalNew + plan.totalUpdated, 0)

        var target = store
        Importer.apply(plan: plan, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
    }

    // MARK: 1(c) Rebuilding an empty store from the bytes

    func testOwnExportBytesRebuildAnEmptyStoreAndTheLedgerAgrees() throws {
        let original = RichFixture.store()
        let data = try RichFixture.xlsx(store: original)
        var empty = Store(settings: original.settings)
        let bundle = try ImportParser.parse(data: data, filename: "export.xlsx", store: empty)
        XCTAssertEqual(bundle.invalid, [])
        let plan = Importer.plan(store: empty, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: RichFixture.counts["presence"]!))
        XCTAssertEqual(plan.counts["manual"], ImportPlan.Counts(new: RichFixture.counts["manual"]!))
        XCTAssertEqual(plan.counts["timeOff"], ImportPlan.Counts(new: RichFixture.counts["timeOff"]!))
        XCTAssertEqual(plan.counts["timeOffTypes"], ImportPlan.Counts(new: 2, unchanged: 3))      // built-ins already exist
        XCTAssertEqual(plan.counts["leaveBalances"], ImportPlan.Counts(new: 1, updated: 2))      // default PTO/Personal configs replaced
        XCTAssertEqual(plan.newLocationNames, [])                                                // real locations come from the sheet
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
        Importer.apply(plan: plan, mode: .merge, to: &empty)

        assertEquivalentAfterWorkbookRoundTrip(original, empty)

        // The ledger cannot tell the two stores apart.
        XCTAssertEqual(RichFixture.dayResults(store: empty), RichFixture.dayResults(store: original))
        XCTAssertEqual(Ledger.summary(store: empty, now: RichFixture.now), Ledger.summary(store: original, now: RichFixture.now))
        let today = DayKey(RichFixture.now, calendar: cal)
        XCTAssertEqual(Ledger.leaveBalances(store: empty, asOf: today), Ledger.leaveBalances(store: original, asOf: today))

        // The rebuilt store exports byte-identical fact sheets.
        let again = try XLSXReader.read(try RichFixture.xlsx(store: empty), timeZone: RichFixture.timeZone)
        let first = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        for i in 2..<12 where i != 7 { XCTAssertEqual(again.sheets[i], first.sheets[i], again.sheets[i].name) }
    }

    /// Everything the ledger reads must be identical. The workbook has no column for
    /// `WorkLocation.createdAt`, `ManualSession.createdAt`, `ScheduleVersion.note` or
    /// `dismissedInboxKeys` (SPEC §6.1 lists none), so those are compared separately in
    /// `testFieldsTheWorkbookCannotCarryAreTheOnlyDifferences`.
    func assertEquivalentAfterWorkbookRoundTrip(_ a: Store, _ b: Store, file: StaticString = #filePath, line: UInt = #line) {
        func sorted<T: Identifiable>(_ xs: [T]) -> [T] where T.ID == UUID { xs.sorted { $0.id.uuidString < $1.id.uuidString } }
        XCTAssertEqual(a.settings, b.settings, "settings", file: file, line: line)
        XCTAssertEqual(a.schemaVersion, b.schemaVersion, "schemaVersion", file: file, line: line)
        XCTAssertEqual(sorted(a.presence), sorted(b.presence), "presence", file: file, line: line)
        XCTAssertEqual(sorted(a.timeOff), sorted(b.timeOff), "timeOff", file: file, line: line)
        XCTAssertEqual(sorted(a.holidays), sorted(b.holidays), "holidays", file: file, line: line)
        XCTAssertEqual(sorted(a.adjustments), sorted(b.adjustments), "adjustments", file: file, line: line)
        XCTAssertEqual(sorted(a.overrides), sorted(b.overrides), "overrides", file: file, line: line)
        XCTAssertEqual(sorted(a.locationEvents), sorted(b.locationEvents), "events", file: file, line: line)
        XCTAssertEqual(sorted(a.timeOffTypes), sorted(b.timeOffTypes), "timeOffTypes", file: file, line: line)
        XCTAssertEqual(sorted(a.leaveBalances), sorted(b.leaveBalances), "leaveBalances", file: file, line: line)
        func strip(_ m: ManualSession) -> ManualSession { var x = m; x.createdAt = Date(timeIntervalSince1970: 0); return x }
        XCTAssertEqual(sorted(a.manual.map(strip)), sorted(b.manual.map(strip)), "manual", file: file, line: line)
        func strip(_ l: WorkLocation) -> WorkLocation { var x = l; x.createdAt = Date(timeIntervalSince1970: 0); return x }
        XCTAssertEqual(sorted(a.locations.map(strip)), sorted(b.locations.map(strip)), "locations", file: file, line: line)
        func strip(_ v: ScheduleVersion) -> ScheduleVersion { var x = v; x.note = ""; return x }
        XCTAssertEqual(sorted(a.schedules.map(strip)), sorted(b.schedules.map(strip)), "schedules", file: file, line: line)
    }

    func testFieldsTheWorkbookCannotCarryAreTheOnlyDifferences() throws {
        let original = RichFixture.store()
        var rebuilt = Store(settings: original.settings)
        let bundle = try ImportParser.parse(data: try RichFixture.xlsx(store: original), filename: "export.xlsx", store: rebuilt)
        Importer.apply(plan: Importer.plan(store: rebuilt, bundle: bundle, mode: .merge), mode: .merge, to: &rebuilt)

        // Location createdAt: the sheet has no column; the importer uses the earliest instant the file relates to it.
        XCTAssertEqual(rebuilt.location(id: RichFixture.plantA)?.createdAt, RichFixture.date(2026, 3, 8, 6, 55))
        XCTAssertEqual(rebuilt.location(id: RichFixture.plantB)?.createdAt, RichFixture.date(2026, 3, 10, 13, 0))
        XCTAssertNotEqual(rebuilt.location(id: RichFixture.plantA)?.createdAt, original.location(id: RichFixture.plantA)?.createdAt)
        // Manual createdAt: taken from the first segment start.
        XCTAssertEqual(rebuilt.manualSession(id: RichFixture.uuid(41))?.createdAt, RichFixture.date(2026, 3, 11, 9, 0))
        XCTAssertEqual(original.manualSession(id: RichFixture.uuid(41))?.createdAt, RichFixture.date(2026, 3, 11, 8, 59))
        // Schedule note: the Schedule sheet has no note column.
        XCTAssertEqual(rebuilt.schedules.first { $0.id == RichFixture.scheduleV2 }?.note, "")
        XCTAssertEqual(original.schedules.first { $0.id == RichFixture.scheduleV2 }?.note, "summer")
        // Dismissed inbox keys are UI state; only the JSON backup carries them.
        XCTAssertEqual(rebuilt.dismissedInboxKeys, [])
        XCTAssertEqual(original.dismissedInboxKeys.count, 2)
        // Everything else is identical, including the ledger.
        var normalised = rebuilt
        normalised.dismissedInboxKeys = original.dismissedInboxKeys
        for i in normalised.locations.indices { normalised.locations[i].createdAt = original.location(id: normalised.locations[i].id)!.createdAt }
        for i in normalised.manual.indices { normalised.manual[i].createdAt = original.manualSession(id: normalised.manual[i].id)!.createdAt }
        for i in normalised.schedules.indices { normalised.schedules[i].note = original.schedules.first { $0.id == normalised.schedules[i].id }!.note }
        func canonical(_ s: Store) -> Store {
            var c = s
            c.presence.sort { $0.id.uuidString < $1.id.uuidString }
            c.manual.sort { $0.id.uuidString < $1.id.uuidString }
            c.timeOff.sort { $0.id.uuidString < $1.id.uuidString }
            c.holidays.sort { $0.id.uuidString < $1.id.uuidString }
            c.adjustments.sort { $0.id.uuidString < $1.id.uuidString }
            c.overrides.sort { $0.id.uuidString < $1.id.uuidString }
            c.locationEvents.sort { $0.id.uuidString < $1.id.uuidString }
            c.locations.sort { $0.id.uuidString < $1.id.uuidString }
            c.schedules.sort { $0.id.uuidString < $1.id.uuidString }
            c.timeOffTypes.sort { $0.id.uuidString < $1.id.uuidString }
            c.leaveBalances.sort { $0.typeID.uuidString < $1.typeID.uuidString }
            return c
        }
        XCTAssertEqual(canonical(normalised), canonical(original))
    }

    // MARK: Probes

    /// Notes are free text: whatever the user typed (including stray spaces) must come back unchanged,
    /// otherwise an untouched export reports "updated" rows on re-import.
    func testNotesAndReasonsComeBackVerbatimIncludingSurroundingWhitespace() throws {
        var store = RichFixture.store()
        store.presence[0].note = "  padded  "
        store.manual[0].note = "trailing "
        store.timeOff[0].note = " leading"
        store.adjustments[0].reason = " spaced reason "
        store.overrides[0].note = "tab\t"
        let bundle = try ImportParser.parse(data: try RichFixture.xlsx(store: store), filename: "x.xlsx", store: store)
        XCTAssertEqual(bundle.invalid, [])
        XCTAssertEqual(bundle.presence.first { $0.id == store.presence[0].id }?.note, "  padded  ")
        XCTAssertEqual(bundle.manual.first { $0.id == store.manual[0].id }?.note, "trailing ")
        XCTAssertEqual(bundle.timeOff.first { $0.id == store.timeOff[0].id }?.note, " leading")
        XCTAssertEqual(bundle.adjustments.first { $0.id == store.adjustments[0].id }?.reason, " spaced reason ")
        XCTAssertEqual(bundle.overrides.first { $0.id == store.overrides[0].id }?.note, "tab\t")
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.totalUpdated, 0)
        XCTAssertEqual(plan.totalNew, 0)
    }

    /// Excel dates are wall-clock in the exporting zone. If the phone's time zone setting changed
    /// after the export, the import must still rebuild the same instants: the Settings sheet says
    /// which zone the file was written in.
    func testWorkbookExportedInAnotherTimeZoneStillImportsTheSameInstants() throws {
        let original = RichFixture.store()                                  // New York
        let data = try RichFixture.xlsx(store: original)
        var moved = original
        moved.settings.timeZoneIdentifier = "America/Los_Angeles"          // the setting moved, the facts did not
        let bundle = try ImportParser.parse(data: data, filename: "export.xlsx", store: moved)
        XCTAssertEqual(bundle.invalid, [])
        XCTAssertEqual(bundle.presence.first { $0.id == RichFixture.uuid(21) }?.enteredAt, RichFixture.date(2026, 3, 9, 7, 0, 30))
        XCTAssertEqual(bundle.manual.first { $0.id == RichFixture.uuid(41) }?.segments, original.manualSession(id: RichFixture.uuid(41))?.segments)
        XCTAssertEqual(bundle.events.first { $0.id == RichFixture.uuid(90) }?.at, RichFixture.date(2026, 3, 8, 6, 55))
        XCTAssertEqual(bundle.settings?.timeZoneIdentifier, "America/New_York")
        let plan = Importer.plan(store: moved, bundle: bundle, mode: .merge)
        for key in ImportPlan.countKeys {
            XCTAssertEqual(plan.counts[key]?.new, 0, key)
            XCTAssertEqual(plan.counts[key]?.updated, 0, key)
        }
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(updated: 1))   // the file's zone comes back with its settings

        // An already-read Workbook (dates are instants) still resolves text dates in the file's zone.
        var wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        wb.sheets[5].rows.append([.string("11111111-1111-4111-8111-111111111111"), .string("2026-07-04"), .string("Independence Day")])
        wb.sheets[10].rows.append([.empty, .string("Plant A"), .string("enter"), .string("2026-07-06 07:00"), .string("manual")])
        let b2 = ImportParser.parse(workbook: wb, store: moved)
        XCTAssertEqual(b2.invalid, [])
        XCTAssertEqual(b2.holidays.last?.day, RichFixture.day(2026, 7, 4))
        XCTAssertEqual(b2.events.last?.at, RichFixture.date(2026, 7, 6, 7, 0))
    }

    /// Known limitation (OTXLSX, by design of Excel dates): an instant inside the repeated hour of a
    /// fall-back night has the same wall clock as the instant an hour earlier, so it comes back as
    /// the first occurrence. Everything outside that one hour per year round-trips exactly.
    func testInstantInTheRepeatedHourCannotRoundTripThroughAnExcelDate() throws {
        var store = RichFixture.store()
        let firstIn = RichFixture.date(2026, 11, 1, 1, 10)                       // 01:10 EDT (Calendar picks the first occurrence)
        let secondIn = firstIn.addingTimeInterval(3600)                         // 01:10 EST, same wall clock an hour later
        let secondOut = secondIn.addingTimeInterval(40 * 60)                    // 01:50 EST
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: secondIn).hour, 1)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: secondOut).minute, 50)
        store.presence.append(PresenceSession(id: RichFixture.uuid(99), locationID: RichFixture.plantA,
                                              enteredAt: secondIn, exitedAt: secondOut, source: .manual))
        let bundle = try ImportParser.parse(data: try RichFixture.xlsx(store: store), filename: "x.xlsx", store: store)
        let row = bundle.presence.first { $0.id == RichFixture.uuid(99) }!
        XCTAssertEqual(row.enteredAt, firstIn)                                  // one hour early
        XCTAssertEqual(row.exitedAt, firstIn.addingTimeInterval(40 * 60))       // duration intact
        XCTAssertEqual(Importer.plan(store: store, bundle: bundle, mode: .merge).counts["presence"]?.updated, 1)
    }

    // MARK: 2. Artifact for the independent (openpyxl) reader check

    /// Writes the workbook to `$OT_VERIFY_OUT/export.xlsx` when that variable is set (the host-side
    /// openpyxl script reads it); otherwise only checks the bytes are a zip.
    func testWritesTheWorkbookForAnExternalReaderWhenAsked() throws {
        let data = try RichFixture.xlsx()
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        guard let dir = ProcessInfo.processInfo.environment["OT_VERIFY_OUT"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("export.xlsx"))
    }
}
