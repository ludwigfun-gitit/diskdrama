import Foundation

/// What changed between two scans (F20) — the recurring-crisis radar.
///
/// The point of this view is not "here is a diff". It is to answer one question in
/// a glance: *is this a new problem, or the same one again?* Regrowth of something
/// previously cleaned is therefore called out separately and loudly, rather than
/// being one row among many in a list of increases.
struct Delta: Sendable {

    struct Change: Sendable, Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let previousBytes: Int64
        let currentBytes: Int64

        var deltaBytes: Int64 { currentBytes - previousBytes }

        /// Grew back from nothing, or near enough. The signature of a build folder
        /// that was cleaned and has refilled — the exact thing F21's watch list
        /// exists to catch.
        var isRegrowth: Bool {
            previousBytes < currentBytes / 10 && currentBytes > 0
        }
    }

    /// Consumers that did not exist, or were below the floor, in the previous scan.
    let appeared: [Change]
    /// Grew meaningfully.
    let grew: [Change]
    /// Shrank meaningfully — includes the results of the user's own cleanups.
    let shrank: [Change]
    /// Gone entirely.
    let disappeared: [Change]

    let previousScanAt: Date
    let currentScanAt: Date

    /// Net change across everything scanned.
    let netBytes: Int64

    /// The headline. Items that came back after being cleaned, biggest first —
    /// this is what turns one-off cleanup into the hygiene loop.
    var regrown: [Change] {
        (appeared + grew).filter(\.isRegrowth).sorted { $0.currentBytes > $1.currentBytes }
    }

    var isEmpty: Bool {
        appeared.isEmpty && grew.isEmpty && shrank.isEmpty && disappeared.isEmpty
    }
}

enum DeltaComputer {

    /// Changes smaller than this are noise. Ordinary use moves hundreds of
    /// megabytes around a disk between scans without any of it meaning anything,
    /// and a delta view that reports all of it is one nobody reads.
    static let significantChangeBytes: Int64 = 100_000_000

    /// Compares two snapshots.
    ///
    /// Per A07 the baseline is always the immediately previous completed scan —
    /// pinned baselines are explicitly Future scope.
    ///
    /// Both snapshots' prune floors are honoured: an item is only reported as
    /// having appeared or disappeared if it would have been *persisted* in the
    /// other snapshot had it been that size. Without this, raising the floor
    /// between versions would manufacture a wave of phantom "disappeared" rows for
    /// items that simply stopped being written.
    static func compare(previous: Snapshot, current: Snapshot) -> Delta {

        let floor = max(previous.pruneFloorBytes, current.pruneFloorBytes)

        var previousByPath: [String: SnapshotItem] = [:]
        for item in previous.items { previousByPath[item.path] = item }

        var currentByPath: [String: SnapshotItem] = [:]
        for item in current.items { currentByPath[item.path] = item }

        var appeared: [Delta.Change] = []
        var grew: [Delta.Change] = []
        var shrank: [Delta.Change] = []
        var disappeared: [Delta.Change] = []

        for (path, item) in currentByPath {
            if let before = previousByPath[path] {
                let change = Delta.Change(path: path, name: item.name,
                                          previousBytes: before.sizeBytes,
                                          currentBytes: item.sizeBytes)
                if change.deltaBytes >= significantChangeBytes {
                    grew.append(change)
                } else if change.deltaBytes <= -significantChangeBytes {
                    shrank.append(change)
                }
            } else if item.sizeBytes >= floor {
                appeared.append(Delta.Change(path: path, name: item.name,
                                             previousBytes: 0,
                                             currentBytes: item.sizeBytes))
            }
        }

        for (path, item) in previousByPath where currentByPath[path] == nil {
            guard item.sizeBytes >= floor else { continue }
            disappeared.append(Delta.Change(path: path, name: item.name,
                                            previousBytes: item.sizeBytes,
                                            currentBytes: 0))
        }

        return Delta(
            appeared: appeared.sorted { $0.currentBytes > $1.currentBytes },
            grew: grew.sorted { $0.deltaBytes > $1.deltaBytes },
            shrank: shrank.sorted { $0.deltaBytes < $1.deltaBytes },
            disappeared: disappeared.sorted { $0.previousBytes > $1.previousBytes },
            previousScanAt: previous.completedAt,
            currentScanAt: current.completedAt,
            netBytes: current.totalScannedBytes - previous.totalScannedBytes
        )
    }
}
