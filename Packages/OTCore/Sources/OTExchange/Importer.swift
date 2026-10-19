import Foundation
import OTModels

/// Previews and applies an `ImportBundle` (SPEC §6.3).
///
/// Records match an existing one by ID when the ID is known to the store, otherwise by a
/// natural key (presence: location + entered + exited; manual: category + first start + last end;
/// time off: day + type + seconds; holiday: day; adjustment: day + seconds + reason; location: name;
/// override: day; schedule: effectiveFrom; event: location + kind + time; type: name). A match with
/// identical content (whole seconds) is *unchanged*, otherwise *updated*; no match is *new*.
/// Fields a file format cannot carry (createdAt, a schedule's note, the source of a CSV presence row)
/// are taken from the matched record.
public enum Importer {
    /// Dry run: the counts the preview screen shows. In `.replace` mode everything is new.
    public static func plan(store: Store, bundle: ImportBundle, mode: ImportMode) -> ImportPlan {
        var working = mode == .replace ? wiped(store) : store
        let tally = MergeEngine.run(bundle: bundle, mode: mode, into: &working)
        return ImportPlan(bundle: bundle, counts: tally.counts, invalid: bundle.invalid,
                          newLocationNames: tally.newLocationNames, newTimeOffTypeNames: tally.newTimeOffTypeNames)
    }

    /// Applies the plan. `.merge` upserts; `.replace` wipes everything but settings and the built-in
    /// time-off types first (a JSON backup in `.replace` mode becomes the store wholesale).
    public static func apply(plan: ImportPlan, mode: ImportMode, to store: inout Store) {
        if mode == .replace { store = wiped(store) }
        _ = MergeEngine.run(bundle: plan.bundle, mode: mode, into: &store)
    }

    /// A store with the same settings and schema version but no facts (built-in types and the
    /// default leave configs come back with it).
    static func wiped(_ store: Store) -> Store {
        var s = Store(settings: store.settings)
        s.schemaVersion = store.schemaVersion
        return s
    }
}

/// The one code path behind `plan` (on a copy) and `apply` (on the real store).
enum MergeEngine {
    enum Outcome { case new, updated, unchanged }

    struct Tally {
        var counts: [String: ImportPlan.Counts] = Dictionary(uniqueKeysWithValues: ImportPlan.countKeys.map { ($0, ImportPlan.Counts()) })
        var newLocationNames: [String] = []
        var newTimeOffTypeNames: [String] = []
        /// Replace mode: the store was wiped, so every record counts as new (built-in types included).
        var forceNew = false

        mutating func add(_ kind: String, _ outcome: Outcome) {
            var c = counts[kind] ?? ImportPlan.Counts()
            switch forceNew ? .new : outcome {
            case .new: c.new += 1
            case .updated: c.updated += 1
            case .unchanged: c.unchanged += 1
            }
            counts[kind] = c
        }
    }

    static func run(bundle: ImportBundle, mode: ImportMode, into store: inout Store) -> Tally {
        var tally = Tally()
        tally.forceNew = mode == .replace
        if mode == .replace, let full = bundle.fullStore {
            store = full
            // A backup from a newer app may carry a higher schema number; what was decoded is
            // this app's schema, so it is stamped as such.
            store.schemaVersion = min(full.schemaVersion, Store.currentSchemaVersion)
            for _ in full.presence { tally.add("presence", .new) }
            for _ in full.manual { tally.add("manual", .new) }
            for _ in full.timeOff { tally.add("timeOff", .new) }
            for _ in full.holidays { tally.add("holidays", .new) }
            for _ in full.adjustments { tally.add("adjustments", .new) }
            for _ in full.locations { tally.add("locations", .new) }
            for _ in full.overrides { tally.add("overrides", .new) }
            for _ in full.schedules { tally.add("schedules", .new) }
            for _ in full.locationEvents { tally.add("events", .new) }
            for _ in full.timeOffTypes { tally.add("timeOffTypes", .new) }
            for _ in full.leaveBalances { tally.add("leaveBalances", .new) }
            tally.add("settings", .new)
            return tally
        }

        // Reference data first so facts can resolve names against it. A file record that matched
        // an existing one by name keeps the existing ID; rows referring to the file's ID follow.
        var locationIDRemap: [UUID: UUID] = [:]
        var typeIDRemap: [UUID: UUID] = [:]

        for var loc in bundle.locations {
            loc.createdAt = loc.createdAt.wholeSeconds
            let existing = store.location(id: loc.id) ?? store.location(named: loc.name)
            if let e = existing {
                if e.id != loc.id { locationIDRemap[loc.id] = e.id }
                loc.id = e.id; loc.createdAt = e.createdAt
            }
            tally.add("locations", outcome(loc, existing))
            if loc != existing { store.upsert(loc) }
        }

        for var t in bundle.timeOffTypes {
            let existing = store.timeOffType(id: t.id) ?? store.timeOffTypes.first { ExchangeFormat.nameKey($0.name) == ExchangeFormat.nameKey(t.name) }
            if let e = existing {
                if e.id != t.id { typeIDRemap[t.id] = e.id }
                t.id = e.id
            }
            tally.add("timeOffTypes", outcome(t, existing))
            if t != existing { store.upsert(t) }
        }

        for var cfg in bundle.leaveBalances {
            cfg.typeID = typeIDRemap[cfg.typeID] ?? cfg.typeID
            let existing = store.leaveBalances.first { $0.typeID == cfg.typeID }
            tally.add("leaveBalances", outcome(cfg, existing))
            if cfg != existing { store.upsert(cfg) }
        }

        for var v in bundle.schedules {
            let existing = store.schedules.first { $0.id == v.id } ?? store.schedules.first { $0.effectiveFrom == v.effectiveFrom }
            if let e = existing { v.id = e.id; if v.note.isEmpty { v.note = e.note } }
            tally.add("schedules", outcome(v, existing))
            if v != existing { store.upsert(v) }
        }

        for var o in bundle.overrides {
            let existing = store.overrides.first { $0.id == o.id } ?? store.override(for: o.day)
            if let e = existing { o.id = e.id }
            tally.add("overrides", outcome(o, existing))
            if o != existing {
                store.overrides.removeAll { $0.id == o.id || $0.day == o.day }
                store.overrides.append(o)
            }
        }

        for var h in bundle.holidays {
            let existing = store.holidays.first { $0.id == h.id } ?? store.holiday(on: h.day)
            if let e = existing { h.id = e.id }
            tally.add("holidays", outcome(h, existing))
            if h != existing { store.upsert(h) }
        }

        for var a in bundle.adjustments {
            let existing = store.adjustments.first { $0.id == a.id }
                ?? store.adjustments.first { $0.day == a.day && $0.seconds == a.seconds && $0.reason == a.reason }
            if let e = existing { a.id = e.id }
            tally.add("adjustments", outcome(a, existing))
            if a != existing { store.upsert(a) }
        }

        // Facts.
        for row in bundle.presence {
            let locationID = resolveLocation(named: row.locationName, bundle: bundle, store: &store, tally: &tally)
            var s = PresenceSession(id: row.id ?? UUID(), locationID: locationID, enteredAt: row.enteredAt.wholeSeconds,
                                    exitedAt: row.exitedAt?.wholeSeconds, source: row.source,
                                    followingGapIsWork: row.followingGapIsWork, note: row.note)
            let existing = row.id.flatMap { store.presenceSession(id: $0) }
                ?? store.presence.first { $0.locationID == s.locationID && $0.enteredAt.wholeSeconds == s.enteredAt && $0.exitedAt?.wholeSeconds == s.exitedAt }
            if let e = existing {
                s.id = e.id
                if row.source == .imported { s.source = e.source }
            }
            tally.add("presence", outcome(s, existing))
            if s != existing { store.upsert(s) }
        }

        for var m in bundle.manual {
            m.segments = m.segments.map { ManualSegment(start: $0.start.wholeSeconds, end: $0.end?.wholeSeconds) }
            m.createdAt = m.createdAt.wholeSeconds
            let firstStart = m.segments.first?.start
            let lastEnd = m.segments.last?.end
            let existing = store.manualSession(id: m.id) ?? store.manual.first {
                $0.category == m.category && $0.segments.first?.start.wholeSeconds == firstStart && $0.segments.last?.end?.wholeSeconds == lastEnd
            }
            if let e = existing { m.id = e.id; m.createdAt = e.createdAt }
            tally.add("manual", outcome(m, existing))
            if m != existing { store.upsert(m) }
        }

        for row in bundle.timeOff {
            let typeID = resolveTimeOffType(named: row.typeName, store: &store, tally: &tally)
            var t = TimeOffEntry(id: row.id ?? UUID(), day: row.day, typeID: typeID, seconds: row.seconds, note: row.note)
            let existing = row.id.flatMap { id in store.timeOff.first { $0.id == id } }
                ?? store.timeOff.first { $0.day == t.day && $0.typeID == t.typeID && $0.seconds == t.seconds }
            if let e = existing { t.id = e.id }
            tally.add("timeOff", outcome(t, existing))
            if t != existing { store.upsert(t) }
        }

        for var e in bundle.events {
            e.at = e.at.wholeSeconds
            e.locationID = locationIDRemap[e.locationID] ?? e.locationID
            let existing = store.locationEvents.first { $0.id == e.id }
                ?? store.locationEvents.first { $0.locationID == e.locationID && $0.kind == e.kind && $0.at.wholeSeconds == e.at }
            if let x = existing { e.id = x.id }
            tally.add("events", outcome(e, existing))
            if e != existing {
                if let i = store.locationEvents.firstIndex(where: { $0.id == e.id }) { store.locationEvents[i] = e } else { store.locationEvents.append(e) }
            }
        }

        // Settings travel with a Replace only: a Merge adds records, it never changes how this
        // phone is configured (grace, categories, time zone, export email, onboarding state).
        if mode == .replace, let settings = bundle.settings {
            tally.add("settings", settings == store.settings ? .unchanged : .updated)
            store.settings = settings
        }

        return tally
    }

    static func outcome<T: Equatable>(_ incoming: T, _ existing: T?) -> Outcome {
        guard let e = existing else { return .new }
        return e == incoming ? .unchanged : .updated
    }

    /// The store's location with that name, else a placeholder (0, 0, 200 m, inactive) created once.
    /// A UUID in place of a name (the export's fallback for a location that no longer exists) is
    /// that location's ID, kept as it is rather than turned into a UUID-named placeholder.
    static func resolveLocation(named name: String, bundle: ImportBundle, store: inout Store, tally: inout Tally) -> UUID {
        let trimmed = ExchangeFormat.trim(name)
        if let id = UUID(uuidString: trimmed) { return store.location(id: id)?.id ?? id }
        let effectiveName = trimmed.isEmpty ? "Unknown location" : trimmed
        if let l = store.location(named: effectiveName) { return l.id }
        let key = ExchangeFormat.nameKey(effectiveName)
        let firstSeen = bundle.presence.filter { ExchangeFormat.nameKey($0.locationName) == key }.map { $0.enteredAt.wholeSeconds }.min()
            ?? Date(timeIntervalSince1970: 0)
        let placeholder = WorkLocation(name: effectiveName, latitude: 0, longitude: 0, radiusMeters: 200, isActive: false, createdAt: firstSeen)
        store.upsert(placeholder)
        tally.add("locations", .new)
        tally.newLocationNames.append(effectiveName)
        return placeholder.id
    }

    /// The store's time-off type with that name or kind, else a placeholder `.other` type created once.
    static func resolveTimeOffType(named name: String, store: inout Store, tally: inout Tally) -> UUID {
        let trimmed = ExchangeFormat.trim(name)
        let effectiveName = trimmed.isEmpty ? "Other" : trimmed
        if let t = store.timeOffType(named: effectiveName) { return t.id }
        let placeholder = TimeOffType(name: effectiveName, kind: .other, tracksBalance: false, deductsFromBank: false)
        store.upsert(placeholder)
        tally.add("timeOffTypes", .new)
        tally.newTimeOffTypeNames.append(effectiveName)
        return placeholder.id
    }
}
