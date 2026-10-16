import Foundation

public enum ManualCountsAs: String, Codable, Sendable, CaseIterable {
    /// Adds to the bank regardless of schedule (default).
    case extra
    /// Treated like presence: fills the scheduled window first.
    case regular
}

public struct ManualSegment: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public var isOpen: Bool { end == nil }

    public func interval(now: Date) -> Interval {
        Interval(start: start, end: end ?? max(now, start))
    }
}

/// Timer-based or hand-entered work outside the geofences.
public struct ManualSession: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var category: String
    public var note: String
    public var countsAs: ManualCountsAs
    public var segments: [ManualSegment]
    public var isStopped: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), category: String, note: String = "", countsAs: ManualCountsAs = .extra,
                segments: [ManualSegment] = [], isStopped: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.category = category
        self.note = note
        self.countsAs = countsAs
        self.segments = segments
        self.isStopped = isStopped
        self.createdAt = createdAt
    }

    public enum State: String, Codable, Sendable { case running, paused, stopped }

    public var state: State {
        if isStopped { return .stopped }
        if let last = segments.last, last.isOpen { return .running }
        return .paused
    }

    public var isActive: Bool { !isStopped }
    public var startedAt: Date? { segments.first?.start }
    public var endedAt: Date? { isStopped ? segments.last?.end : nil }

    /// Closed and open segments as intervals; the open one runs to `now`.
    public func intervals(now: Date) -> [Interval] {
        segments.map { $0.interval(now: now) }
    }

    public func activeSeconds(now: Date) -> Int {
        intervals(now: now).reduce(0) { $0 + $1.seconds }
    }

    /// A finished block entered after the fact.
    public static func block(category: String, note: String = "", countsAs: ManualCountsAs = .extra,
                             start: Date, end: Date, id: UUID = UUID(), createdAt: Date = Date()) -> ManualSession {
        ManualSession(id: id, category: category, note: note, countsAs: countsAs,
                      segments: [ManualSegment(start: start, end: max(start, end))], isStopped: true, createdAt: createdAt)
    }
}
