import Foundation

/// A single row in the recommendations view (F08).
struct Recommendation: Sendable, Identifiable {
    var id: String { path }

    let path: String
    let name: String
    let classification: Classification

    /// Physical bytes — what actually frees on delete.
    let sizeBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let newestModifiedAt: Date?

    var tier: Tier { classification.tier }

    /// Days since anything in here was touched. One of the strongest signals in an
    /// explanation: "nothing here has changed in fourteen months" carries more
    /// weight than any amount of prose about what the folder is for.
    var daysSinceModified: Int? {
        guard let date = newestModifiedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
}

/// The set of recommendations produced from one scan.
struct RecommendationSet: Sendable {
    let recommendations: [Recommendation]
    let blindSpots: [(path: String, reason: BlindSpotReason)]

    /// Largest consumers that are deliberately **not** recommended.
    ///
    /// F08's failure case needs these: when there is nothing worth suggesting, the
    /// app has to say so and show what the space actually went on ("Your space is
    /// mostly Photos (26 GB) — nothing I'd advise deleting") rather than showing an
    /// empty list, which reads like a broken scan.
    let largestNonRecommendable: [(path: String, name: String, sizeBytes: Int64)]

    let totalScannedBytes: Int64

    func inTier(_ tier: Tier) -> [Recommendation] {
        recommendations.filter { $0.tier == tier }
    }

    func reclaimableBytes(in tier: Tier) -> Int64 {
        inTier(tier).reduce(0) { $0 + $1.sizeBytes }
    }

    /// Headline figure. Tier 2 is excluded deliberately — DiskDrama cannot free
    /// that space itself, only point at the app that can, so counting it would be
    /// promising something the app does not deliver.
    var totalReclaimableBytes: Int64 {
        reclaimableBytes(in: .safe) + reclaimableBytes(in: .reviewFirst)
    }
}

/// Turns a scanned tree into tiered recommendations.
///
/// Pure computation over an already-built tree — no filesystem access — so it runs
/// wherever the caller puts it, and `ScanEngine` runs it on the same background
/// queue as the walk.
enum RecommendationBuilder {

    /// Unmatched folders below this are never offered for review. Without a floor,
    /// Tier 3 fills with every mid-sized folder in the home directory and the
    /// signal disappears into the noise.
    static let unknownItemFloorBytes: Int64 = 1_000_000_000

    /// How small a folder can be and still be worth opening.
    ///
    /// This was a tenth of the Tier 3 floor — 100 MB — which quietly capped the
    /// whole classifier: a rule that fires at 20 MB could never be reached
    /// through a parent under 100 MB, and since a parent is always at least as
    /// large as its child, every rule with a minimum below 100 MB was partly
    /// unreachable. A 60 MB `node_modules` in a 60 MB project was invisible.
    /// The floor now follows the most permissive rule, so traversal is never
    /// the thing that decides what is classifiable.
    /// Entries in one subtree past which the shape itself is worth reporting.
    ///
    /// Matches `DirectoryPreview.enumerationCeiling`, which is the count at which
    /// the app already declines to list a folder's contents — so this is the app
    /// agreeing with itself about what "too many to deal with" means, rather than
    /// a second number invented here.
    static let crowdedDirectoryFileCount = 200_000

    static var descendFloorBytes: Int64 {
        min(unknownItemFloorBytes / 10, KnowledgeBase.smallestRuleMinimumBytes)
    }

    static func build(
        from result: ScanResult,
        ignoredPaths: Set<String> = [],
        snoozedPaths: Set<String> = []
    ) -> RecommendationSet {

        var recommendations: [Recommendation] = []
        var nonRecommendable: [(path: String, name: String, sizeBytes: Int64)] = []

        // Paths that took pathologically long to enumerate, so the finding can be
        // attached to the node when the walk reaches it in this pass.
        // `result.slowDirectories` is still collected and still surfaced as scan
        // diagnostics, but it no longer decides anything a user can act on. It
        // measures how the scan went, not what is on the disk.

        /// Walks a subtree, deciding at each node whether it is a recommendation,
        /// and — crucially — whether to keep descending.
        func visit(_ node: ScanNode) {
            // F18: dismissed items are still scanned and still counted toward
            // totals, but never suggested. That is the whole distinction from an
            // F19 exclusion, which never gets here at all.
            if ignoredPaths.contains(node.path) || snoozedPaths.contains(node.path) {
                return
            }

            if let (rule, classification) = KnowledgeBase.classify(path: node.path, name: node.name) {
                if node.sizeBytes >= rule.minimumSizeBytes {
                    recommendations.append(Recommendation(
                        path: node.path, name: node.name, classification: classification,
                        sizeBytes: node.sizeBytes, logicalBytes: node.logicalBytes,
                        fileCount: node.fileCount, newestModifiedAt: node.newestModifiedAt))
                }
                // Terminal rules stop here whether or not the node was big enough.
                // This is what prevents recommending DerivedData *and* each of the
                // forty projects inside it — the same gigabytes counted twice in
                // one list is the fastest way for a cleanup tool to lose trust.
                if rule.isTerminal { return }
            }

            // Nothing matched. Descend if there is anything worth descending into.
            var descended = false
            for child in node.children where child.sizeBytes >= descendFloorBytes {
                visit(child)
                descended = true
            }

            // A large unmatched leaf — nothing recognised it and nothing beneath it
            // was worth exploring — is offered for review with an explicit "I don't
            // know what this is", never a confident guess.
            //
            // The crowded-directory finding shares this slot rather than
            // pre-empting it. It used to run *before* classification and descent
            // and return immediately, so a folder that happened to be slow to
            // list never got looked inside — `~/Library` became one blanket
            // recommendation and the real caches within it were never found. Now
            // a folder only earns this finding if descending failed to identify
            // anything, which is the same bar `unknown()` has always had.
            //
            // Preferred over `unknown()` when both apply, because "this holds
            // 800,000 files" is a more useful thing to tell someone than "I don't
            // recognise this".
            if !descended && node.depth > 0, node.fileCount >= crowdedDirectoryFileCount {
                recommendations.append(Recommendation(
                    path: node.path, name: node.name,
                    classification: KnowledgeBase.crowdedDirectoryFinding(
                        path: node.path, name: node.name, fileCount: node.fileCount),
                    sizeBytes: node.sizeBytes, logicalBytes: node.logicalBytes,
                    fileCount: node.fileCount, newestModifiedAt: node.newestModifiedAt))
            } else if !descended && node.sizeBytes >= unknownItemFloorBytes && node.depth > 0 {
                recommendations.append(Recommendation(
                    path: node.path, name: node.name,
                    classification: KnowledgeBase.unknown(name: node.name),
                    sizeBytes: node.sizeBytes, logicalBytes: node.logicalBytes,
                    fileCount: node.fileCount, newestModifiedAt: node.newestModifiedAt))
            }
        }

        for root in result.roots {
            for child in root.children {
                visit(child)
            }
        }

        // Anything big that produced no recommendation, for F08's empty case.
        let recommendedPaths = Set(recommendations.map(\.path))
        for root in result.roots {
            for child in root.children.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(12)
            where !recommendedPaths.contains(child.path) && child.sizeBytes >= unknownItemFloorBytes {
                nonRecommendable.append((child.path, child.name, child.sizeBytes))
            }
        }

        // Largest first within the whole set; the UI groups by tier and inherits
        // this ordering inside each group, which is F08's stated sort.
        recommendations.sort { $0.sizeBytes > $1.sizeBytes }

        return RecommendationSet(
            recommendations: recommendations,
            blindSpots: result.blindSpots,
            largestNonRecommendable: nonRecommendable,
            totalScannedBytes: result.totalSizeBytes
        )
    }
}
