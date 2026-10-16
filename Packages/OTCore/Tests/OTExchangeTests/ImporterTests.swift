import XCTest
import OTModels
import OTXLSX
@testable import OTExchange

final class ImporterTests: XCTestCase {
    let header = "record,date,start,end,location,category,type,hours,minutes,name,note,id"

    /// Expected per-kind record counts of the fixture store.
    let fixtureCounts: [String: Int] = ["presence": 6, "manual": 5, "timeOff": 4, "holidays": 2, "adjustments": 2, "locations": 2,
                                        "overrides": 3, "schedules": 2, "events": 3, "timeOffTypes": 4, "leaveBalances": 3]

    func assertCounts(_ plan: ImportPlan, new: (String) -> Int, updated: (String) -> Int, unchanged: (String) -> Int,
                      file: StaticString = #filePath, line: UInt = #line) {
        for key in ImportPlan.countKeys {
            let c = plan.counts[key] ?? ImportPlan.Counts()
            XCTAssertEqual(c.new, new(key), "\(key).new", file: file, line: line)
            XCTAssertEqual(c.updated, updated(key), "\(key).updated", file: file, line: line)
            XCTAssertEqual(c.unchanged, unchanged(key), "\(key).unchanged", file: file, line: line)
        }
    }

    // MARK: Workbook round trip

    func testOwnExportMergesBackAsAllUnchanged() {
        let store = Fixtures.store()
        let bundle = ImportParser.parse(workbook: Fixtures.workbook(store: store), store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.invalid, [])
        assertCounts(plan, new: { _ in 0 }, updated: { _ in 0 }, unchanged: { fixtureCounts[$0]! })
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(new: 0, updated: 0, unchanged: 1))
        XCTAssertEqual(plan.newLocationNames, [])
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
        XCTAssertEqual(plan.totalNew, 0)
        XCTAssertEqual(plan.totalUpdated, 0)

        var target = store
        Importer.apply(plan: plan, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
    }

    func testReplacePlanCountsEverythingAsNew() {
        let store = Fixtures.store()
        let bundle = ImportParser.parse(workbook: Fixtures.workbook(store: store), store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .replace)
        // The store is wiped first, so everything in the file is new (built-in types included).
        assertCounts(plan, new: { fixtureCounts[$0]! }, updated: { _ in 0 }, unchanged: { _ in 0 })
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.totalNew, fixtureCounts.values.reduce(0, +) + 1)
        XCTAssertEqual(plan.newLocationNames, [])
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
    }

    func testOwnExportReplacedIntoAnEmptyStoreRebuildsTheData() {
        let store = Fixtures.store()
        let bundle = ImportParser.parse(workbook: Fixtures.workbook(store: store), store: store)
        var target = Store(settings: Fixtures.settings)
        target.holidays = [Holiday(day: Fixtures.day(2030, 1, 1), name: "gone after replace")]
        Importer.apply(plan: Importer.plan(store: target, bundle: bundle, mode: .replace), mode: .replace, to: &target)

        XCTAssertEqual(Set(target.presence), Set(store.presence))
        XCTAssertEqual(Set(target.manual), Set(store.manual))
        XCTAssertEqual(Set(target.timeOff), Set(store.timeOff))
        XCTAssertEqual(Set(target.holidays), Set(store.holidays))
        XCTAssertEqual(Set(target.adjustments), Set(store.adjustments))
        XCTAssertEqual(Set(target.overrides), Set(store.overrides))
        XCTAssertEqual(Set(target.locationEvents), Set(store.locationEvents))
        XCTAssertEqual(Set(target.timeOffTypes), Set(store.timeOffTypes))
        XCTAssertEqual(Set(target.leaveBalances), Set(store.leaveBalances))
        XCTAssertEqual(target.settings, store.settings)
        XCTAssertEqual(target.schemaVersion, store.schemaVersion)
        // Not carried by the workbook: location createdAt and schedule notes.
        func strip(_ l: WorkLocation) -> WorkLocation { var x = l; x.createdAt = Date(timeIntervalSince1970: 0); return x }
        XCTAssertEqual(Set(target.locations.map(strip)), Set(store.locations.map(strip)))
        func strip(_ v: ScheduleVersion) -> ScheduleVersion { var x = v; x.note = ""; return x }
        XCTAssertEqual(Set(target.schedules.map(strip)), Set(store.schedules.map(strip)))
    }

    // MARK: Plan counts

    func testPlanCountsNewUpdatedAndUnchanged() {
        var store = Store(settings: Fixtures.settings)
        store.locations = [WorkLocation(id: Fixtures.plantA, name: "Plant A", latitude: 1, longitude: 2, createdAt: Fixtures.date(2026, 1, 1, 0, 0))]
        store.presence = [
            PresenceSession(id: Fixtures.uuid(1), locationID: Fixtures.plantA, enteredAt: Fixtures.date(2026, 10, 14, 7, 2), exitedAt: Fixtures.date(2026, 10, 14, 17, 42), source: .geofence),
            PresenceSession(id: Fixtures.uuid(2), locationID: Fixtures.plantA, enteredAt: Fixtures.date(2026, 10, 15, 7, 0), exitedAt: Fixtures.date(2026, 10, 15, 15, 30), source: .geofence),
        ]
        let text = """
        \(header)
        presence,2026-10-14,07:02,17:42,plant a,,,,,,,
        presence,2026-10-15,07:00,15:30,Plant A,,,,,,late,
        presence,2026-10-16,07:00,15:30,Plant A,,,,,,,
        """
        let bundle = ImportParser.parse(csvText: text, store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: 1, updated: 1, unchanged: 1))
        XCTAssertEqual(plan.counts["locations"], ImportPlan.Counts())
        XCTAssertEqual(plan.totalNew, 1)
        XCTAssertEqual(plan.totalUpdated, 1)
        XCTAssertEqual(plan.totalUnchanged, 1)
        XCTAssertEqual(plan.newLocationNames, [])

        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.presence.count, 3)
        let updated = store.presenceSession(id: Fixtures.uuid(2))!
        XCTAssertEqual(updated.note, "late")
        XCTAssertEqual(updated.source, .geofence)          // a CSV row does not know better than the store
        XCTAssertEqual(store.presenceSession(id: Fixtures.uuid(1))?.source, .geofence)
        XCTAssertEqual(store.presence[2].source, .imported)
        XCTAssertEqual(store.presence[2].locationID, Fixtures.plantA)
    }

    func testManualTimeOffHolidayAdjustmentNaturalKeys() {
        var store = Store(settings: Fixtures.settings)
        store.manual = [ManualSession.block(category: "After hours", note: "emails", start: Fixtures.date(2026, 10, 14, 19, 0), end: Fixtures.date(2026, 10, 14, 20, 15),
                                            id: Fixtures.uuid(1), createdAt: Fixtures.date(2026, 10, 14, 21, 0))]
        store.timeOff = [TimeOffEntry(id: Fixtures.uuid(2), day: Fixtures.day(2026, 10, 20), typeID: TimeOffType.ptoID, seconds: 8 * 3600)]
        store.holidays = [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 26), name: "Thanksgiving")]
        store.adjustments = [Adjustment(id: Fixtures.uuid(4), day: Fixtures.day(2026, 10, 1), seconds: 5400, reason: "carry-over from old sheet")]
        let bundle = ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["manual"], ImportPlan.Counts(unchanged: 1))          // createdAt adopted from the store
        XCTAssertEqual(plan.counts["timeOff"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(plan.counts["adjustments"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.counts["locations"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.newLocationNames, ["Plant A"])
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.manual.count, 1)
        XCTAssertEqual(store.manual[0].createdAt, Fixtures.date(2026, 10, 14, 21, 0))
        XCTAssertEqual(store.timeOff.count, 1)
        XCTAssertEqual(store.holidays.count, 1)
        XCTAssertEqual(store.adjustments.count, 1)
    }

    func testIDMatchUpdatesEvenWhenTheNaturalKeyChanges() {
        var store = Store(settings: Fixtures.settings)
        store.holidays = [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 26), name: "Thanksgiving")]
        var bundle = ImportBundle()
        bundle.holidays = [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 27), name: "Turkey day")]
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(updated: 1))
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.holidays, [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 27), name: "Turkey day")])
    }

    func testUnknownIDWithMatchingNaturalKeyKeepsTheExistingRecord() {
        var store = Store(settings: Fixtures.settings)
        store.holidays = [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 26), name: "Thanksgiving")]
        var bundle = ImportBundle()
        bundle.holidays = [Holiday(id: Fixtures.uuid(9), day: Fixtures.day(2026, 11, 26), name: "Thanksgiving"),
                           Holiday(id: Fixtures.uuid(8), day: Fixtures.day(2026, 11, 26), name: "Turkey day")]
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(new: 0, updated: 1, unchanged: 1))
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.holidays, [Holiday(id: Fixtures.uuid(3), day: Fixtures.day(2026, 11, 26), name: "Turkey day")])
    }

    func testOverrideMatchesByDayAndStaysUnique() {
        var store = Store(settings: Fixtures.settings)
        store.overrides = [DayOverride(id: Fixtures.uuid(5), day: Fixtures.day(2026, 3, 16), kind: .dayOff)]
        var bundle = ImportBundle()
        bundle.overrides = [DayOverride(day: Fixtures.day(2026, 3, 16), kind: .none, excused: true, note: "snow")]
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["overrides"], ImportPlan.Counts(updated: 1))
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.overrides.count, 1)
        XCTAssertEqual(store.overrides[0].id, Fixtures.uuid(5))
        XCTAssertTrue(store.overrides[0].excused)
        XCTAssertEqual(store.overrides[0].kind, .none)
    }

    func testImportingTheSameFileTwiceChangesNothing() {
        var store = Store(settings: Fixtures.settings)
        let first = Importer.plan(store: store, bundle: ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store), mode: .merge)
        XCTAssertEqual(first.totalNew, 6)      // 5 rows + the Plant A placeholder
        Importer.apply(plan: first, mode: .merge, to: &store)
        let after = store
        let second = Importer.plan(store: store, bundle: ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store), mode: .merge)
        XCTAssertEqual(second.totalNew, 0)
        XCTAssertEqual(second.totalUpdated, 0)
        XCTAssertEqual(second.totalUnchanged, 5)
        Importer.apply(plan: second, mode: .merge, to: &store)
        XCTAssertEqual(store, after)
    }

    // MARK: Placeholders

    func testMergeCreatesPlaceholderLocationAndType() {
        var store = Store(settings: Fixtures.settings)
        let text = """
        \(header)
        presence,2026-10-14,07:00,15:00,Plant Z,,,,,,,
        presence,2026-10-13,07:00,15:00,plant z,,,,,,,
        timeoff,2026-10-20,,,,,Comp2,8,0,,,
        timeoff,2026-10-21,,,,,comp2,1,0,,,
        """
        let bundle = ImportParser.parse(csvText: text, store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.newLocationNames, ["Plant Z"])
        XCTAssertEqual(plan.newTimeOffTypeNames, ["Comp2"])
        XCTAssertEqual(plan.counts["locations"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.counts["timeOffTypes"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: 2))
        XCTAssertEqual(plan.counts["timeOff"], ImportPlan.Counts(new: 2))

        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.locations.count, 1)
        let loc = store.locations[0]
        XCTAssertEqual(loc.name, "Plant Z")
        XCTAssertEqual(loc.latitude, 0)
        XCTAssertEqual(loc.longitude, 0)
        XCTAssertEqual(loc.radiusMeters, 200)
        XCTAssertFalse(loc.isActive)
        XCTAssertEqual(loc.createdAt, Fixtures.date(2026, 10, 13, 7, 0))      // first time the file mentions it
        XCTAssertEqual(store.presence.map { $0.locationID }, [loc.id, loc.id])

        let type = store.timeOffTypes.first { $0.name == "Comp2" }!
        XCTAssertEqual(type.kind, .other)
        XCTAssertFalse(type.tracksBalance)
        XCTAssertFalse(type.deductsFromBank)
        XCTAssertEqual(store.timeOffTypes.count, 4)
        XCTAssertEqual(store.timeOff.map { $0.typeID }, [type.id, type.id])

        let again = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(again.totalNew, 0)
        XCTAssertEqual(again.newLocationNames, [])
        XCTAssertEqual(again.newTimeOffTypeNames, [])
    }

    func testBuiltInTypesResolveByNameOrKind() {
        var store = Store(settings: Fixtures.settings)
        let text = """
        \(header)
        timeoff,2026-10-20,,,,,pto,8,0,,,
        timeoff,2026-10-21,,,,,Personal,1,0,,,
        timeoff,2026-10-22,,,,,flex,2,0,,,
        timeoff,2026-10-23,,,,,Flex (from bank),2,0,,,
        """
        let plan = Importer.plan(store: store, bundle: ImportParser.parse(csvText: text, store: store), mode: .merge)
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.timeOff.map { $0.typeID }, [TimeOffType.ptoID, TimeOffType.personalID, TimeOffType.flexID, TimeOffType.flexID])
        XCTAssertEqual(store.timeOffTypes.count, 3)
    }

    func testFileIDsAreRemappedWhenALocationOrTypeMatchesByName() {
        var store = Store(settings: Fixtures.settings)
        store.locations = [WorkLocation(id: Fixtures.plantA, name: "Plant A", latitude: 1, longitude: 2, createdAt: Fixtures.date(2026, 1, 1, 0, 0))]
        store.timeOffTypes.append(Fixtures.compType)
        let fileLocationID = Fixtures.uuid(77), fileTypeID = Fixtures.uuid(78)
        var bundle = ImportBundle()
        bundle.locations = [WorkLocation(id: fileLocationID, name: "plant a", latitude: 1, longitude: 2, createdAt: Fixtures.now)]
        bundle.events = [LocationEvent(id: Fixtures.uuid(79), locationID: fileLocationID, kind: .enter, at: Fixtures.now, source: .imported)]
        bundle.timeOffTypes = [TimeOffType(id: fileTypeID, name: "Comp", kind: .other, tracksBalance: true, deductsFromBank: false)]
        bundle.leaveBalances = [LeaveBalanceConfig(typeID: fileTypeID, startingSeconds: 3600, asOf: Fixtures.day(2026, 1, 1))]
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["locations"], ImportPlan.Counts(updated: 1))   // name differs in case only
        XCTAssertEqual(plan.counts["timeOffTypes"], ImportPlan.Counts(unchanged: 1))
        XCTAssertEqual(plan.counts["events"], ImportPlan.Counts(new: 1))
        XCTAssertEqual(plan.counts["leaveBalances"], ImportPlan.Counts(new: 1))
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.locations.map { $0.id }, [Fixtures.plantA])
        XCTAssertEqual(store.locationEvents.map { $0.locationID }, [Fixtures.plantA])
        XCTAssertEqual(store.timeOffTypes.filter { $0.name == "Comp" }.map { $0.id }, [Fixtures.compTypeID])
        XCTAssertEqual(store.leaveBalances.last?.typeID, Fixtures.compTypeID)
    }

    // MARK: Replace

    func testReplaceWipesEverythingButSettingsAndBuiltInTypes() {
        var store = Fixtures.store()
        let original = store
        let bundle = ImportParser.parse(csvText: "date,name\n2027-01-01,New Year\n", store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: .replace)
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(new: 1))
        Importer.apply(plan: plan, mode: .replace, to: &store)
        XCTAssertEqual(store.holidays.map { $0.name }, ["New Year"])
        XCTAssertEqual(store.presence, [])
        XCTAssertEqual(store.manual, [])
        XCTAssertEqual(store.timeOff, [])
        XCTAssertEqual(store.adjustments, [])
        XCTAssertEqual(store.overrides, [])
        XCTAssertEqual(store.schedules, [])
        XCTAssertEqual(store.locations, [])
        XCTAssertEqual(store.locationEvents, [])
        XCTAssertEqual(store.dismissedInboxKeys, [])
        XCTAssertEqual(store.timeOffTypes, TimeOffType.builtIn)
        XCTAssertEqual(store.leaveBalances, Store(settings: original.settings).leaveBalances)
        XCTAssertEqual(store.settings, original.settings)
        XCTAssertEqual(store.schemaVersion, original.schemaVersion)
    }

    func testJSONBackupReplaceRoundTripEqualsTheOriginalStore() throws {
        let original = Fixtures.store()
        let bundle = try ImportParser.parse(json: ExportBuilder.json(store: original))
        var target = Store()
        target.holidays = [Holiday(day: Fixtures.day(2030, 1, 1), name: "gone")]
        let plan = Importer.plan(store: target, bundle: bundle, mode: .replace)
        assertCounts(plan, new: { fixtureCounts[$0]! }, updated: { _ in 0 }, unchanged: { _ in 0 })
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(new: 1))
        Importer.apply(plan: plan, mode: .replace, to: &target)
        XCTAssertEqual(target, original)
    }

    func testJSONBackupMergedIntoItselfIsAllUnchanged() throws {
        let store = Fixtures.store()
        let bundle = try ImportParser.parse(json: ExportBuilder.json(store: store))
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        assertCounts(plan, new: { _ in 0 }, updated: { _ in 0 }, unchanged: { fixtureCounts[$0]! })
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(unchanged: 1))
        var target = store
        Importer.apply(plan: plan, mode: .merge, to: &target)
        XCTAssertEqual(target, store)
    }

    func testJSONBackupMergedIntoAnotherStoreAddsItsFacts() throws {
        let original = Fixtures.store()
        let bundle = try ImportParser.parse(json: ExportBuilder.json(store: original))
        var target = Store(settings: Fixtures.settings)
        target.holidays = [Holiday(id: Fixtures.uuid(90), day: Fixtures.day(2027, 1, 1), name: "kept")]
        Importer.apply(plan: Importer.plan(store: target, bundle: bundle, mode: .merge), mode: .merge, to: &target)
        XCTAssertEqual(Set(target.holidays), Set(original.holidays + [Holiday(id: Fixtures.uuid(90), day: Fixtures.day(2027, 1, 1), name: "kept")]))
        XCTAssertEqual(Set(target.presence), Set(original.presence))
        XCTAssertEqual(Set(target.locations), Set(original.locations))   // real coordinates, not placeholders
        XCTAssertEqual(target.settings, original.settings)
        XCTAssertEqual(target.dismissedInboxKeys, [])                     // merge never touches inbox state
    }

    // MARK: Settings

    func testSettingsAreCountedAndApplied() {
        var store = Fixtures.store()
        var bundle = ImportParser.parse(workbook: Fixtures.workbook(store: store), store: store)
        bundle.settings?.graceMinutes = 12
        let plan = Importer.plan(store: store, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(updated: 1))
        Importer.apply(plan: plan, mode: .merge, to: &store)
        XCTAssertEqual(store.settings.graceMinutes, 12)

        let csvPlan = Importer.plan(store: store, bundle: ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store), mode: .merge)
        XCTAssertNil(csvPlan.counts["settings"])
    }

    func testPlanNeverMutatesTheStoreAndEmptyBundleIsANoOp() {
        var store = Fixtures.store()
        let before = store
        _ = Importer.plan(store: store, bundle: ImportParser.parse(csvText: ExportBuilder.csvTemplate(), store: store), mode: .merge)
        _ = Importer.plan(store: store, bundle: ImportBundle(), mode: .replace)
        XCTAssertEqual(store, before)
        let empty = Importer.plan(store: store, bundle: ImportBundle(), mode: .merge)
        assertCounts(empty, new: { _ in 0 }, updated: { _ in 0 }, unchanged: { _ in 0 })
        Importer.apply(plan: empty, mode: .merge, to: &store)
        XCTAssertEqual(store, before)
    }
}
