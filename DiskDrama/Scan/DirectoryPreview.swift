import Foundation

/// "Look inside" (F10) — the biggest things one level down.
///
/// Two sources, in order of preference:
///
/// 1. **The in-memory tree**, when the scan ran in this session. Its children are
///    already sized, so opening a preview costs nothing and cannot fail.
/// 2. **A scoped walk**, otherwise — after a relaunch there is no tree, only the
///    pruned snapshot, and the snapshot deliberately does not hold small nodes.
///
/// The fallback runs on GCD, never `Task.detached` (§3.1), and never touches
/// `URL` (§5.1). It is a real filesystem walk of a real directory: everything the
/// scan engine is careful about applies here too, at a smaller scale.
enum DirectoryPreview {

    struct Entry: Sendable, Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let sizeBytes: Int64
        /// Kept alongside the physical size so a drilled-into item carries the
        /// same pair every other item has, rather than a copy of one standing in
        /// for the other.
        let logicalBytes: Int64
        let fileCount: Int
        let newestModifiedAt: Date?
        let isDirectory: Bool
    }

    struct Result: Sendable {
        let entries: [Entry]
        /// Files in the whole subtree, which is the number worth stating for a
        /// folder whose problem is count rather than size.
        let totalFileCount: Int
        /// Bytes not accounted for by `entries` — the tail below the display cut.
        let remainderBytes: Int64
        let remainderCount: Int
        /// Set when the folder was not enumerated at all, and why.
        let notEnumerated: NotEnumerated?
    }

    enum NotEnumerated: Sendable {
        /// F10's stated behaviour for build indexes and the like: summarize,
        /// don't enumerate. Listing a million rows helps nobody and the count
        /// *is* the finding.
        case tooManyEntries(Int)
        case unreadable(BlindSpotReason)
    }

    /// Above this, a folder is described rather than listed.
    static let enumerationCeiling = 200_000

    /// How many children are shown before the rest becomes one summary row.
    static let displayLimit = 6

    private static let queue = DispatchQueue(label: "com.bloo.diskdrama.preview", qos: .userInitiated)

    /// Builds a preview for `item`, calling back on the main actor.
    ///
    /// Returns synchronously via the callback when the in-memory tree can answer,
    /// so the common case has no visible loading state at all.
    @MainActor
    static func load(
        path: String,
        fileCount: Int,
        from result: ScanResult?,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        if fileCount > enumerationCeiling {
            completion(Result(entries: [], totalFileCount: fileCount,
                              remainderBytes: 0, remainderCount: 0,
                              notEnumerated: .tooManyEntries(fileCount)))
            return
        }

        if let node = result?.node(at: path), !node.children.isEmpty {
            completion(summarize(children: node.children, totalFileCount: node.fileCount))
            return
        }

        let exclusions = Settings.shared.exclusionSet
        queue.async {
            let walked = FileTreeWalker.walk(roots: [path],
                                             exclusions: exclusions,
                                             control: ScanControl()) { _ in }
            guard let root = walked.roots.first else {
                Task { @MainActor in
                    completion(Result(entries: [], totalFileCount: 0,
                                      remainderBytes: 0, remainderCount: 0,
                                      notEnumerated: .unreadable(.unreadable)))
                }
                return
            }
            let summary = summarize(children: root.children, totalFileCount: root.fileCount)
            let blindSpot = walked.blindSpots.first(where: { $0.path == path })?.reason
            Task { @MainActor in
                if summary.entries.isEmpty, let blindSpot {
                    // F10's failure case: unreadable shows a blind-spot notice
                    // rather than an empty table, which would read as "empty
                    // folder" — a materially different and wrong statement.
                    completion(Result(entries: [], totalFileCount: summary.totalFileCount,
                                      remainderBytes: 0, remainderCount: 0,
                                      notEnumerated: .unreadable(blindSpot)))
                } else {
                    completion(summary)
                }
            }
        }
    }

    /// Largest first, with everything past the display limit folded into a
    /// remainder. Values are copied out of the nodes here, on whichever thread
    /// owns them, so nothing hands a `ScanNode` across an isolation boundary.
    private static func summarize(children: [ScanNode], totalFileCount: Int) -> Result {
        let sorted = children.sorted { $0.sizeBytes > $1.sizeBytes }
        let shown = sorted.prefix(displayLimit)
        let rest = sorted.dropFirst(displayLimit)

        return Result(
            entries: shown.map {
                Entry(path: $0.path, name: $0.name, sizeBytes: $0.sizeBytes,
                      logicalBytes: $0.logicalBytes, fileCount: $0.fileCount,
                      newestModifiedAt: $0.newestModifiedAt, isDirectory: true)
            },
            totalFileCount: totalFileCount,
            remainderBytes: rest.reduce(0) { $0 + $1.sizeBytes },
            remainderCount: rest.count,
            notEnumerated: nil)
    }
}

extension ScanResult {
    /// Finds a node by absolute path.
    ///
    /// Descends by path prefix rather than searching the whole tree: at a few
    /// hundred thousand nodes a linear scan per preview would be noticeable, and
    /// the tree is already keyed by exactly the thing being looked up.
    func node(at path: String) -> ScanNode? {
        for root in roots {
            if root.path == path { return root }
            guard path.hasPrefix(root.path + "/") else { continue }
            var current = root
            descend: while true {
                if current.path == path { return current }
                for child in current.children
                where path == child.path || path.hasPrefix(child.path + "/") {
                    current = child
                    continue descend
                }
                return nil
            }
        }
        return nil
    }
}
