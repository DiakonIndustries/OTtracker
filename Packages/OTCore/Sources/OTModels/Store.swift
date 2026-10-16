import Foundation

/// The entire app state. Facts and decisions only; every number is derived from these.
public struct Store: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var schedules: [ScheduleVersion]
    public var overrides: [DayOverride]
    public var holidays: [Holiday]
    public var locations: [WorkLocation]
    public var locationEvents: [LocationEvent]
    public var presence: [PresenceSession]
    public var manual: [ManualSession]
    public var timeOffTypes: [TimeOffType]
    public var timeOff: [TimeOffEntry]
    public var leaveBalances: [LeaveBalanceConfig]
    public var adjustments: [Adjustment]
    public var dismissedInboxKeys: Set<String>
    public var settings: Settings

    public init(settings: Settings = Settings()) {
        schemaVersion = Store.currentSchemaVersion
        schedules = []
        overrides = []
        holidays = []
        locations = []
        locationEvents = []
        presence = []
        manual = []
        timeOffTypes = TimeOffType.builtIn
        timeOff = []
        leaveBalances = [LeaveBalanceConfig(typeID: TimeOffType.ptoID), LeaveBalanceConfig(typeID: TimeOffType.personalID)]
        adjustments = []
        dismissedInboxKeys = []
        self.settings = settings
    }

    // MARK: Lookups

    public var calendar: Calendar { settings.calendar }

    public var hasSchedule: Bool { !schedules.isEmpty }

    public func location(id: UUID) -> WorkLocation? { locations.first { $0.id == id } }

    public func location(named name: String) -> WorkLocation? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return locations.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == n }
    }

    public func timeOffType(id: UUID) -> TimeOffType? { timeOffTypes.first { $0.id == id } }

    public func timeOffType(named name: String) -> TimeOffType? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return timeOffTypes.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == n }
            ?? timeOffTypes.first { $0.kind.rawValue == n }
    }

    public func override(for day: DayKey) -> DayOverride? { overrides.first { $0.day == day } }

    public func holiday(on day: DayKey) -> Holiday? { holidays.first { $0.day == day } }

    /// The schedule version in force on `day`: latest `effectiveFrom <= day`.
    public func scheduleVersion(for day: DayKey) -> ScheduleVersion? {
        schedules.filter { $0.effectiveFrom <= day }.max { $0.effectiveFrom < $1.effectiveFrom }
    }

    public var activeManualSession: ManualSession? { manual.first { !$0.isStopped } }

    public var openPresenceSession: PresenceSession? { presence.first { $0.isOpen } }

    public func presenceSession(id: UUID) -> PresenceSession? { presence.first { $0.id == id } }

    public func manualSession(id: UUID) -> ManualSession? { manual.first { $0.id == id } }

    public func timeOff(on day: DayKey) -> [TimeOffEntry] { timeOff.filter { $0.day == day } }

    public func adjustments(on day: DayKey) -> [Adjustment] { adjustments.filter { $0.day == day } }

    // MARK: Mutations (small, generic helpers; features compose these)

    /// Replaces the override for that day, or inserts it. Empty overrides are removed.
    public mutating func setOverride(_ o: DayOverride) {
        overrides.removeAll { $0.day == o.day }
        if !o.isEmpty { overrides.append(o) }
    }

    public func overrideOrNew(for day: DayKey) -> DayOverride {
        override(for: day) ?? DayOverride(day: day)
    }

    public mutating func upsert(_ s: PresenceSession) {
        if let i = presence.firstIndex(where: { $0.id == s.id }) { presence[i] = s } else { presence.append(s) }
    }

    public mutating func upsert(_ m: ManualSession) {
        if let i = manual.firstIndex(where: { $0.id == m.id }) { manual[i] = m } else { manual.append(m) }
    }

    public mutating func upsert(_ t: TimeOffEntry) {
        if let i = timeOff.firstIndex(where: { $0.id == t.id }) { timeOff[i] = t } else { timeOff.append(t) }
    }

    public mutating func upsert(_ h: Holiday) {
        if let i = holidays.firstIndex(where: { $0.id == h.id }) { holidays[i] = h } else { holidays.append(h) }
    }

    public mutating func upsert(_ l: WorkLocation) {
        if let i = locations.firstIndex(where: { $0.id == l.id }) { locations[i] = l } else { locations.append(l) }
    }

    public mutating func upsert(_ a: Adjustment) {
        if let i = adjustments.firstIndex(where: { $0.id == a.id }) { adjustments[i] = a } else { adjustments.append(a) }
    }

    public mutating func upsert(_ v: ScheduleVersion) {
        if let i = schedules.firstIndex(where: { $0.id == v.id }) { schedules[i] = v } else { schedules.append(v) }
    }

    public mutating func upsert(_ t: TimeOffType) {
        if let i = timeOffTypes.firstIndex(where: { $0.id == t.id }) { timeOffTypes[i] = t } else { timeOffTypes.append(t) }
    }

    public mutating func upsert(_ b: LeaveBalanceConfig) {
        if let i = leaveBalances.firstIndex(where: { $0.typeID == b.typeID }) { leaveBalances[i] = b } else { leaveBalances.append(b) }
    }

    public mutating func dismissInbox(_ key: String) { dismissedInboxKeys.insert(key) }

    // MARK: Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, schedules, overrides, holidays, locations, locationEvents, presence, manual,
             timeOffTypes, timeOff, leaveBalances, adjustments, dismissedInboxKeys, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        var s = Store(settings: settings)
        s.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        s.schedules = try c.decodeIfPresent([ScheduleVersion].self, forKey: .schedules) ?? []
        s.overrides = try c.decodeIfPresent([DayOverride].self, forKey: .overrides) ?? []
        s.holidays = try c.decodeIfPresent([Holiday].self, forKey: .holidays) ?? []
        s.locations = try c.decodeIfPresent([WorkLocation].self, forKey: .locations) ?? []
        s.locationEvents = try c.decodeIfPresent([LocationEvent].self, forKey: .locationEvents) ?? []
        s.presence = try c.decodeIfPresent([PresenceSession].self, forKey: .presence) ?? []
        s.manual = try c.decodeIfPresent([ManualSession].self, forKey: .manual) ?? []
        s.timeOffTypes = try c.decodeIfPresent([TimeOffType].self, forKey: .timeOffTypes) ?? TimeOffType.builtIn
        s.timeOff = try c.decodeIfPresent([TimeOffEntry].self, forKey: .timeOff) ?? []
        s.leaveBalances = try c.decodeIfPresent([LeaveBalanceConfig].self, forKey: .leaveBalances) ?? s.leaveBalances
        s.adjustments = try c.decodeIfPresent([Adjustment].self, forKey: .adjustments) ?? []
        s.dismissedInboxKeys = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedInboxKeys) ?? []
        // Built-in types must always exist.
        for t in TimeOffType.builtIn where !s.timeOffTypes.contains(where: { $0.id == t.id }) {
            s.timeOffTypes.append(t)
        }
        self = s
    }
}

// MARK: - JSON codec shared by persistence, backup and export

public enum StoreCodec {
    /// ISO 8601 at whole-second precision (all ledger arithmetic is integer seconds).
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.plain.string(from: date.wholeSeconds))
        }
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = ISO8601.fractional.date(from: s) ?? ISO8601.plain.date(from: s) { return date }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            // Tolerate numeric seconds since 1970.
            let secs = try c.decode(Double.self)
            return Date(timeIntervalSince1970: secs)
        }
        return d
    }

    public static func encode(_ store: Store) throws -> Data { try encoder().encode(store) }

    public static func decode(_ data: Data) throws -> Store { try decoder().decode(Store.self, from: data) }
}

public extension Date {
    /// Truncated to whole seconds; what persistence stores.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// Shared ISO 8601 formatters (thread-safe in Foundation).
public enum ISO8601 {
    public static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
