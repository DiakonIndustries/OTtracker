import Foundation
import OTModels
import OTLedger

/// What a geofence event did to the store, so the app can notify.
public struct InterpretationOutcome: Hashable, Sendable {
    /// The event as it was appended to `store.locationEvents`.
    public var event: LocationEvent
    /// The session that is open after the event (newly created or reopened by the flap filter).
    public var opened: PresenceSession?
    /// The session the event closed, with its final `exitedAt`.
    public var closed: PresenceSession?
    /// `opened` is a previously closed session whose exit was undone (flap filter).
    public var reopened: Bool
    /// An exit arrived while nothing was open; the Inbox raises `orphanExit:<eventID>`.
    public var orphanExit: Bool
    /// The event changed nothing (unknown location, or enter while already open there).
    public var ignored: Bool

    /// Memberwise initializer; the interpreter fills in only the fields that apply.
    public init(event: LocationEvent, opened: PresenceSession? = nil, closed: PresenceSession? = nil,
                reopened: Bool = false, orphanExit: Bool = false, ignored: Bool = false) {
        self.event = event
        self.opened = opened
        self.closed = closed
        self.reopened = reopened
        self.orphanExit = orphanExit
        self.ignored = ignored
    }

    /// True when the event mutated a presence session (opened, closed or reopened one).
    public var changedPresence: Bool { opened != nil || closed != nil }
}

/// See docs/SPEC.md section 5.1. Turns arrive/leave events into presence sessions.
public enum GeofenceInterpreter {
    /// Appends `event` to the audit log, then applies the §5.1 table to `store.presence`.
    /// Pure apart from the `inout` store: no clock, no time zone.
    @discardableResult
    public static func apply(_ event: LocationEvent, to store: inout Store) -> InterpretationOutcome {
        store.locationEvents.append(event)
        var outcome = InterpretationOutcome(event: event)

        guard store.location(id: event.locationID) != nil else {
            outcome.ignored = true
            return outcome
        }

        let openIndex = openSessionIndex(in: store)

        switch event.kind {
        case .enter:
            if let i = openIndex {
                if store.presence[i].locationID == event.locationID {
                    outcome.ignored = true
                    return outcome
                }
                // Device moved from M to L: close M, open L.
                outcome.closed = close(index: i, at: event.at, in: &store)
                outcome.opened = open(event, in: &store)
                return outcome
            }
            if let j = flapCandidateIndex(for: event, in: store) {
                store.presence[j].exitedAt = nil
                outcome.reopened = true
                outcome.opened = store.presence[j]
                return outcome
            }
            outcome.opened = open(event, in: &store)

        case .exit:
            guard let i = openIndex else {
                outcome.orphanExit = true
                return outcome
            }
            // Open at L or at M ≠ L: either way the device left, close it.
            outcome.closed = close(index: i, at: event.at, in: &store)
        }
        return outcome
    }

    // MARK: Helpers

    /// Index of the open session (latest `enteredAt` wins if the store somehow holds several).
    static func openSessionIndex(in store: Store) -> Int? {
        store.presence.indices
            .filter { store.presence[$0].isOpen }
            .max { store.presence[$0].enteredAt < store.presence[$1].enteredAt }
    }

    /// The most recently closed session at the event's location when it ended less than
    /// `flapMergeMinutes` before the event (and not after it). Nil when no flap applies.
    static func flapCandidateIndex(for event: LocationEvent, in store: Store) -> Int? {
        let flapSeconds = TimeInterval(store.settings.flapMergeMinutes * 60)
        guard flapSeconds > 0 else { return nil }
        let candidates = store.presence.indices.filter {
            let s = store.presence[$0]
            return s.locationID == event.locationID && s.exitedAt != nil
        }
        guard let j = candidates.max(by: { (store.presence[$0].exitedAt ?? .distantPast) < (store.presence[$1].exitedAt ?? .distantPast) }),
              let exitedAt = store.presence[j].exitedAt else { return nil }
        let sinceExit = event.at.timeIntervalSince(exitedAt)
        return sinceExit >= 0 && sinceExit < flapSeconds ? j : nil
    }

    /// Closes the session at `index` at `at`, clamped so it never ends before it began.
    @discardableResult
    static func close(index: Int, at: Date, in store: inout Store) -> PresenceSession {
        store.presence[index].exitedAt = max(at, store.presence[index].enteredAt)
        return store.presence[index]
    }

    /// Opens a new session for the event's location at the event's time, carrying its source.
    @discardableResult
    static func open(_ event: LocationEvent, in store: inout Store) -> PresenceSession {
        let session = PresenceSession(locationID: event.locationID, enteredAt: event.at, exitedAt: nil, source: event.source)
        store.presence.append(session)
        return session
    }
}
