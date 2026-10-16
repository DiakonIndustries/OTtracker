import Foundation
import OTModels

/// See docs/SPEC.md section 5.2. Only one active (running or paused) session at a time.
/// Every function takes the instant as a parameter and clamps it so segments never run backwards.
public enum ManualTimer {
    /// Why a timer transition was refused.
    public enum TimerError: Error, Equatable { case alreadyActive, nothingActive, notRunning, notPaused }

    /// Starts a new running session at `at`. Throws `.alreadyActive` when a session is running or paused.
    @discardableResult
    public static func start(store: inout Store, category: String, note: String = "", countsAs: ManualCountsAs = .extra, at: Date) throws -> ManualSession {
        guard store.activeManualSession == nil else { throw TimerError.alreadyActive }
        let session = ManualSession(category: category, note: note, countsAs: countsAs,
                                    segments: [ManualSegment(start: at)], isStopped: false, createdAt: at)
        store.manual.append(session)
        return session
    }

    /// Closes the open segment at `at` (clamped to its start). Throws `.notRunning` when paused or nothing is active.
    @discardableResult
    public static func pause(store: inout Store, at: Date) throws -> ManualSession {
        guard let i = activeIndex(in: store), store.manual[i].state == .running,
              let last = store.manual[i].segments.indices.last else { throw TimerError.notRunning }
        store.manual[i].segments[last].end = max(at, store.manual[i].segments[last].start)
        return store.manual[i]
    }

    /// Appends a new open segment at `at` (clamped to the previous segment's end). Throws `.notPaused` unless paused.
    @discardableResult
    public static func resume(store: inout Store, at: Date) throws -> ManualSession {
        guard let i = activeIndex(in: store), store.manual[i].state == .paused else { throw TimerError.notPaused }
        let floor = store.manual[i].segments.last.map { $0.end ?? $0.start } ?? at
        store.manual[i].segments.append(ManualSegment(start: max(at, floor)))
        return store.manual[i]
    }

    /// Closes any open segment at `at` (clamped) and marks the session stopped. Throws `.nothingActive`.
    @discardableResult
    public static func stop(store: inout Store, at: Date) throws -> ManualSession {
        guard let i = activeIndex(in: store) else { throw TimerError.nothingActive }
        if let last = store.manual[i].segments.indices.last, store.manual[i].segments[last].isOpen {
            store.manual[i].segments[last].end = max(at, store.manual[i].segments[last].start)
        }
        store.manual[i].isStopped = true
        return store.manual[i]
    }

    /// Removes the active (running or paused) session without keeping any of its time. Throws `.nothingActive`.
    @discardableResult
    public static func discard(store: inout Store) throws -> ManualSession {
        guard let i = activeIndex(in: store) else { throw TimerError.nothingActive }
        return store.manual.remove(at: i)
    }

    /// Records a finished block entered after the fact (`end` clamped to `start`); never touches the active timer.
    @discardableResult
    public static func addBlock(store: inout Store, category: String, note: String = "", countsAs: ManualCountsAs = .extra,
                                start: Date, end: Date, createdAt: Date) -> ManualSession {
        let block = ManualSession.block(category: category, note: note, countsAs: countsAs,
                                        start: start, end: max(start, end), createdAt: createdAt)
        store.manual.append(block)
        return block
    }

    /// Index of the active session in `store.manual`, matching `Store.activeManualSession`.
    static func activeIndex(in store: Store) -> Int? {
        store.manual.firstIndex { !$0.isStopped }
    }
}
