import XCTest
import OTModels
import OTXLSX
@testable import OTExchange

/// SPEC §6.3 merge semantics, driven through real `.xlsx` bytes.
final class MergeSemanticsTests: XCTestCase {
    /// Edits one cell of a sheet in the exported workbook and returns new bytes.
    func edited(_ data: Data, sheet: String, edit: (inout Worksheet) -> Void) throws -> Data {
        var wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        let i = wb.sheets.firstIndex { $0.name == sheet }!
        edit(&wb.sheets[i])
        return try XLSXWriter.write(wb, timeZone: RichFixture.timeZone)
    }

    func rowIndex(_ sheet: Worksheet, id: UUID) -> Int { sheet.rows.firstIndex { $0.first?.stringValue == id.uuidString }! }

    func plan(_ data: Data, store: Store, mode: ImportMode = .merge) throws -> ImportPlan {
        let bundle = try ImportParser.parse(data: data, filename: "export.xlsx", store: store)
        XCTAssertEqual(bundle.invalid, [])
        return Importer.plan(store: store, bundle: bundle, mode: mode)
    }

    func assertOnlyChange(_ plan: ImportPlan, kind: String, new: Int = 0, updated: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        for key in ImportPlan.countKeys {
            let c = plan.counts[key] ?? ImportPlan.Counts()
            XCTAssertEqual(c.new, key == kind ? new : 0, "\(key).new", file: file, line: line)
            XCTAssertEqual(c.updated, key == kind ? updated : 0, "\(key).updated", file: file, line: line)
        }
        XCTAssertNil(plan.counts["settings"], "a Merge never touches settings", file: file, line: line)
    }

    func testSameFileImportedTwiceIsANoOp() throws {
        let original = RichFixture.store()
        let data = try RichFixture.xlsx(store: original)
        var target = Store(settings: original.settings)
        let first = try plan(data, store: target)
        XCTAssertEqual(first.totalNew, RichFixture.counts.values.reduce(0, +) - 3 - 2) // built-in types exist; default PTO/Personal configs are updated
        XCTAssertEqual(first.totalUpdated, 2)
        Importer.apply(plan: first, mode: .merge, to: &target)
        let after = target
        let second = try plan(data, store: target)
        XCTAssertEqual(second.totalNew, 0)
        XCTAssertEqual(second.totalUpdated, 0)
        XCTAssertEqual(second.totalUnchanged, RichFixture.counts.values.reduce(0, +))
        XCTAssertNil(second.counts["settings"], "a Merge never touches settings")
        Importer.apply(plan: second, mode: .merge, to: &target)
        XCTAssertEqual(target, after)
    }

    func testEditingOneNoteInTheFileGivesExactlyOneUpdated() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let id = RichFixture.uuid(22)
        let changed = try edited(data, sheet: "Presence") { sheet in
            let r = self.rowIndex(sheet, id: id)
            sheet.rows[r][7] = .string("dentist (rescheduled)")
        }
        let p = try plan(changed, store: store)
        assertOnlyChange(p, kind: "presence", updated: 1)
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target.presenceSession(id: id)?.note, "dentist (rescheduled)")
        XCTAssertEqual(target.presenceSession(id: id)?.followingGapIsWork, false)   // the rest of the row kept
        var expected = store
        expected.presence[expected.presence.firstIndex { $0.id == id }!].note = "dentist (rescheduled)"
        XCTAssertEqual(target, expected)
    }

    func testEditingATimeInTheFileUpdatesTheRecordByID() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let id = RichFixture.uuid(21)
        let changed = try edited(data, sheet: "Presence") { sheet in
            let r = self.rowIndex(sheet, id: id)
            sheet.rows[r][3] = .date(RichFixture.date(2026, 3, 9, 16, 0))
        }
        let p = try plan(changed, store: store)
        assertOnlyChange(p, kind: "presence", updated: 1)
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target.presenceSession(id: id)?.exitedAt, RichFixture.date(2026, 3, 9, 16, 0))
        XCTAssertEqual(target.presenceSession(id: id)?.source, .geofence)
        XCTAssertEqual(target.presence.count, store.presence.count)
    }

    func testRowWithABrandNewIDIsNew() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let newID = UUID(uuidString: "12345678-1234-4123-8123-123456789abc")!
        let changed = try edited(data, sheet: "TimeOff") { sheet in
            sheet.rows.append([.string(newID.uuidString), .dateOnly(RichFixture.day(2026, 12, 1).start(in: RichFixture.calendar)),
                               .string("PTO"), .integer(8), .integer(0), .string("new row")])
        }
        let p = try plan(changed, store: store)
        assertOnlyChange(p, kind: "timeOff", new: 1)
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target.timeOff.count, store.timeOff.count + 1)
        XCTAssertEqual(target.timeOff.last, TimeOffEntry(id: newID, day: RichFixture.day(2026, 12, 1), typeID: TimeOffType.ptoID, seconds: 28800, note: "new row"))
    }

    func testRowWithoutIDMatchingAnExistingRecordByNaturalKeyIsUnchanged() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let changed = try edited(data, sheet: "Presence") { sheet in
            sheet.rows[self.rowIndex(sheet, id: RichFixture.uuid(20))][0] = .empty
            sheet.rows[self.rowIndex(sheet, id: RichFixture.uuid(29))][0] = .string("")      // open session, no exit
        }
        let withoutManualIDs = try edited(changed, sheet: "Manual") { sheet in
            for r in 1..<sheet.rows.count { sheet.rows[r][0] = .empty }
        }
        let p = try plan(withoutManualIDs, store: store)
        assertOnlyChange(p, kind: "none")
        XCTAssertEqual(p.counts["presence"], ImportPlan.Counts(unchanged: RichFixture.counts["presence"]!))
        XCTAssertEqual(p.counts["manual"], ImportPlan.Counts(unchanged: RichFixture.counts["manual"]!))
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
    }

    func testUnknownIDWithAMatchingNaturalKeyKeepsTheExistingRecord() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let strangerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let changed = try edited(data, sheet: "Adjustments") { sheet in
            sheet.rows[self.rowIndex(sheet, id: RichFixture.uuid(80))][0] = .string(strangerID.uuidString)
        }
        let p = try plan(changed, store: store)
        assertOnlyChange(p, kind: "none")
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
        XCTAssertNil(target.adjustments.first { $0.id == strangerID })
    }

    func testUnknownLocationAndTimeOffTypeNamesCreatePlaceholdersAsSpecified() throws {
        let store = RichFixture.store()
        let data = try RichFixture.xlsx(store: store)
        let changed = try edited(data, sheet: "Presence") { sheet in
            sheet.rows.append([.empty, .string("Plant Z"), .date(RichFixture.date(2026, 12, 2, 7, 0)), .date(RichFixture.date(2026, 12, 2, 15, 0)),
                               .empty, .empty, .empty, .empty])
            sheet.rows.append([.empty, .string(" plant z "), .date(RichFixture.date(2026, 12, 1, 7, 0)), .date(RichFixture.date(2026, 12, 1, 15, 0)),
                               .empty, .empty, .empty, .empty])
        }
        let withType = try edited(changed, sheet: "TimeOff") { sheet in
            sheet.rows.append([.empty, .dateOnly(RichFixture.day(2026, 12, 3).start(in: RichFixture.calendar)), .string("Sabbatical"), .integer(8), .integer(0), .empty])
            sheet.rows.append([.empty, .dateOnly(RichFixture.day(2026, 12, 4).start(in: RichFixture.calendar)), .string("sabbatical"), .integer(4), .integer(0), .empty])
        }
        let p = try plan(withType, store: store)
        XCTAssertEqual(p.newLocationNames, ["Plant Z"])
        XCTAssertEqual(p.newTimeOffTypeNames, ["Sabbatical"])
        XCTAssertEqual(p.counts["presence"], ImportPlan.Counts(new: 2, unchanged: RichFixture.counts["presence"]!))
        XCTAssertEqual(p.counts["locations"], ImportPlan.Counts(new: 1, unchanged: 2))
        XCTAssertEqual(p.counts["timeOff"], ImportPlan.Counts(new: 2, unchanged: RichFixture.counts["timeOff"]!))
        XCTAssertEqual(p.counts["timeOffTypes"], ImportPlan.Counts(new: 1, unchanged: 5))

        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        let z = target.location(named: "plant z")!
        XCTAssertEqual(z.name, "Plant Z")
        XCTAssertEqual(z.latitude, 0)
        XCTAssertEqual(z.longitude, 0)
        XCTAssertEqual(z.radiusMeters, 200)
        XCTAssertFalse(z.isActive)
        XCTAssertEqual(z.createdAt, RichFixture.date(2026, 12, 1, 7, 0))                 // earliest mention in the file
        XCTAssertEqual(target.presence.filter { $0.locationID == z.id }.count, 2)
        XCTAssertEqual(target.presence.filter { $0.locationID == z.id }.map { $0.source }, [.imported, .imported])
        let sab = target.timeOffType(named: "Sabbatical")!
        XCTAssertEqual(sab.kind, .other)
        XCTAssertFalse(sab.tracksBalance)
        XCTAssertFalse(sab.deductsFromBank)
        XCTAssertEqual(target.timeOff.filter { $0.typeID == sab.id }.map { $0.seconds }, [28800, 14400])
        XCTAssertEqual(target.timeOffTypes.count, 6)
        XCTAssertEqual(target.locations.count, 3)

        let again = try plan(withType, store: target)
        XCTAssertEqual(again.totalNew + again.totalUpdated, 0)
        XCTAssertEqual(again.newLocationNames, [])
        XCTAssertEqual(again.newTimeOffTypeNames, [])
    }

    func testPresenceRowNamingADeletedLocationByIDReusesThatIDRatherThanAUUIDNamedPlaceholder() throws {
        var store = RichFixture.store()
        store.locations.removeAll { $0.id == RichFixture.plantB }            // sessions still point at it
        let data = try RichFixture.xlsx(store: store)
        let wb = try XLSXReader.read(data, timeZone: RichFixture.timeZone)
        let bRow = wb.sheets[2].rows.first { $0.first?.stringValue == RichFixture.uuid(23).uuidString }!
        XCTAssertEqual(bRow[1], .string(RichFixture.plantB.uuidString))         // the export falls back to the ID
        let p = try plan(data, store: store)
        XCTAssertEqual(p.counts["presence"], ImportPlan.Counts(unchanged: RichFixture.counts["presence"]!))
        XCTAssertEqual(p.counts["locations"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(p.newLocationNames, [])
        var target = store
        Importer.apply(plan: p, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
    }

    func testReplaceWipesEverythingButSettingsAndBuiltInTypesThenImportsTheFile() throws {
        let original = RichFixture.store()
        let data = try RichFixture.xlsx(store: original)
        var target = Fixtures.store()                                            // a different, populated store
        target.dismissedInboxKeys = ["old:1"]
        let p = try plan(data, store: target, mode: .replace)
        for key in ImportPlan.countKeys { XCTAssertEqual(p.counts[key], ImportPlan.Counts(new: RichFixture.counts[key]!), key) }
        XCTAssertEqual(p.counts["settings"], ImportPlan.Counts(new: 1))
        Importer.apply(plan: p, mode: .replace, to: &target)

        XCTAssertEqual(Set(target.presence), Set(original.presence))
        XCTAssertEqual(Set(target.timeOff), Set(original.timeOff))
        XCTAssertEqual(Set(target.holidays), Set(original.holidays))
        XCTAssertEqual(Set(target.adjustments), Set(original.adjustments))
        XCTAssertEqual(Set(target.overrides), Set(original.overrides))
        XCTAssertEqual(Set(target.locationEvents), Set(original.locationEvents))
        XCTAssertEqual(Set(target.timeOffTypes), Set(original.timeOffTypes))
        XCTAssertEqual(Set(target.leaveBalances), Set(original.leaveBalances))
        XCTAssertEqual(Set(target.locations.map { $0.id }), Set(original.locations.map { $0.id }))
        XCTAssertEqual(Set(target.schedules.map { $0.id }), Set(original.schedules.map { $0.id }))
        XCTAssertEqual(target.settings, original.settings)                       // the file's settings, not the old store's
        XCTAssertEqual(target.dismissedInboxKeys, [])                             // wiped, not carried
        XCTAssertNil(target.presenceSession(id: Fixtures.uuid(20)))              // nothing of the old store survives
        XCTAssertNil(target.manualSession(id: Fixtures.uuid(30)))
        XCTAssertEqual(target.schemaVersion, Store.currentSchemaVersion)
    }

    func testReplaceWithAnEmptyFileKeepsOnlySettingsAndBuiltIns() throws {
        var store = RichFixture.store()
        let settings = store.settings
        let bundle = try ImportParser.parse(data: Data("record,date\n".utf8), filename: "empty.csv", store: store)
        Importer.apply(plan: Importer.plan(store: store, bundle: bundle, mode: .replace), mode: .replace, to: &store)
        var expected = Store(settings: settings)
        expected.schemaVersion = Store.currentSchemaVersion
        XCTAssertEqual(store, expected)
        XCTAssertEqual(store.timeOffTypes, TimeOffType.builtIn)
    }

    func testPlanCountKeysAreExactlyTheElevenKindsTheUIReads() throws {
        XCTAssertEqual(ImportPlan.countKeys, ["presence", "manual", "timeOff", "holidays", "adjustments", "locations",
                                              "overrides", "schedules", "events", "timeOffTypes", "leaveBalances"])
        let store = RichFixture.store()
        let csv = Importer.plan(store: store, bundle: ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store), mode: .merge)
        XCTAssertEqual(Set(csv.counts.keys), Set(ImportPlan.countKeys))           // a CSV carries no settings
        let empty = Importer.plan(store: store, bundle: ImportBundle(), mode: .merge)
        XCTAssertEqual(Set(empty.counts.keys), Set(ImportPlan.countKeys))
        let xlsx = try plan(try RichFixture.xlsx(store: store), store: store)
        XCTAssertEqual(Set(xlsx.counts.keys), Set(ImportPlan.countKeys))                   // a Merge ignores the file's settings
        let json = Importer.plan(store: store, bundle: try ImportParser.parse(json: ExportBuilder.json(store: store)), mode: .merge)
        XCTAssertEqual(Set(json.counts.keys), Set(ImportPlan.countKeys))
        let replace = Importer.plan(store: store, bundle: try ImportParser.parse(json: ExportBuilder.json(store: store)), mode: .replace)
        XCTAssertEqual(Set(replace.counts.keys), Set(ImportPlan.countKeys + ["settings"]))   // a Replace carries them
    }

    func testPlanNeverMutatesTheStore() throws {
        let store = RichFixture.store()
        let before = store
        _ = try plan(try RichFixture.xlsx(store: store), store: store)
        _ = try plan(try RichFixture.xlsx(store: store), store: store, mode: .replace)
        XCTAssertEqual(store, before)
    }
}
