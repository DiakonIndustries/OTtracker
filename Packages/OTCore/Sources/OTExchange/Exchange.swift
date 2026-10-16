import Foundation
import OTModels
import OTLedger
import OTXLSX
import OTCSV

/// Builds the Excel workbook described in docs/SPEC.md section 6.1.
public enum ExportBuilder {
    public static func workbook(store: Store, dayResults: [DayResult], from: DayKey, through: DayKey, now: Date) -> Workbook {
        fatalError("OTExchange.ExportBuilder not implemented yet")
    }

    /// `.xlsx` bytes for the range.
    public static func xlsx(store: Store, dayResults: [DayResult], from: DayKey, through: DayKey, now: Date) throws -> Data {
        try XLSXWriter.write(workbook(store: store, dayResults: dayResults, from: from, through: through, now: now),
                             timeZone: store.settings.timeZone)
    }

    /// Full-fidelity JSON backup of the store.
    public static func json(store: Store) throws -> Data { try StoreCodec.encode(store) }

    /// The CSV import template (header + example rows) from docs/IMPORT_TEMPLATE.md.
    public static func csvTemplate() -> String {
        fatalError("OTExchange.csvTemplate not implemented yet")
    }
}

/// Everything an import file can contribute. Rows are already typed; unknown names
/// (locations, time-off types) are carried as strings and resolved at plan time.
public struct ImportBundle: Hashable, Sendable {
    public struct PresenceRow: Hashable, Sendable {
        public var id: UUID?; public var locationName: String; public var enteredAt: Date; public var exitedAt: Date?
        public var source: EventSource; public var followingGapIsWork: Bool?; public var note: String
        public init(id: UUID? = nil, locationName: String, enteredAt: Date, exitedAt: Date?, source: EventSource = .imported, followingGapIsWork: Bool? = nil, note: String = "") {
            self.id = id; self.locationName = locationName; self.enteredAt = enteredAt; self.exitedAt = exitedAt
            self.source = source; self.followingGapIsWork = followingGapIsWork; self.note = note
        }
    }
    public struct TimeOffRow: Hashable, Sendable {
        public var id: UUID?; public var day: DayKey; public var typeName: String; public var seconds: Int; public var note: String
        public init(id: UUID? = nil, day: DayKey, typeName: String, seconds: Int, note: String = "") {
            self.id = id; self.day = day; self.typeName = typeName; self.seconds = seconds; self.note = note
        }
    }
    public struct InvalidRow: Hashable, Sendable {
        public var line: Int; public var reason: String
        public init(line: Int, reason: String) { self.line = line; self.reason = reason }
    }

    public var presence: [PresenceRow] = []
    public var manual: [ManualSession] = []
    public var timeOff: [TimeOffRow] = []
    public var holidays: [Holiday] = []
    public var adjustments: [Adjustment] = []
    public var locations: [WorkLocation] = []
    public var overrides: [DayOverride] = []
    public var schedules: [ScheduleVersion] = []
    public var events: [LocationEvent] = []
    public var timeOffTypes: [TimeOffType] = []
    public var leaveBalances: [LeaveBalanceConfig] = []
    public var settings: Settings? = nil
    /// Present only for a JSON backup: the whole store, used verbatim on Replace.
    public var fullStore: Store? = nil
    public var invalid: [InvalidRow] = []

    public init() {}

    public var isEmpty: Bool {
        presence.isEmpty && manual.isEmpty && timeOff.isEmpty && holidays.isEmpty && adjustments.isEmpty
            && locations.isEmpty && overrides.isEmpty && schedules.isEmpty && events.isEmpty && fullStore == nil
    }
}

public enum ImportFormat: String, Sendable { case xlsx, json, csv, holidaysCSV }

public enum ImportError: Error, Equatable {
    case unrecognizedFormat
    case unreadable(String)
}

/// Detects the format and parses into an `ImportBundle`. Never mutates the store.
public enum ImportParser {
    public static func detectFormat(data: Data, filename: String) -> ImportFormat? {
        fatalError("OTExchange.ImportParser not implemented yet")
    }

    public static func parse(data: Data, filename: String, store: Store) throws -> ImportBundle {
        fatalError("OTExchange.ImportParser not implemented yet")
    }
}

public enum ImportMode: String, Sendable { case merge, replace }

/// Counts shown on the preview screen before the user commits.
public struct ImportPlan: Hashable, Sendable {
    public struct Counts: Hashable, Sendable {
        public var new: Int = 0
        public var updated: Int = 0
        public var unchanged: Int = 0
        public init(new: Int = 0, updated: Int = 0, unchanged: Int = 0) { self.new = new; self.updated = updated; self.unchanged = unchanged }
    }
    public var bundle: ImportBundle
    public var counts: [String: Counts]      // keyed by record kind: presence, manual, timeOff, holidays, ...
    public var invalid: [ImportBundle.InvalidRow]
    public var newLocationNames: [String]
    public var newTimeOffTypeNames: [String]

    public init(bundle: ImportBundle, counts: [String: Counts], invalid: [ImportBundle.InvalidRow], newLocationNames: [String], newTimeOffTypeNames: [String]) {
        self.bundle = bundle; self.counts = counts; self.invalid = invalid
        self.newLocationNames = newLocationNames; self.newTimeOffTypeNames = newTimeOffTypeNames
    }

    public var totalNew: Int { counts.values.reduce(0) { $0 + $1.new } }
    public var totalUpdated: Int { counts.values.reduce(0) { $0 + $1.updated } }
}

public enum Importer {
    public static func plan(store: Store, bundle: ImportBundle, mode: ImportMode) -> ImportPlan {
        fatalError("OTExchange.Importer not implemented yet")
    }

    /// Applies the plan. `.merge` upserts; `.replace` wipes everything but settings first.
    public static func apply(plan: ImportPlan, mode: ImportMode, to store: inout Store) {
        fatalError("OTExchange.Importer not implemented yet")
    }
}
