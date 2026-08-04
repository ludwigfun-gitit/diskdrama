import Foundation

/// A directory in the scanned tree, with its subtree totals.
///
/// Reference type on purpose: the tree is built bottom-up by a traversal that
/// mutates parents as children complete, and copying value-type subtrees at every
/// post-order step would be quadratic.
///
/// **Directories only.** Individual files are counted into their parent's totals
/// but not retained — a home directory holds millions of them and keeping every
/// one would cost more memory than the app is trying to reclaim disk. F10's
/// "Look inside" re-enumerates a single directory on demand instead, which is a
/// few milliseconds for one level.
final class ScanNode {

    let path: String
    let name: String
    let depth: Int

    /// Bytes actually occupied on disk across the subtree (`st_blocks * 512`).
    /// This is what frees on delete, and every reclaim figure derives from it.
    var sizeBytes: Int64 = 0

    /// Sum of `st_size` across the subtree — what Finder shows. Kept so a
    /// divergence (sparse files, APFS clones, compression) can be explained
    /// rather than leaving the user to notice the two disagree.
    var logicalBytes: Int64 = 0

    /// Files in the subtree, excluding directories.
    var fileCount: Int = 0

    /// Newest mtime in the subtree. One of the strongest staleness signals an
    /// explanation can carry — "nothing here has been touched in 14 months".
    var newestModifiedAt: Date?

    /// Immediate subdirectories.
    ///
    /// Dropped during traversal for subtrees that finish below the detail floor
    /// (see `ScanEngine.inMemoryDetailFloorBytes`). The node keeps its accurate
    /// totals either way; only the breakdown beneath it goes. That bounds memory
    /// to the parts of the disk large enough to be worth talking about.
    var children: [ScanNode] = []

    /// Set when this directory could not be read. Its totals are then a floor,
    /// not a measurement, and the UI must say so rather than present them as
    /// complete.
    var blindSpot: BlindSpotReason?

    weak var parent: ScanNode?

    init(path: String, name: String, depth: Int, parent: ScanNode?) {
        self.path = path
        self.name = name
        self.depth = depth
        self.parent = parent
    }

    /// Rolls this node's totals into its parent. Called once, at post-order.
    func accumulateIntoParent() {
        guard let parent else { return }
        parent.sizeBytes += sizeBytes
        parent.logicalBytes += logicalBytes
        parent.fileCount += fileCount
        if let mine = newestModifiedAt {
            if let theirs = parent.newestModifiedAt {
                parent.newestModifiedAt = max(mine, theirs)
            } else {
                parent.newestModifiedAt = mine
            }
        }
    }

    /// Depth-first walk, largest-first at each level. Used by classification and
    /// by the delta.
    func forEachDescendant(_ body: (ScanNode) -> Void) {
        for child in children.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
            body(child)
            child.forEachDescendant(body)
        }
    }
}

/// The outcome of a completed scan.
///
/// ## Sendability
///
/// `ScanNode` is a mutable reference graph and cannot be `Sendable`. This is an
/// **ownership transfer**, not shared state: the traversal builds the tree on a
/// background thread, drops every reference it holds, and hands the root over
/// exactly once. Nothing on the background side can reach it afterwards.
///
/// `@unchecked` is stating that fact rather than waving the checker off — the
/// alternative (deep-copying a multi-hundred-thousand-node tree across the
/// boundary purely to satisfy a checker that cannot see the handoff) would cost
/// real time and memory to prove something already true by construction.
struct ScanResult: @unchecked Sendable {
    let roots: [ScanNode]
    let blindSpots: [(path: String, reason: BlindSpotReason)]

    /// Directories that took pathologically long to enumerate, slowest first.
    /// Surfaced to the user rather than silently absorbed — a folder the
    /// filesystem struggles to list is exactly what this app exists to find.
    let slowDirectories: [(path: String, seconds: TimeInterval)]

    let startedAt: Date
    let completedAt: Date
    let visitedEntryCount: Int
    let totalSizeBytes: Int64

    /// Set when the scan stopped early. A cancelled scan's results are discarded
    /// entirely — the previous snapshot stays authoritative (F06/F07), because a
    /// half-populated snapshot would poison the delta silently.
    let wasCancelled: Bool
}
