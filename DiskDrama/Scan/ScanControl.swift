import Foundation
import os

/// Pause / cancel signalling between the UI and a running traversal (F07).
///
/// The traversal is a tight C loop on a background thread, not an async task, so
/// there is no `Task.isCancelled` to consult. This is the channel instead: a
/// lock-protected flag the UI writes and the loop polls.
///
/// `OSAllocatedUnfairLock` rather than `Mutex` because `Mutex` requires macOS 15
/// and this app targets 14. Rather than a bare `Bool` with an atomic, the state
/// is an enum so "paused" and "cancelled" cannot both be true and disagree.
final class ScanControl: Sendable {

    enum State {
        case running
        case paused
        case cancelled
    }

    /// What the traversal is doing right now, and since when.
    ///
    /// This exists because a progress callback cannot report a stall: it fires
    /// from inside the walk loop, so the moment the walk blocks the callback
    /// stops too and the UI freezes on its last value looking broken.
    ///
    /// Publishing the directory *before* entering it, into a lock the main thread
    /// can read independently, means a stall is visible precisely when nothing is
    /// happening — which is §2.3's requirement ("visible status to the user after
    /// 2s of waiting"). The watchdog reads this; the blocked thread does not have
    /// to be alive enough to say anything.
    struct Activity: Sendable {
        var path: String
        var since: Date
    }

    private let state = OSAllocatedUnfairLock(initialState: State.running)

    /// One activity per worker, not one for the walk.
    ///
    /// The walk used to be a single thread, so "what is the traversal doing" had
    /// exactly one answer. With a pool of workers there are N answers at once,
    /// and collapsing them into one shared slot would mean the last worker to
    /// enter a directory silently overwrites everyone else's — a busy worker
    /// would keep resetting the timestamp of a genuinely wedged one, and the
    /// stall would never be reported at all.
    private let activities = OSAllocatedUnfairLock(initialState: [Int: Activity]())

    var current: State { state.withLock { $0 } }

    /// The worst-stalled worker, which is the only one worth naming.
    ///
    /// While any worker is moving, `ScanEngine` keeps clearing the stall on its
    /// progress callbacks, so this surfaces only when the whole pool is stuck —
    /// which is exactly when the user needs to be told. One slow folder among
    /// eight busy workers is no longer a stall, because it no longer stops the
    /// scan.
    var currentActivity: Activity {
        activities.withLock { live in
            live.values.min(by: { $0.since < $1.since })
                ?? Activity(path: "", since: .distantPast)
        }
    }

    /// Called immediately before descending into a directory. Sets both the path
    /// being worked on and a fresh progress timestamp.
    func entering(_ path: String, worker: Int = 0) {
        activities.withLock { $0[worker] = Activity(path: path, since: Date()) }
    }

    /// Drops a worker's activity when it runs out of work, so an idle worker's
    /// last directory cannot masquerade as the longest-running stall.
    func idle(worker: Int) {
        activities.withLock { $0[worker] = nil }
    }

    /// Called from the walk's already-throttled progress tick.
    ///
    /// This is what makes the stall signal mean what it says. Timing from
    /// directory *entry* alone conflates "hasn't opened a new folder" with "isn't
    /// getting anywhere" — a single folder holding a hundred thousand files is
    /// steady progress, but looked identical to a wedged `open()` and got reported
    /// as a six-minute stall during testing.
    ///
    /// Refreshing the timestamp on any forward movement fixes that, and it stays
    /// correct for a real stall by construction: the progress tick lives inside
    /// the walk loop, so when the walk blocks, the heartbeat stops with it. The
    /// path deliberately does not change here — the last directory entered is
    /// still the most useful thing to name.
    func heartbeat(worker: Int = 0) {
        activities.withLock { $0[worker]?.since = Date() }
    }

    func pause() {
        state.withLock { if $0 == .running { $0 = .paused } }
    }

    func resume() {
        state.withLock { if $0 == .paused { $0 = .running } }
    }

    /// Terminal. A cancelled scan cannot be resumed — F07 is explicit that cancel
    /// discards partial results and leaves the previous snapshot authoritative.
    func cancel() {
        state.withLock { $0 = .cancelled }
    }

    /// Called from the traversal loop. Returns false when the scan should stop.
    ///
    /// Blocks while paused rather than spinning. `Task.yield()`-style busy-waiting
    /// is the antipattern §2.4 names explicitly; sleeping a background thread that
    /// has nothing to do is correct and costs nothing.
    func waitIfPausedAndContinue() -> Bool {
        while true {
            switch current {
            case .running:   return true
            case .cancelled: return false
            case .paused:    Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
}
