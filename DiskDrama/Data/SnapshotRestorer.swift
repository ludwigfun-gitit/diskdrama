import Foundation
import SwiftData

/// Rebuilds a `RecommendationSet` from the last persisted scan.
///
/// F08's trigger is "scan completion; **main window at any time (shows last
/// scan)**". `ScanEngine` only holds a set for a scan run in this session, so
/// without this the window would be blank after every relaunch even though a
/// perfectly good snapshot is sitting on disk — and a blank recommendations pane
/// reads as "the app is broken", not as "you haven't scanned yet".
///
/// ## Prose is re-derived, tier is not
///
/// Only the *identity* of a classification is persisted (`classificationKey`),
/// never its prose. The prose lives in `KnowledgeBase` and is re-derived here, so
/// improving an explanation improves it for old snapshots too, rather than
/// leaving stale copies frozen in the store.
///
/// The stored `tier` and `confidence` are used as-is. They are what the scan
/// concluded at the time and the snapshot is a record of that scan, not a
/// re-run of it.
enum SnapshotRestorer {

    struct Restored: Sendable {
        let recommendations: RecommendationSet
        let scannedAt: Date
        let volumeAvailableBytes: Int64
        /// Recomputed against the snapshot before this one, so the Changes view
        /// survives a relaunch. Nil when only one scan has ever run — F20's
        /// "first scan, nothing to compare against" is a different statement
        /// from "nothing changed" and the UI must not conflate them.
        let delta: Delta?
    }

    /// Reads the most recent snapshot. Returns nil when nothing has ever been
    /// scanned — which the UI must render as "no scan yet", distinct from
    /// "scanned and found nothing".
    static func restoreLatest(from container: ModelContainer) throws -> Restored? {
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<Snapshot>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        let recent = try context.fetch(descriptor)
        guard let snapshot = recent.first else { return nil }
        let delta = recent.dropFirst().first.flatMap {
            DeltaComputer.compare(previous: $0, current: snapshot)
        }

        var recommendations: [Recommendation] = []
        var nonRecommendable: [(path: String, name: String, sizeBytes: Int64)] = []

        // The live builder collects "largest non-recommendable" from the roots'
        // immediate children only. The store holds every node above the prune
        // floor, so without the same restriction a restored session would list
        // deeply nested folders that a freshly scanned one never would — and the
        // two paths must not disagree about the same scan.
        let rootPaths = Set(snapshot.rootPaths)

        for item in snapshot.items {
            if item.isRecommendation {
                recommendations.append(Recommendation(
                    path: item.path,
                    name: item.name,
                    classification: classification(for: item),
                    sizeBytes: item.sizeBytes,
                    logicalBytes: item.logicalBytes,
                    fileCount: item.fileCount,
                    newestModifiedAt: item.newestModifiedAt))
            } else if item.sizeBytes >= RecommendationBuilder.unknownItemFloorBytes,
                      rootPaths.contains((item.path as NSString).deletingLastPathComponent) {
                nonRecommendable.append((item.path, item.name, item.sizeBytes))
            }
        }

        recommendations.sort { $0.sizeBytes > $1.sizeBytes }
        nonRecommendable.sort { $0.sizeBytes > $1.sizeBytes }

        let set = RecommendationSet(
            recommendations: recommendations,
            blindSpots: snapshot.blindSpots.map { ($0.path, $0.reason) },
            largestNonRecommendable: Array(nonRecommendable.prefix(12)),
            totalScannedBytes: snapshot.totalScannedBytes)

        return Restored(recommendations: set,
                        scannedAt: snapshot.completedAt,
                        volumeAvailableBytes: snapshot.volumeAvailableBytes,
                        delta: delta)
    }

    /// Re-derives the explanation for a persisted item.
    ///
    /// By key first, so an item keeps the rule it was actually classified under.
    /// Falling back to re-matching by path would silently re-tier an item if the
    /// rule table has since changed — the snapshot would then disagree with its
    /// own recorded tier, and the delta would compare two different things.
    private static func classification(for item: SnapshotItem) -> Classification {
        if let key = item.classificationKey,
           let rule = KnowledgeBase.rulesByKey[key] {
            return Classification(
                key: rule.key, tier: item.tier, title: rule.title,
                whatThisIs: rule.whatThisIs, consequence: rule.consequence,
                rebuildCost: rule.rebuildCost, owningApp: rule.owningApp,
                confidence: item.confidence)
        }
        // Synthetic keys (unknown, pathological-directory findings) and anything
        // written by a build whose rule has since been removed land here. An
        // over-careful row is the correct failure, never an invented explanation.
        return KnowledgeBase.unknown(name: item.name)
    }
}
