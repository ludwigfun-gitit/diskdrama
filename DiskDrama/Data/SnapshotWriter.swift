import Foundation
import SwiftData

/// Converts a completed scan into a persisted snapshot (F06), pruned on the way in.
///
/// The prune is the whole point. A scanned home directory is hundreds of thousands
/// of directory nodes and millions of files; SwiftData was chosen on the premise
/// that this app's data is "small, mostly append-only", and a million-row insert
/// per scan would break that premise quietly rather than the choice being wrong.
///
/// What survives:
/// - every recommendation, whatever its size — these are the rows the user acts on
/// - every other node above the prune floor — these are what the delta compares
///
/// What does not: everything smaller. The delta is about meaningful consumers
/// regrowing, not about individual small files appearing, so nothing is lost that
/// F20 would have used.
///
/// Roll-up totals on the `Snapshot` itself are computed over the **full** tree, so
/// headline figures stay exact even though the detail beneath them is pruned.
enum SnapshotWriter {

    /// Builds the object graph. Pure construction — no context, no insert — so the
    /// caller decides which actor performs the write.
    static func makeSnapshot(
        from result: ScanResult,
        recommendations: RecommendationSet,
        volume: DiskInfo?,
        pruneFloorBytes: Int64
    ) -> Snapshot {

        let snapshot = Snapshot(
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            rootPaths: result.roots.map(\.path)
        )
        snapshot.totalScannedBytes = result.totalSizeBytes
        snapshot.visitedEntryCount = result.visitedEntryCount
        snapshot.pruneFloorBytes = pruneFloorBytes

        if let volume {
            snapshot.volumeTotalBytes = volume.totalBytes
            snapshot.volumeAvailableBytes = volume.availableBytes
            snapshot.volumeStrictAvailableBytes = volume.strictAvailableBytes
        }

        // Recommendations first, so their classification wins if the same path
        // also clears the prune floor as a plain node.
        var written = Set<String>()

        for rec in recommendations.recommendations {
            let item = SnapshotItem(
                path: rec.path, name: rec.name,
                sizeBytes: rec.sizeBytes, logicalBytes: rec.logicalBytes,
                fileCount: rec.fileCount, isDirectory: true,
                newestModifiedAt: rec.newestModifiedAt)
            item.tier = rec.tier
            item.classificationKey = rec.classification.key
            item.confidence = rec.classification.confidence
            item.isRecommendation = true
            item.snapshot = snapshot
            snapshot.items.append(item)
            written.insert(rec.path)
        }

        for root in result.roots {
            collect(root, into: snapshot, floor: pruneFloorBytes, written: &written)
        }

        for spot in result.blindSpots {
            let blind = BlindSpot(path: spot.path, reason: spot.reason)
            blind.snapshot = snapshot
            snapshot.blindSpots.append(blind)
        }

        return snapshot
    }

    private static func collect(_ node: ScanNode, into snapshot: Snapshot,
                                floor: Int64, written: inout Set<String>) {
        // Depth-first, but pruned at the node: if a subtree's *total* is below the
        // floor, nothing inside it can be above it either, so the whole branch is
        // skipped rather than walked and discarded.
        guard node.sizeBytes >= floor else { return }

        if !written.contains(node.path) && node.depth > 0 {
            let item = SnapshotItem(
                path: node.path, name: node.name,
                sizeBytes: node.sizeBytes, logicalBytes: node.logicalBytes,
                fileCount: node.fileCount, isDirectory: true,
                newestModifiedAt: node.newestModifiedAt)
            item.tier = Tier.reviewFirst
            item.isRecommendation = false
            item.snapshot = snapshot
            snapshot.items.append(item)
            written.insert(node.path)
        }

        for child in node.children {
            collect(child, into: snapshot, floor: floor, written: &written)
        }
    }
}
