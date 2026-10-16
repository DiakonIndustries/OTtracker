import Foundation
import OTModels

/// What the UI still has to collect before an Inbox action can be applied.
public enum InputKind: Equatable, Sendable {
    /// A single instant (a stop, exit or arrival time).
    case dateTime
    /// A number of seconds.
    case duration
    /// The time-off booking form, preset to this kind.
    case timeOffForm(TimeOffKind)
    /// The manual session form (category, counts-as, start and end).
    case manualForm
    /// The presence session editor for the item's subject.
    case sessionEditor
}

/// Result of `InboxResolver.apply`.
public enum ResolutionOutcome: Equatable, Sendable {
    /// The store was mutated; the item will disappear on the next `InboxEngine.items`.
    case applied
    /// Nothing changed; collect this input and call again.
    case needsInput(InputKind)
    /// The action is not handled here (export actions) or its subject no longer exists.
    case notApplicable
}

/// Applies an `InboxAction` to the store. See docs/SPEC.md section 5.3.
public enum InboxResolver {
    /// Note used on presence sessions created from `.setArrivalTime`.
    public static let missedArrivalNote = "Added from missed arrival"
    /// Category of the regular manual session created by `.markRemoteDay`.
    public static let remoteDayCategory = "Remote day"

    /// Mutates `store` for `action` on `item`. `date`, `seconds` and `window` carry the
    /// user's input where an action needs one; when missing, `.needsInput` says what to ask for.
    @discardableResult
    public static func apply(_ action: InboxAction, item: InboxItem, store: inout Store, now: Date,
                             date: Date? = nil, seconds: Int? = nil, window: Interval? = nil) -> ResolutionOutcome {
        if action.isDismissal {
            store.dismissInbox(item.key)
            return .applied
        }

        switch action {
        case .markGapWork:
            return setGapDecision(true, item: item, store: &store)

        case .markGapPersonal:
            return setGapDecision(false, item: item, store: &store)

        case .excuseDay:
            var o = store.overrideOrNew(for: item.day)
            o.excused = true
            store.setOverride(o)
            return .applied

        case .countEarlyArrival:
            var o = store.overrideOrNew(for: item.day)
            o.countEarlyArrival = true
            store.setOverride(o)
            store.dismissInbox(item.key)
            return .applied

        case .markRemoteDay:
            guard let window, !window.isEmpty else { return .needsInput(.manualForm) }
            ManualTimer.addBlock(store: &store, category: remoteDayCategory, note: "", countsAs: .regular,
                                 start: window.start, end: window.end, createdAt: now)
            return .applied

        case .stopTimerNow:
            return stopTimer(item: item, store: &store, at: now)

        case .setTimerStop:
            guard let date else { return .needsInput(.dateTime) }
            return stopTimer(item: item, store: &store, at: date)

        case .setExitTime:
            guard let date else { return .needsInput(.dateTime) }
            guard let i = presenceIndex(item, store) else { return .notApplicable }
            store.presence[i].exitedAt = max(date, store.presence[i].enteredAt)
            return .applied

        case .setArrivalTime:
            guard let date else { return .needsInput(.dateTime) }
            guard let id = item.subjectID, let event = store.locationEvents.first(where: { $0.id == id }) else { return .notApplicable }
            let session = PresenceSession(locationID: event.locationID, enteredAt: min(date, event.at), exitedAt: event.at,
                                          source: .manual, followingGapIsWork: nil, note: missedArrivalNote)
            store.presence.append(session)
            store.dismissInbox(item.key)
            return .applied

        case .removeSession, .deleteSession:
            guard let i = presenceIndex(item, store) else { return .notApplicable }
            store.presence.remove(at: i)
            return .applied

        case .addTimeOff(let kind):
            let typeID: UUID
            switch kind {
            case .pto: typeID = TimeOffType.ptoID
            case .personal: typeID = TimeOffType.personalID
            case .flex: typeID = TimeOffType.flexID
            case .other: return .needsInput(.timeOffForm(.other))
            }
            guard let seconds, seconds > 0 else { return .needsInput(.timeOffForm(kind)) }
            if store.timeOffType(id: typeID) == nil,
               let builtIn = TimeOffType.builtIn.first(where: { $0.id == typeID }) {
                store.upsert(builtIn)
            }
            store.upsert(TimeOffEntry(day: item.day, typeID: typeID, seconds: seconds))
            return .applied

        case .enterHours:
            return .needsInput(.manualForm)

        case .adjustSession:
            return .needsInput(.sessionEditor)

        case .emailExport, .shareExport:
            return .notApplicable

        case .keepDeficit, .confirm, .dontCountEarlyArrival, .stillWorking, .ignore, .dismiss:
            // Handled above via `isDismissal`; listed so the switch stays exhaustive.
            store.dismissInbox(item.key)
            return .applied
        }
    }

    // MARK: Helpers

    static func presenceIndex(_ item: InboxItem, _ store: Store) -> Int? {
        guard let id = item.subjectID else { return nil }
        return store.presence.firstIndex { $0.id == id }
    }

    static func setGapDecision(_ isWork: Bool, item: InboxItem, store: inout Store) -> ResolutionOutcome {
        guard let i = presenceIndex(item, store) else { return .notApplicable }
        store.presence[i].followingGapIsWork = isWork
        return .applied
    }

    /// Stops the active timer, refusing when the item points at a different session.
    static func stopTimer(item: InboxItem, store: inout Store, at: Date) -> ResolutionOutcome {
        guard let active = store.activeManualSession else { return .notApplicable }
        if let subject = item.subjectID, subject != active.id { return .notApplicable }
        do {
            try ManualTimer.stop(store: &store, at: at)
            return .applied
        } catch {
            return .notApplicable
        }
    }
}
