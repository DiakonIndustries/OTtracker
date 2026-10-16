import XCTest
import OTModels
import OTLedger
@testable import OTExchange

/// SPEC §6.2: the JSON backup is the full `Store`.
final class JSONBackupTests: XCTestCase {
    func testReplaceRoundTripIsExactlyTheOriginalStore() throws {
        let original = RichFixture.store()
        let data = try ExportBuilder.json(store: original)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "backup.json"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "Backup.JSON"), .json)
        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "nameless"), .json)
        let bundle = try ImportParser.parse(data: data, filename: "backup.Json", store: Store())
        XCTAssertEqual(bundle.fullStore, original)
        XCTAssertEqual(bundle.invalid, [])

        var target = Store()                                  // different zone, default settings, stray data
        target.holidays = [Holiday(day: RichFixture.day(2030, 1, 1), name: "gone")]
        target.dismissedInboxKeys = ["gone:1"]
        let plan = Importer.plan(store: target, bundle: bundle, mode: .replace)
        for key in ImportPlan.countKeys { XCTAssertEqual(plan.counts[key], ImportPlan.Counts(new: RichFixture.counts[key]!), key) }
        XCTAssertEqual(plan.counts["settings"], ImportPlan.Counts(new: 1))
        Importer.apply(plan: plan, mode: .replace, to: &target)
        XCTAssertEqual(target, original)                      // every field, including createdAt, notes and inbox keys
        XCTAssertEqual(RichFixture.dayResults(store: target), RichFixture.dayResults(store: original))
    }

    func testMergeIntoAnotherStoreMergesByID() throws {
        let original = RichFixture.store()
        let bundle = try ImportParser.parse(json: ExportBuilder.json(store: original))

        var target = Store(settings: RichFixture.settings)
        target.locations = original.locations
        // Same ID, different content → updated; a record only the target has → kept; same content → unchanged.
        var changed = original.presence[0]
        changed.note = "edited on the phone"
        target.presence = [changed, original.presence[1]]
        target.holidays = [Holiday(id: RichFixture.uuid(99), day: RichFixture.day(2027, 1, 1), name: "kept"),
                           original.holidays[0]]
        var renamed = original.manual[0]
        renamed.category = "Travel"                           // natural key changes, ID wins
        target.manual = [renamed]
        target.dismissedInboxKeys = ["mine:1"]

        let plan = Importer.plan(store: target, bundle: bundle, mode: .merge)
        XCTAssertEqual(plan.counts["presence"], ImportPlan.Counts(new: RichFixture.counts["presence"]! - 2, updated: 1, unchanged: 1))
        XCTAssertEqual(plan.counts["holidays"], ImportPlan.Counts(new: 2, updated: 0, unchanged: 1))
        XCTAssertEqual(plan.counts["manual"], ImportPlan.Counts(new: RichFixture.counts["manual"]! - 1, updated: 1))
        XCTAssertEqual(plan.counts["locations"], ImportPlan.Counts(unchanged: 2))
        XCTAssertEqual(plan.newLocationNames, [])
        XCTAssertEqual(plan.newTimeOffTypeNames, [])
        Importer.apply(plan: plan, mode: .merge, to: &target)

        XCTAssertEqual(target.presenceSession(id: original.presence[0].id), original.presence[0])     // the file's note won
        XCTAssertEqual(target.manualSession(id: original.manual[0].id), original.manual[0])
        XCTAssertEqual(Set(target.presence), Set(original.presence))
        XCTAssertEqual(Set(target.manual), Set(original.manual))
        XCTAssertEqual(Set(target.holidays), Set(original.holidays + [Holiday(id: RichFixture.uuid(99), day: RichFixture.day(2027, 1, 1), name: "kept")]))
        XCTAssertEqual(Set(target.timeOff), Set(original.timeOff))
        XCTAssertEqual(Set(target.locations), Set(original.locations))
        XCTAssertEqual(Set(target.schedules), Set(original.schedules))                             // JSON carries notes
        XCTAssertEqual(target.settings, original.settings)
        XCTAssertEqual(target.dismissedInboxKeys, ["mine:1"])                                         // merge never touches inbox state
    }

    func testMergeOfTheSameBackupTwiceIsANoOp() throws {
        let original = RichFixture.store()
        let bundle = try ImportParser.parse(json: ExportBuilder.json(store: original))
        var target = Store(settings: RichFixture.settings)
        Importer.apply(plan: Importer.plan(store: target, bundle: bundle, mode: .merge), mode: .merge, to: &target)
        let after = target
        let again = Importer.plan(store: target, bundle: bundle, mode: .merge)
        XCTAssertEqual(again.totalNew, 0)
        XCTAssertEqual(again.totalUpdated, 0)
        XCTAssertEqual(again.totalUnchanged, RichFixture.counts.values.reduce(0, +) + 1)   // + settings
        Importer.apply(plan: again, mode: .merge, to: &target)
        XCTAssertEqual(target, after)
    }

    func testNewerSchemaVersionAndUnknownKeysStillLoad() throws {
        let original = RichFixture.store()
        var object = try JSONSerialization.jsonObject(with: ExportBuilder.json(store: original)) as! [String: Any]
        object["schemaVersion"] = 99
        object["futureTopLevel"] = ["anything": [1, 2, 3]]
        var presence = object["presence"] as! [[String: Any]]
        presence[0]["futureField"] = "x"
        object["presence"] = presence
        var settings = object["settings"] as! [String: Any]
        settings["futureSetting"] = true
        object["settings"] = settings
        var manual = object["manual"] as! [[String: Any]]
        manual[0]["segments"] = (manual[0]["segments"] as! [[String: Any]]).map { seg in var s = seg; s["colour"] = "red"; return s }
        object["manual"] = manual
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertEqual(ImportParser.detectFormat(data: data, filename: "future.json"), .json)
        let bundle = try ImportParser.parse(data: data, filename: "future.json", store: Store())
        XCTAssertEqual(bundle.fullStore?.schemaVersion, 99)
        var expected = original
        expected.schemaVersion = 99
        XCTAssertEqual(bundle.fullStore, expected)
        XCTAssertEqual(bundle.invalid, [])

        var target = Store(settings: RichFixture.settings)
        Importer.apply(plan: Importer.plan(store: target, bundle: bundle, mode: .replace), mode: .replace, to: &target)
        XCTAssertEqual(target, expected)
    }

    func testOlderBackupsWithMissingCollectionsAndNumericDatesStillLoad() throws {
        let json = """
        {
          "schemaVersion": 0,
          "presence": [
            {"id": "\(RichFixture.uuid(1).uuidString)", "locationID": "\(RichFixture.plantA.uuidString)",
             "enteredAt": 1760000000, "exitedAt": "2026-10-14T21:42:00.000Z", "source": "geofence", "note": ""}
          ],
          "settings": {"graceMinutes": 9}
        }
        """
        let b = try ImportParser.parse(json: Data(json.utf8))
        let full = b.fullStore!
        XCTAssertEqual(full.schemaVersion, 0)
        XCTAssertEqual(full.presence.count, 1)
        XCTAssertEqual(full.presence[0].enteredAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(full.presence[0].exitedAt, ISO8601.plain.date(from: "2026-10-14T21:42:00Z"))
        XCTAssertEqual(full.settings.graceMinutes, 9)
        XCTAssertEqual(full.timeOffTypes, TimeOffType.builtIn)                // built-ins always come back
        XCTAssertEqual(b.presence[0].locationName, RichFixture.plantA.uuidString)   // unknown location: the ID is the name
        XCTAssertTrue(full.manual.isEmpty && full.timeOff.isEmpty && full.holidays.isEmpty)
    }

    func testNotABackupIsReportedNotCrashed() {
        for bad in ["[1,2,3]", "{\"presence\": \"nope\"}", "{\"settings\": 5}", "{ nope", "{\"presence\":[{\"id\":\"x\"}]}"] {
            XCTAssertThrowsError(try ImportParser.parse(data: Data(bad.utf8), filename: "b.json", store: Store()), bad) {
                guard case .unreadable(let why)? = $0 as? ImportError else { return XCTFail("expected unreadable for \(bad), got \($0)") }
                XCTAssertFalse(why.isEmpty)
            }
        }
    }
}
