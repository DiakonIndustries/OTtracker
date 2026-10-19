import Foundation
import OTModels
import OTLedger
import OTXLSX
import OTCSV

// Shared value types of the exchange module. The behaviour lives in ExportBuilder.swift,
// ImportParser*.swift and Importer.swift.

/// Everything an import file can contribute. Rows are already typed; unknown names
/// (locations, time-off types) are carried as strings and resolved at plan time.
public struct ImportBundle: Hashable, Sendable {
    /// A presence session whose location is still a name (resolved when the import is applied).
    public struct PresenceRow: Hashable, Sendable {
        public var id: UUID?; public var locationName: String; public var enteredAt: Date; public var exitedAt: Date?
        public var source: EventSource; public var followingGapIsWork: Bool?; public var note: String
        public init(id: UUID? = nil, locationName: String, enteredAt: Date, exitedAt: Date?, source: EventSource = .imported, followingGapIsWork: Bool? = nil, note: String = "") {
            self.id = id; self.locationName = locationName; self.enteredAt = enteredAt; self.exitedAt = exitedAt
            self.source = source; self.followingGapIsWork = followingGapIsWork; self.note = note
        }
    }
    /// A time-off entry whose type is still a name (matched by name or kind, created as `.other` if unknown).
    public struct TimeOffRow: Hashable, Sendable {
        public var id: UUID?; public var day: DayKey; public var typeName: String; public var seconds: Int; public var note: String
        public init(id: UUID? = nil, day: DayKey, typeName: String, seconds: Int, note: String = "") {
            self.id = id; self.day = day; self.typeName = typeName; self.seconds = seconds; self.note = note
        }
    }
    /// A row the parser rejected: `line` is the CSV record number or the sheet row number (header = 1).
    public struct InvalidRow: Hashable, Sendable {
        public var line: Int; public var reason: String
        public init(line: Int, reason: String) { self.line = line; self.reason = reason }
    }

    /// Typed rows per record kind. Records carry their IDs when the file had them.
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
    /// Settings carried by a workbook's Settings sheet or a JSON backup; nil when the file has none.
    public var settings: Settings? = nil
    /// Present only for a JSON backup: the whole store, used verbatim on Replace.
    public var fullStore: Store? = nil
    /// Rows the parser rejected, with line/row numbers and reasons.
    public var invalid: [InvalidRow] = []

    /// An empty bundle.
    public init() {}

    /// True when the bundle carries no facts (settings, types and leave configs do not count).
    public var isEmpty: Bool {
        presence.isEmpty && manual.isEmpty && timeOff.isEmpty && holidays.isEmpty && adjustments.isEmpty
            && locations.isEmpty && overrides.isEmpty && schedules.isEmpty && events.isEmpty && fullStore == nil
    }
}

/// The file formats the importer understands. `holidaysCSV` is a two-column `date,name` file.
public enum ImportFormat: String, Sendable { case xlsx, json, csv, holidaysCSV }

/// Why an import file could not be turned into a bundle at all (row-level problems are `InvalidRow`s).
public enum ImportError: Error, Equatable {
    case unrecognizedFormat
    case unreadable(String)
}

/// Merge keeps what is in the store and upserts; Replace wipes everything but settings first.
public enum ImportMode: String, Sendable { case merge, replace }

/// Counts shown on the preview screen before the user commits.
public struct ImportPlan: Hashable, Sendable {
    /// New / updated / unchanged tallies for one record kind.
    public struct Counts: Hashable, Sendable {
        public var new: Int = 0
        public var updated: Int = 0
        public var unchanged: Int = 0
        /// Memberwise initialiser; all counts default to zero.
        public init(new: Int = 0, updated: Int = 0, unchanged: Int = 0) { self.new = new; self.updated = updated; self.unchanged = unchanged }
    }
    /// The parsed file this plan is for.
    public var bundle: ImportBundle
    /// Keyed by record kind (`countKeys`, plus `settings` when the file carries settings).
    public var counts: [String: Counts]
    /// Rows the parser rejected (copied from the bundle).
    public var invalid: [ImportBundle.InvalidRow]
    /// Location names that match nothing in the store and will be created as placeholders.
    public var newLocationNames: [String]
    /// Time-off type names that match nothing in the store and will be created as `.other` types.
    public var newTimeOffTypeNames: [String]

    /// Memberwise initialiser.
    public init(bundle: ImportBundle, counts: [String: Counts], invalid: [ImportBundle.InvalidRow], newLocationNames: [String], newTimeOffTypeNames: [String]) {
        self.bundle = bundle; self.counts = counts; self.invalid = invalid
        self.newLocationNames = newLocationNames; self.newTimeOffTypeNames = newTimeOffTypeNames
    }

    /// Sum of `new` over every kind.
    public var totalNew: Int { counts.values.reduce(0) { $0 + $1.new } }
    /// Sum of `updated` over every kind.
    public var totalUpdated: Int { counts.values.reduce(0) { $0 + $1.updated } }
    /// Sum of `unchanged` over every kind.
    public var totalUnchanged: Int { counts.values.reduce(0) { $0 + $1.unchanged } }

    /// The keys `counts` always carries, in display order.
    public static let countKeys = ["presence", "manual", "timeOff", "holidays", "adjustments", "locations",
                                   "overrides", "schedules", "events", "timeOffTypes", "leaveBalances"]
}
