import Foundation
import Darwin

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

    /// Walks `roots`, returning the built tree.
    ///
    /// **Runs on the calling thread and blocks it.** Callers must be on a
    /// background queue — `ScanEngine` is the only intended caller and dispatches
    /// via GCD, not `Task.detached`, because §3.1 means a detached task's
    /// continuation can still resume on main. GCD gives thread guarantees; Swift
    /// Concurrency gives scheduling hints.
    static func walk(
        roots: [String],
        exclusions: Set<String>,
        control: ScanControl,
        onProgress: @Sendable (Progress) -> Void
    ) -> ScanResult {

        let startedAt = Date()
        var blindSpots: [(path: String, reason: BlindSpotReason)] = []
        var rootNodes: [ScanNode] = []
        var visited = 0

        /// Running total for progress reporting only.
        ///
        /// Deliberately *not* derived from the root nodes: those only accrue at
        /// post-order, so a walk of a deep tree reported `0 bytes` for minutes
        /// while making perfectly good progress. Accurate and useless is still
        /// useless — a progress figure that doesn't move is indistinguishable
        /// from a hang, which is the exact confusion Step 3 spent a day on.
        var bytesSeen: Int64 = 0

        var lastProgressAt = Date.distantPast

        // Directories that took long enough to be worth reporting. A single
        // pathological directory can dominate a whole scan's wall-clock, and the
        // user deserves to be told which one rather than being left with "that
        // took ages". It is also a genuine finding in its own right — see
        // `slowDirectoryThreshold`.
        var slowDirectories: [(path: String, seconds: TimeInterval)] = []
        var pendingDirectoryStarts: [String: Date] = [:]

        // Hard links occupy their blocks once, however many names point at them.
        // Counting each name would overstate reclaimable space — and overstating
        // is the one direction a cleanup advisor must never err in. Only tracked
        // for entries that actually have multiple links, so the common case costs
        // nothing.
        var seenHardLinks = Set<UInt64>()

        // Full Disk Access decides how an unreadable directory is explained: a
        // missing grant is a fixable situation with a walkthrough behind it, an
        // ordinary permission failure is not. Read once — it cannot change
        // mid-scan without the app being relaunched by TCC anyway.
        let hasFullDiskAccess = FullDiskAccess.isGranted()

        // Without a grant, TCC-protected folders do not fail — they hang (see
        // `FullDiskAccess.protectedPaths`). They are folded into the skip set so
        // the walk never reaches the blocking `open()`, and each is reported as a
        // blind spot naming the missing permission, which is what F05's reduced
        // mode requires anyway.
        let protectedSkips: Set<String> = hasFullDiskAccess
            ? []
            : Set(FullDiskAccess.protectedPaths)
        let skipSet = exclusions.union(protectedSkips)

        for root in roots {
            guard control.waitIfPausedAndContinue() else {
                return cancelled(startedAt: startedAt, roots: rootNodes,
                                 blindSpots: blindSpots, visited: visited)
            }
            guard !isExcluded(root, by: skipSet) else {
                blindSpots.append((root, protectedSkips.contains(root) ? .fullDiskAccessMissing : .excludedByUser))
                continue
            }

            // fts_open takes a NULL-terminated array of C strings. Only one root
            // is passed per call so a failure is attributable to a specific root
            // rather than the batch.
            let rootCopy = strdup(root)
            defer { free(rootCopy) }
            var pathArgv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]

            guard let fts = fts_open(&pathArgv,
                                     FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR,
                                     nil) else {
                blindSpots.append((root, hasFullDiskAccess ? .unreadable : .fullDiskAccessMissing))
                continue
            }
            defer { fts_close(fts) }

            let rootNode = ScanNode(path: root,
                                    name: (root as NSString).lastPathComponent,
                                    depth: 0,
                                    parent: nil)
            rootNodes.append(rootNode)

            // Stack of open directories. `fts` emits FTS_D on the way down and
            // FTS_DP on the way back up, so this mirrors the walk exactly and
            // never needs a path lookup to find the current parent.
            var stack: [ScanNode] = [rootNode]

            while let entry = fts_read(fts) {
                visited += 1

                // Polled rather than checked every entry: the lock is cheap but
                // not free, and 512 entries is a few milliseconds of walking —
                // well inside any human sense of "it stopped immediately".
                if visited % 512 == 0 {
                    guard control.waitIfPausedAndContinue() else {
                        return cancelled(startedAt: startedAt, roots: rootNodes,
                                         blindSpots: blindSpots, visited: visited)
                    }
                }

                let info = Int32(entry.pointee.fts_info)

                // The path String is built only in the branches that need it.
                //
                // Files are the overwhelming majority of entries — millions on a
                // developer's home directory — and none of them need a Swift
                // String: their bytes go straight into the parent's totals. Doing
                // `String(cString:)` unconditionally at the top of the loop, as
                // this first did, allocated and UTF-8-validated a string per file
                // and made the walk several times slower than `du` for no benefit
                // whatsoever.
                @inline(__always) func currentPath() -> String {
                    String(cString: entry.pointee.fts_path)
                }

                switch info {

                case FTS_D:
                    // Pre-order. Decide here whether to descend at all.
                    let path = currentPath()
                    if entry.pointee.fts_level > 0 && isExcluded(path, by: skipSet) {
                        // Distinguish the two reasons: "you told me not to look"
                        // and "I am not allowed to look" need different copy and
                        // only the second has a fix behind it.
                        blindSpots.append((path, protectedSkips.contains(path) ? .fullDiskAccessMissing : .excludedByUser))
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    if entry.pointee.fts_level == 0 { continue }  // the root itself, already on the stack

                    // Name comes from the path rather than `fts_name`: the latter
                    // is a C flexible array member, which Swift imports as a
                    // single-element tuple needing an unsafe rebind to read.
                    // `NSString.lastPathComponent` on a plain String is a pure
                    // string operation — the §5.1 hazard is `URL`'s accessors,
                    // not string manipulation.
                    // Published *before* fts opens the directory, so a stall is
                    // attributable to a specific path even though the thread that
                    // would report it is the one that is stuck.
                    control.entering(path)
                    pendingDirectoryStarts[path] = Date()

                    let node = ScanNode(path: path,
                                        name: (path as NSString).lastPathComponent,
                                        depth: Int(entry.pointee.fts_level),
                                        parent: stack.last)
                    stack.last?.children.append(node)
                    stack.append(node)

                case FTS_DP:
                    // Post-order: the subtree is complete.
                    guard entry.pointee.fts_level > 0, stack.count > 1 else { continue }
                    if let started = pendingDirectoryStarts.removeValue(forKey: currentPath()) {
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed >= slowDirectoryThreshold {
                            slowDirectories.append((currentPath(), elapsed))
                        }
                    }
                    let node = stack.removeLast()
                    if node.sizeBytes < inMemoryDetailFloorBytes {
                        node.children.removeAll()   // totals kept, breakdown dropped
                    }
                    node.accumulateIntoParent()

                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    guard let st = entry.pointee.fts_statp else { continue }
                    let stat = st.pointee

                    if stat.st_nlink > 1 {
                        let key = (UInt64(stat.st_dev) << 32) ^ UInt64(stat.st_ino)
                        if seenHardLinks.contains(key) { continue }
                        seenHardLinks.insert(key)
                    }

                    let physical = Int64(stat.st_blocks) * 512
                    let logical = Int64(stat.st_size)
                    let modified = Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))

                    bytesSeen += physical

                    if let current = stack.last {
                        current.sizeBytes += physical
                        current.logicalBytes += logical
                        current.fileCount += 1
                        current.newestModifiedAt = current.newestModifiedAt.map { max($0, modified) } ?? modified
                    }

                case FTS_DNR:
                    // Directory exists but could not be opened. This is the case
                    // F06 requires be recorded and shown rather than guessed at —
                    // and without Full Disk Access it is most of ~/Library.
                    let reason: BlindSpotReason = entry.pointee.fts_errno == EPERM || entry.pointee.fts_errno == EACCES
                        ? (hasFullDiskAccess ? .permissionDenied : .fullDiskAccessMissing)
                        : .unreadable
                    blindSpots.append((currentPath(), reason))
                    stack.last?.blindSpot = reason

                case FTS_NS, FTS_ERR:
                    blindSpots.append((currentPath(), .unreadable))

                case FTS_DC:
                    // Directory cycle. Cannot happen with FTS_PHYSICAL, but if it
                    // ever does, silently double-counting is the worst response.
                    blindSpots.append((currentPath(), .unreadable))

                default:
                    break
                }

                let now = Date()
                if now.timeIntervalSince(lastProgressAt) >= progressInterval {
                    lastProgressAt = now
                    // Heartbeat and progress share the same throttle: both mean
                    // "the walk is still moving", and taking the lock per
                    // filesystem entry would cost millions of acquisitions.
                    control.heartbeat()
                    onProgress(Progress(currentPath: currentPath(),
                                        entriesVisited: visited,
                                        bytesSoFar: bytesSeen))
                }
            }

            // Unwind anything still open — a walk cut short by an fts-level error
            // leaves entries on the stack whose totals would otherwise never roll
            // up into their parents.
            while stack.count > 1 {
                stack.removeLast().accumulateIntoParent()
            }
        }

        let total = rootNodes.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ScanResult(roots: rootNodes,
                          blindSpots: blindSpots,
                          slowDirectories: slowDirectories.sorted { $0.seconds > $1.seconds },
                          startedAt: startedAt,
                          completedAt: Date(),
                          visitedEntryCount: visited,
                          totalSizeBytes: total,
                          wasCancelled: false)
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
