import Foundation
import os

/// The pool's shared to-do list, and the thing that decides when the walk is over.
///
/// ## Termination is the hard part
///
/// "The queue is empty" is not the same as "there is no more work". A worker
/// holding a claimed subtree can push new paths back at any moment, so an empty
/// queue with workers still running means *wait*, not *stop*. Getting this wrong
/// gives you either a scan that exits early with half the disk unaccounted for,
/// or one that hangs forever with every worker asleep waiting for the others.
///
/// The rule that makes it correct: a claim increments `active` **before** the
/// lock is released, so from the moment work leaves the queue it is accounted
/// for somewhere. The walk is over only when `pending` is empty *and* `active`
/// is zero — no work waiting and no worker able to produce any. Every worker
/// that finishes broadcasts, so the last one to put `active` back to zero wakes
/// everyone still asleep to observe it.
final class ScanWorkQueue: @unchecked Sendable {

    struct Item {
        /// Absolute path to walk.
        let path: String
        /// The node this subtree fills in. Already attached to its parent's
        /// `children` by whoever enqueued it, so the tree's shape is fixed
        /// before any worker touches it.
        let node: ScanNode
        /// True only for the configured scan roots. They count their own
        /// pre- and post-order visits; handed-off subtrees do not, because the
        /// worker that handed them off already counted both.
        let isRoot: Bool
    }

    private let condition = NSCondition()
    private var pending: [Item] = []
    private var active = 0
    private var waiting = 0
    private var stopped = false

    init(seed: [Item]) {
        pending = seed
    }

    /// Blocks until there is work, or until the walk is genuinely finished.
    func claim() -> Item? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if stopped { return nil }
            if let item = pending.popLast() {
                active += 1
                return item
            }
            // Nothing queued and nobody working: this is the real end.
            if active == 0 {
                condition.broadcast()
                return nil
            }
            waiting += 1
            condition.wait()
            waiting -= 1
        }
    }

    /// Called by a worker when it has finished the subtree it claimed.
    func finish() {
        condition.lock()
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    func push(_ item: Item) {
        condition.lock()
        pending.append(item)
        condition.signal()
        condition.unlock()
    }

    /// Wakes every sleeping worker and stops handing out work. Used for cancel.
    func stop() {
        condition.lock()
        stopped = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Whether handing work back would actually help right now.
    ///
    /// The handoff exists to feed *idle* workers. Splitting a subtree when
    /// everyone is already busy costs a queue round-trip and an extra
    /// `fts_open` and buys nothing, so the answer has to be no unless someone
    /// is genuinely sitting there with nothing to do.
    var wantsWork: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pending.isEmpty && waiting > 0
    }
}

/// Everything the workers share, behind the smallest locks that will do.
///
/// The counters are deliberately **not** here on the hot path. `visited` and
/// `bytesSeen` move once per filesystem entry — millions of times — and taking
/// a shared lock that often would serialise the very thing this change exists to
/// parallelise. Workers keep their own running totals and merge them in on the
/// throttled progress tick instead, which is a few times a second rather than a
/// few million.
///
/// What is here is genuinely shared and genuinely rare: blind spots, slow
/// directories, and the hard-link set.
final class ScanSharedState: @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock()

    private var _visited = 0
    private var _bytesSeen: Int64 = 0
    private var _blindSpots: [(path: String, reason: BlindSpotReason)] = []
    private var _slowDirectories: [(path: String, seconds: TimeInterval)] = []

    /// Hard links occupy their blocks once, however many names point at them.
    ///
    /// This was already shared state on one thread; on several it is the one
    /// piece of per-file bookkeeping that genuinely cannot be worker-local. Two
    /// workers in different directories can now reach the same inode at the same
    /// moment, and if both counted it the scan would overstate reclaimable
    /// space — the one direction a cleanup advisor must never err in. Only
    /// consulted for entries that actually have multiple links, so the common
    /// case never takes the lock at all.
    private var _seenHardLinks = Set<UInt64>()

    private var _lastProgressAt = Date.distantPast

    func noteBlindSpot(_ path: String, _ reason: BlindSpotReason) {
        lock.withLock { _blindSpots.append((path, reason)) }
    }

    func noteSlowDirectory(_ path: String, seconds: TimeInterval) {
        lock.withLock { _slowDirectories.append((path, seconds)) }
    }

    /// Returns true when this worker is the first to see the inode and should
    /// therefore count its blocks.
    func claimHardLink(_ key: UInt64) -> Bool {
        lock.withLock { _seenHardLinks.insert(key).inserted }
    }

    /// Folds a worker's local counters into the totals, and reports progress if
    /// the interval has elapsed. Returns the aggregate so the caller can hand it
    /// to the progress callback without a second lock.
    func merge(visited: Int, bytes: Int64) -> (visited: Int, bytes: Int64, shouldReport: Bool) {
        lock.withLock {
            _visited += visited
            _bytesSeen += bytes
            let now = Date()
            let due = now.timeIntervalSince(_lastProgressAt) >= FileTreeWalker.progressInterval
            if due { _lastProgressAt = now }
            return (_visited, _bytesSeen, due)
        }
    }

    var totals: (visited: Int, bytes: Int64) {
        lock.withLock { (_visited, _bytesSeen) }
    }

    var blindSpots: [(path: String, reason: BlindSpotReason)] {
        lock.withLock { _blindSpots }
    }

    var slowDirectories: [(path: String, seconds: TimeInterval)] {
        lock.withLock { _slowDirectories }
    }
}
