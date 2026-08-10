import Foundation
import Darwin
import os

/// The traversal. Pure C-level filesystem walking, no Foundation `URL` anywhere.
///
/// ## Why `fts(3)` and not `FileManager`
///
/// This is the single most important architectural decision in the app, so it is
/// written down where the code is rather than only in the decision log.
///
/// `architectural-rules.md` §5.1 lists `url.resourceValues(forKeys:)`,
/// `url.lastPathComponent`, `url.deletingLastPathComponent()` and
/// `url.pathExtension` as operations that can make a **synchronous XPC call to
/// `fileproviderd`** on iCloud-backed paths. Each such call can block for seconds
/// under a slow network. The preflight ranks this as risk #1 for DiskDrama
/// specifically, and not hypothetically: this machine's home directory really
/// does contain File Provider content.
///
/// `FileManager.enumerator` hands back `URL`s. A scanner built on it sits one
/// innocent-looking property access away from that hang, forever, in every future
/// edit. §1 asks for wrong patterns to be made structurally impossible rather
/// than merely documented — and `fts` does that: it walks `char *` paths and
/// returns `struct stat` inline. There is no `URL` to misuse.
///
/// It is also simply the right tool. `fts` is what `du` and `find` use; it
/// handles millions of entries, cycle detection, and post-order aggregation
/// natively.
///
/// ## Flags
///
/// - `FTS_PHYSICAL` — `lstat`, never follow symlinks. Correct for a size scanner
///   (following them double-counts and can cycle), and it means the familiar
///   `~/Google Drive` / `~/OneDrive` symlinks into `~/Library/CloudStorage` are
///   never descended into, whatever a vendor calls its folder.
/// - `FTS_XDEV` — never cross a device boundary. Keeps the scan on the boot
///   volume; external and network volumes are explicitly out of scope.
/// - `FTS_NOCHDIR` — do not `chdir` while walking. `fts` otherwise changes the
///   process-wide working directory, which is a hostile thing to do to every
///   other thread in a GUI app.
enum FileTreeWalker {

    /// Progress ticks are throttled to this interval. The UI cannot render at
    /// filesystem speed and does not need to; §10.2's lesson is that firing an
    /// observable update per element is what kills these views.
    static let progressInterval: TimeInterval = 0.1

    /// Subtrees finishing below this keep their totals but drop their children.
    ///
    /// Detail is only useful where there is enough space at stake to act on. A
    /// full directory tree of a home folder is hundreds of thousands of nodes;
    /// this bounds retention to the parts worth talking about while every
    /// aggregate stays exact.
    static let inMemoryDetailFloorBytes: Int64 = 10_000_000

    /// A directory taking longer than this to enumerate is recorded and reported.
    ///
    /// Five seconds is far outside normal — a directory of a few thousand entries
    /// reads in milliseconds. Anything past this is pathological, and on a
    /// developer's Mac it is usually a build index or package cache that has grown
    /// past the point where the filesystem handles it gracefully. That is a
    /// DiskDrama finding, not merely a scan inconvenience.
    static let slowDirectoryThreshold: TimeInterval = 5.0

    struct Progress: Sendable {
        let currentPath: String
        let entriesVisited: Int
        let bytesSoFar: Int64
    }

    /// How many directories deep, relative to a claimed subtree, a worker will
    /// still consider handing siblings back to the pool.
    ///
    /// Shallow on purpose. Handing off deep in a tree splits work that is
    /// already small, and every handoff costs a queue round-trip and a fresh
    /// `fts_open`. The useful splits are near the top, where "one directory" can
    /// still mean a hundred gigabytes.
    static let handoffDepth: Int32 = 3

    /// Workers in the pool.
    ///
    /// Two cores are left alone deliberately. The scan is background work; the
    /// window, the menubar poll and the rest of the system all have to stay
    /// responsive while it runs, and saturating every core to finish marginally
    /// sooner is a bad trade for an app that lives in the menu bar. Clamped so a
    /// two-core Mac still gets a pool and a very large one does not spawn more
    /// threads than the disk can usefully feed.
    static var workerCount: Int {
        min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Walks `roots`, returning the built tree.
    ///
    /// **Runs on the calling thread and blocks it**, and now fans out from there
    /// onto a pool of worker threads. Callers must be on a background queue —
    /// `ScanEngine` is the only intended caller and dispatches via GCD, not
    /// `Task.detached`, because §3.1 means a detached task's continuation can
    /// still resume on main. That constraint does not relax by adding threads;
    /// it applies to every one of them, which is why the pool is
    /// `DispatchQueue.global` work items and not tasks.
    ///
    /// ## Why a pool at all
    ///
    /// The walk was one thread from start to finish regardless of the machine,
    /// and one blocking `readdir` on an oversized directory stopped everything.
    /// Measured on this Mac: 0.7% CPU while a home scan sat on a single folder.
    /// The disk is an SSD with real concurrent throughput, and nothing about the
    /// traversal needs to be serial — only the bookkeeping around it did.
    ///
    /// `fts` still does all the recursing. A worker claims a subtree and runs
    /// exactly the loop this file has always run, with its own `fts` handle, its
    /// own stack, and its own cycle and device-boundary handling. What is new is
    /// only how subtrees get shared out.
    static func walk(
        roots: [String],
        exclusions: Set<String>,
        control: ScanControl,
        // Escaping because the pool runs it on worker threads. The call still
        // blocks until every worker has stopped, so it does not in fact outlive
        // this frame — the compiler simply cannot prove that.
        onProgress: @escaping @Sendable (Progress) -> Void
    ) -> ScanResult {

        let startedAt = Date()
        let shared = ScanSharedState()

        let hasFullDiskAccess = FullDiskAccess.isGranted()
        let protectedSkips: Set<String> = hasFullDiskAccess ? [] : Set(FullDiskAccess.protectedPaths)
        let skipSet = exclusions.union(protectedSkips)
        let atomicRules = KnowledgeBase.rules.filter(\.isAtomicRegenerable)

        // Seed one item per root. Distribution below the root happens by handoff
        // rather than by pre-listing children: the first worker to claim a root
        // finds the pool idle and the queue empty, so it hands its top-level
        // directories straight back out. That reaches the same place as seeding
        // the children explicitly, without a second way of enumerating a
        // directory that has to agree with the first.
        var rootNodes: [ScanNode] = []
        var seed: [ScanWorkQueue.Item] = []
        for root in roots {
            guard !isExcluded(root, by: skipSet) else {
                shared.noteBlindSpot(root, protectedSkips.contains(root) ? .fullDiskAccessMissing : .excludedByUser)
                continue
            }
            let node = ScanNode(path: root,
                                name: (root as NSString).lastPathComponent,
                                depth: 0,
                                parent: nil)
            rootNodes.append(node)
            seed.append(ScanWorkQueue.Item(path: root, node: node, isRoot: true))
        }

        let queue = ScanWorkQueue(seed: seed)

        // Subtrees that were handed to another worker, and therefore must not
        // roll up into their parents until every worker has stopped. See
        // `joinHandedOffSubtrees`.
        let joinsLock = OSAllocatedUnfairLock(initialState: [ScanNode]())

        let group = DispatchGroup()
        let pool = DispatchQueue.global(qos: .utility)
        for worker in 0..<workerCount {
            pool.async(group: group) {
                while let item = queue.claim() {
                    walkClaimed(item,
                                worker: worker,
                                queue: queue,
                                shared: shared,
                                joins: joinsLock,
                                skipSet: skipSet,
                                protectedSkips: protectedSkips,
                                hasFullDiskAccess: hasFullDiskAccess,
                                atomicRules: atomicRules,
                                control: control,
                                onProgress: onProgress)
                    queue.finish()
                    if control.current == .cancelled { queue.stop() }
                }
                control.idle(worker: worker)
            }
        }
        group.wait()

        let totals = shared.totals

        guard control.current != .cancelled else {
            return cancelled(startedAt: startedAt, roots: rootNodes,
                             blindSpots: shared.blindSpots, visited: totals.visited)
        }

        joinHandedOffSubtrees(joinsLock.withLock { $0 })

        let total = rootNodes.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ScanResult(roots: rootNodes,
                          blindSpots: shared.blindSpots,
                          slowDirectories: shared.slowDirectories.sorted { $0.seconds > $1.seconds },
                          startedAt: startedAt,
                          completedAt: Date(),
                          visitedEntryCount: totals.visited,
                          totalSizeBytes: total,
                          wasCancelled: false)
    }

    /// Rolls handed-off subtrees into their parents, once, after every worker
    /// has stopped.
    ///
    /// This is deliberately *not* done during the walk. A node whose children
    /// are being filled in by three other threads cannot be finalised while they
    /// are still running — it would be pruned or accumulated with totals that
    /// are simply not complete yet, and no amount of locking the node fixes
    /// that, because the question is not "is this write safe" but "has
    /// everything that will ever be added, been added".
    ///
    /// Deepest first, so a nested handoff has already folded into its own parent
    /// before that parent folds into *its* parent. Within a worker's own subtree
    /// nothing changes: post-order accumulation and the sub-10 MB prune still
    /// happen inline, on one thread, exactly as before — which is also what
    /// keeps memory bounded, since only the join points survive to here.
    private static func joinHandedOffSubtrees(_ joins: [ScanNode]) {
        for node in joins.sorted(by: { $0.depth > $1.depth }) {
            if node.sizeBytes < inMemoryDetailFloorBytes {
                node.children.removeAll()
            }
            node.accumulateIntoParent()
        }
    }

    /// One claimed subtree, walked by one worker.
    ///
    /// This is the loop this file has always had. The per-entry switch, the
    /// blind-spot reasons, the hard-link accounting, the prune floor and the
    /// stack discipline are unchanged in substance — what changed is where the
    /// counters live and that a directory can now be given away instead of
    /// walked.
    private static func walkClaimed(
        _ item: ScanWorkQueue.Item,
        worker: Int,
        queue: ScanWorkQueue,
        shared: ScanSharedState,
        joins: OSAllocatedUnfairLock<[ScanNode]>,
        skipSet: Set<String>,
        protectedSkips: Set<String>,
        hasFullDiskAccess: Bool,
        atomicRules: [ClassificationRule],
        control: ScanControl,
        onProgress: @Sendable (Progress) -> Void
    ) {
        let rootCopy = strdup(item.path)
        defer { free(rootCopy) }
        var pathArgv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]

        guard let fts = fts_open(&pathArgv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            shared.noteBlindSpot(item.path, hasFullDiskAccess ? .unreadable : .fullDiskAccessMissing)
            return
        }
        defer { fts_close(fts) }

        let baseDepth = item.node.depth
        var stack: [ScanNode] = [item.node]
        var pendingDirectoryStarts: [String: Date] = [:]

        // Nodes that must not roll up here, because something under them is
        // being filled in by another worker.
        //
        // Without this, an ancestor reaches its post-order visit while a
        // handed-off descendant is still running, and folds an incomplete total
        // into *its* parent. The join pass adds the missing bytes to the
        // ancestor afterwards — too late, the grandparent already took the old
        // number, and the scan quietly under-reports. Worker-local because the
        // whole chain being marked belongs to this worker.
        var deferred = Set<ObjectIdentifier>()

        // Worker-local counters, merged into the shared totals on the throttle.
        // See `ScanSharedState` for why they are not shared directly.
        var localVisited = 0
        var localBytes: Int64 = 0
        var sinceMerge = 0

        control.entering(item.path, worker: worker)

        while let entry = fts_read(fts) {
            let level = entry.pointee.fts_level
            if level > 0 || item.isRoot { localVisited += 1 }

            sinceMerge += 1
            if sinceMerge >= 512 {
                guard control.waitIfPausedAndContinue() else { return }
                sinceMerge = 0
            }

            let info = Int32(entry.pointee.fts_info)

            @inline(__always) func currentPath() -> String {
                String(cString: entry.pointee.fts_path)
            }

            switch info {

            case FTS_D:
                let path = currentPath()
                if level > 0 && isExcluded(path, by: skipSet) {
                    shared.noteBlindSpot(path, protectedSkips.contains(path) ? .fullDiskAccessMissing : .excludedByUser)
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                if level == 0 { continue }   // the claimed root, already on the stack

                let name = (path as NSString).lastPathComponent
                let node = ScanNode(path: path, name: name,
                                    depth: baseDepth + Int(level),
                                    parent: stack.last)

                // Hand it to an idle worker rather than walking it here.
                //
                // Only near the top of a claimed subtree, and only when someone
                // is actually waiting — see `ScanWorkQueue.wantsWork`. The node
                // is created and attached first, so the tree's shape is settled
                // before another thread can touch it; only its *contents* are
                // filled in elsewhere.
                if level <= handoffDepth, queue.wantsWork {
                    stack.last?.children.append(node)
                    joins.withLock { $0.append(node) }
                    // Every ancestor now has an outstanding descendant.
                    for ancestor in stack { deferred.insert(ObjectIdentifier(ancestor)) }
                    queue.push(ScanWorkQueue.Item(path: path, node: node, isRoot: false))
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }

                if !atomicRules.isEmpty,
                   atomicRules.contains(where: { $0.matcher.matches(path: path, name: name) }) {
                    control.entering(path, worker: worker)
                    let started = Date()
                    fts_set(fts, entry, FTS_SKIP)

                    let sum = sumAtomicSubtree(
                        root: path, skipSet: skipSet, protectedSkips: protectedSkips,
                        hasFullDiskAccess: hasFullDiskAccess, control: control, worker: worker,
                        visited: &localVisited, bytesSeen: &localBytes,
                        shared: shared, onProgress: onProgress)

                    guard !sum.wasCancelled else { return }

                    node.sizeBytes = sum.sizeBytes
                    node.logicalBytes = sum.logicalBytes
                    node.fileCount = sum.fileCount
                    node.newestModifiedAt = sum.newestModifiedAt
                    stack.last?.children.append(node)
                    node.accumulateIntoParent()

                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed >= slowDirectoryThreshold {
                        shared.noteSlowDirectory(path, seconds: elapsed)
                    }
                    continue
                }

                control.entering(path, worker: worker)
                pendingDirectoryStarts[path] = Date()
                stack.last?.children.append(node)
                stack.append(node)

            case FTS_DP:
                guard level > 0, stack.count > 1 else { continue }
                let donePath = currentPath()

                // Pop only when the top of the stack really is this directory.
                //
                // `fts_set(FTS_SKIP)` on a pre-order directory still returns that
                // directory in post-order — verified against fts(3) on this
                // machine, not assumed. Skipped directories are never pushed, so
                // without this guard their FTS_DP popped the *parent* instead.
                // Handoff made this matter twice over: every handed-off
                // directory is a skip.
                guard stack.last?.path == donePath else { continue }

                if let started = pendingDirectoryStarts.removeValue(forKey: donePath) {
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed >= slowDirectoryThreshold {
                        shared.noteSlowDirectory(donePath, seconds: elapsed)
                    }
                }
                let node = stack.removeLast()
                guard !deferred.contains(ObjectIdentifier(node)) else {
                    joins.withLock { $0.append(node) }
                    continue
                }
                if node.sizeBytes < inMemoryDetailFloorBytes {
                    node.children.removeAll()   // totals kept, breakdown dropped
                }
                node.accumulateIntoParent()

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = entry.pointee.fts_statp else { continue }
                let stat = st.pointee

                if stat.st_nlink > 1 {
                    let key = (UInt64(stat.st_dev) << 32) ^ UInt64(stat.st_ino)
                    guard shared.claimHardLink(key) else { continue }
                }

                let physical = Int64(stat.st_blocks) * 512
                let logical = Int64(stat.st_size)
                let modified = Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))

                localBytes += physical

                if let current = stack.last {
                    current.sizeBytes += physical
                    current.logicalBytes += logical
                    current.fileCount += 1
                    current.newestModifiedAt = current.newestModifiedAt.map { max($0, modified) } ?? modified
                }

            case FTS_DNR:
                let reason: BlindSpotReason = entry.pointee.fts_errno == EPERM || entry.pointee.fts_errno == EACCES
                    ? (hasFullDiskAccess ? .permissionDenied : .fullDiskAccessMissing)
                    : .unreadable
                shared.noteBlindSpot(currentPath(), reason)
                stack.last?.blindSpot = reason

            case FTS_NS, FTS_ERR, FTS_DC:
                shared.noteBlindSpot(currentPath(), .unreadable)

            default:
                break
            }

            if localVisited >= 512 || localBytes > 0 {
                let merged = shared.merge(visited: localVisited, bytes: localBytes)
                localVisited = 0
                localBytes = 0
                if merged.shouldReport {
                    control.heartbeat(worker: worker)
                    onProgress(Progress(currentPath: currentPath(),
                                        entriesVisited: merged.visited,
                                        bytesSoFar: merged.bytes))
                }
            }
        }

        // Unwind anything still open, then fold the worker's remaining counts in.
        while stack.count > 1 {
            let node = stack.removeLast()
            if deferred.contains(ObjectIdentifier(node)) {
                joins.withLock { $0.append(node) }
            } else {
                node.accumulateIntoParent()
            }
        }
        _ = shared.merge(visited: localVisited, bytes: localBytes)
    }

    // MARK: - Atomic subtree summation

    private struct AtomicSum {
        var sizeBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var newestModifiedAt: Date?
        var wasCancelled = false
    }

    /// Totals for a subtree, building nothing.
    ///
    /// A second `fts` walk rooted at the atomic folder rather than a recursive
    /// `readdir` by hand: same flags, same cycle and device handling, same
    /// hard-link accounting as the main loop, and no new way to get any of that
    /// subtly wrong. The only difference is that directories produce no nodes.
    ///
    /// Shares the caller's mutable walk state deliberately. Hard links must be
    /// deduplicated against everything already seen — counting one twice would
    /// overstate reclaimable space, the one direction this app must never err
    /// in — and progress has to keep moving, because a walk that reports nothing
    /// for two minutes is indistinguishable from a hang. Sharing is safe because
    /// this is serial: the caller is blocked inside this call.
    private static func sumAtomicSubtree(
        root: String,
        skipSet: Set<String>,
        protectedSkips: Set<String>,
        hasFullDiskAccess: Bool,
        control: ScanControl,
        worker: Int,
        visited: inout Int,
        bytesSeen: inout Int64,
        shared: ScanSharedState,
        onProgress: (Progress) -> Void
    ) -> AtomicSum {

        var sum = AtomicSum()

        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var pathArgv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]

        guard let fts = fts_open(&pathArgv,
                                 FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR,
                                 nil) else {
            shared.noteBlindSpot(root, hasFullDiskAccess ? .unreadable : .fullDiskAccessMissing)
            return sum
        }
        defer { fts_close(fts) }

        var sinceCheck = 0

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            let level = entry.pointee.fts_level

            // The root's own visits were counted by the caller, which saw this
            // same directory before handing it over.
            if level > 0 { visited += 1 }

            sinceCheck += 1
            if sinceCheck >= 512 {
                sinceCheck = 0
                if !control.waitIfPausedAndContinue() {
                    sum.wasCancelled = true
                    return sum
                }
                let merged = shared.merge(visited: visited, bytes: bytesSeen)
                visited = 0
                bytesSeen = 0
                if merged.shouldReport {
                    control.heartbeat(worker: worker)
                    onProgress(Progress(currentPath: String(cString: entry.pointee.fts_path),
                                        entriesVisited: merged.visited,
                                        bytesSoFar: merged.bytes))
                }
            }

            switch info {

            case FTS_D:
                // An exclusion inside an atomic folder is unusual but legal, and
                // ignoring it here would quietly scan something the user said not
                // to.
                guard level > 0 else { continue }
                let path = String(cString: entry.pointee.fts_path)
                if isExcluded(path, by: skipSet) {
                    shared.noteBlindSpot(path, protectedSkips.contains(path) ? .fullDiskAccessMissing : .excludedByUser)
                    fts_set(fts, entry, FTS_SKIP)
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = entry.pointee.fts_statp else { continue }
                let stat = st.pointee

                if stat.st_nlink > 1 {
                    let key = (UInt64(stat.st_dev) << 32) ^ UInt64(stat.st_ino)
                    guard shared.claimHardLink(key) else { continue }
                }

                let physical = Int64(stat.st_blocks) * 512
                sum.sizeBytes += physical
                sum.logicalBytes += Int64(stat.st_size)
                sum.fileCount += 1

                let modified = Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))
                sum.newestModifiedAt = sum.newestModifiedAt.map { max($0, modified) } ?? modified

                bytesSeen += physical

            case FTS_DNR:
                let reason: BlindSpotReason = entry.pointee.fts_errno == EPERM || entry.pointee.fts_errno == EACCES
                    ? (hasFullDiskAccess ? .permissionDenied : .fullDiskAccessMissing)
                    : .unreadable
                shared.noteBlindSpot(String(cString: entry.pointee.fts_path), reason)

            case FTS_NS, FTS_ERR, FTS_DC:
                shared.noteBlindSpot(String(cString: entry.pointee.fts_path), .unreadable)

            default:
                break
            }
        }

        return sum
    }

    // MARK: - Helpers

    /// Prefix match on raw path strings — no `URL`, by design (§5.1).
    ///
    /// The trailing-separator test matters: without it, excluding `~/Music` would
    /// also silently exclude `~/MusicVideos`, and the user would never be told
    /// why a folder went missing from their results.
    private static func isExcluded(_ path: String, by exclusions: Set<String>) -> Bool {
        if exclusions.contains(path) { return true }
        for excluded in exclusions where path.hasPrefix(excluded + "/") {
            return true
        }
        return false
    }

    private static func cancelled(startedAt: Date, roots: [ScanNode],
                                  blindSpots: [(path: String, reason: BlindSpotReason)],
                                  visited: Int) -> ScanResult {
        ScanResult(roots: roots,
                   blindSpots: blindSpots,
                   slowDirectories: [],
                   startedAt: startedAt,
                   completedAt: Date(),
                   visitedEntryCount: visited,
                   totalSizeBytes: 0,
                   wasCancelled: true)
    }
}
