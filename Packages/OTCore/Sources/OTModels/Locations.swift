import Foundation

public struct WorkLocation: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var isActive: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double,
                radiusMeters: Double = 200, isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

public enum EventSource: String, Codable, Sendable, CaseIterable {
    case geofence, manual, imported
}

public enum LocationEventKind: String, Codable, Sendable, CaseIterable {
    case enter, exit
}

/// Append-only audit record of every arrival/departure the app learned about.
public struct LocationEvent: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var locationID: UUID
    public var kind: LocationEventKind
    public var at: Date
    public var source: EventSource

    public init(id: UUID = UUID(), locationID: UUID, kind: LocationEventKind, at: Date, source: EventSource = .geofence) {
        self.id = id
        self.locationID = locationID
        self.kind = kind
        self.at = at
        self.source = source
    }
}

/// A stretch of time at one work location.
public struct PresenceSession: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var locationID: UUID
    public var enteredAt: Date
    public var exitedAt: Date?
    public var source: EventSource
    /// Decision about the absence that follows this session (before the next presence
    /// on the same day). nil = undecided → the default from the spec applies.
    public var followingGapIsWork: Bool?
    public var note: String

    public init(id: UUID = UUID(), locationID: UUID, enteredAt: Date, exitedAt: Date? = nil,
                source: EventSource = .geofence, followingGapIsWork: Bool? = nil, note: String = "") {
        self.id = id
        self.locationID = locationID
        self.enteredAt = enteredAt
        self.exitedAt = exitedAt
        self.source = source
        self.followingGapIsWork = followingGapIsWork
        self.note = note
    }

    public var isOpen: Bool { exitedAt == nil }

    public func interval(now: Date) -> Interval {
        Interval(start: enteredAt, end: exitedAt ?? max(now, enteredAt))
    }

    public func seconds(now: Date) -> Int { interval(now: now).seconds }
}
