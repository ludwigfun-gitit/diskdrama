import Foundation
import Observation
import SwiftData

/// State for the main window (F08).
///
/// Owns nothing the engine owns. `ScanEngine` remains the source of truth for
/// scan results; this holds the parts that only exist because there is a window
/// — which tier is showing, which row is selected, and the last-scan data
/// rehydrated from disk for the case where the window opens before any scan has
/// run in this session.
///
/// Selection is kept **per tier**, not globally. Switching tiers and coming back
/// to find your place lost is a small thing that makes an app feel careless, and
/// the handoff's state list asks for exactly this (`selectedItemId` per tier).
@MainActor
@Observable
final class AppModel {

    enum Pane: Equatable {
        case tier(Tier)
        case changes
        case history
    }

    let scanEngine: ScanEngine
    let disk: DiskMonitor

    var pane: Pane = .tier(.safe)

    /// Per-tier selected row path.
    private var selectionByTier: [Tier: String] = [:]

    /// Last scan read back from the store at launch. Superseded the moment a
    /// scan completes in this session.
    private var restored: SnapshotRestorer.Restored?

    private(set) var cleanupLog: [CleanupEntry] = []
    private(set) var watchedCount: Int = 0

    /// What happened to the last scan, when it was something the user needs told.
    ///
    /// A cancelled or abandoned scan leaves the window looking exactly as it did
    /// before — same figures, same rows, because the previous snapshot stays
    /// authoritative (F07). Reverting silently reads as the Stop button having
    /// done nothing at all, so the outcome is stated and then cleared when the
    /// next scan starts.
    var scanNotice: String?

    init(scanEngine: ScanEngine, disk: DiskMonitor) {
        self.scanEngine = scanEngine
        self.disk = disk
    }

    // MARK: - Data

    /// This session's scan wins; otherwise whatever was on disk at launch.
    var recommendations: RecommendationSet? {
        scanEngine.recommendations ?? restored?.recommendations
    }

    var delta: Delta? {
        scanEngine.delta ?? restored?.delta
    }

    var lastScanAt: Date? {
        scanEngine.lastResult?.completedAt ?? restored?.scannedAt
    }

    /// True only before the very first scan has ever completed. Distinct from
    /// "scanned and found nothing", which F08 requires be said differently.
    var hasNeverScanned: Bool { recommendations == nil }

    var allTimeFreedBytes: Int64 {
        cleanupLog
            .filter { $0.outcome != .failed && $0.restoredAt == nil }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Loads everything the window needs that lives in the store.
    ///
    /// Failure is not fatal — the window falls back to "nothing scanned yet",
    /// same as the app degrades to monitor-only when the store won't open at all.
    func loadPersistedState() {
        guard let container = DataStore.shared.state.container else { return }
        let startedAt = Date()
        do {
            restored = try SnapshotRestorer.restoreLatest(from: container)

            let context = ModelContext(container)
            cleanupLog = try context.fetch(FetchDescriptor<CleanupEntry>(
                sortBy: [SortDescriptor(\.performedAt, order: .reverse)]))
            watchedCount = try context.fetch(FetchDescriptor<WatchedPath>())
                .filter(\.isActive).count

            Log.app.notice("""
            window state — seconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public) \
            restored=\(self.restored != nil, privacy: .public) \
            recommendations=\(self.recommendations?.recommendations.count ?? 0, privacy: .public) \
            cleanups=\(self.cleanupLog.count, privacy: .public) \
            watched=\(self.watchedCount, privacy: .public)
            """)
        } catch {
            Log.app.error("window state failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Selection

    var activeTier: Tier? {
        if case .tier(let tier) = pane { return tier }
        return nil
    }

    func items(in tier: Tier) -> [Recommendation] {
        recommendations?.inTier(tier) ?? []
    }

    func reclaimable(in tier: Tier) -> Int64 {
        recommendations?.reclaimableBytes(in: tier) ?? 0
    }

    /// The selected row for a tier, defaulting to the first (largest) item —
    /// which is what the handoff shows and also the row the user almost always
    /// wants. Falls back when the previous selection is gone after a rescan.
    func selection(in tier: Tier) -> Recommendation? {
        let items = items(in: tier)
        if let path = selectionByTier[tier], let match = items.first(where: { $0.path == path }) {
            return match
        }
        return items.first
    }

    func select(_ recommendation: Recommendation, in tier: Tier) {
        selectionByTier[tier] = recommendation.path
    }

    // MARK: - Derived display data

    /// The mini storage map's cells: the biggest consumers on the disk, whether
    /// or not they are recommendable.
    ///
    /// Deliberately merges both lists. A map that only showed reclaimable things
    /// would answer "what can I delete", which the rest of the window already
    /// answers — the question this panel exists for is "where did it all go",
    /// and Photos being the largest thing on the disk is a legitimate answer.
    ///
    /// **The cells must not overlap.** The two lists nest freely: a top-level
    /// folder can sit in one and a recommendation from inside it in the other,
    /// and a naive merge shows both — the same gigabytes drawn twice, under a
    /// heading that claims to account for the disk. Largest-first plus an
    /// ancestry filter keeps whichever region contains the other, so the cells
    /// partition the space instead of double-counting it.
    var topConsumers: [(name: String, sizeBytes: Int64)] {
        guard let set = recommendations else { return [] }

        let candidates =
            set.recommendations.map { (path: $0.path, name: $0.classification.title, sizeBytes: $0.sizeBytes) }
            + set.largestNonRecommendable.map { (path: $0.path, name: $0.name, sizeBytes: $0.sizeBytes) }

        var accepted: [(path: String, name: String, sizeBytes: Int64)] = []
        for candidate in candidates.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
            let isContained = accepted.contains {
                candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/")
            }
            guard !isContained else { continue }
            accepted.append(candidate)
            if accepted.count == 3 { break }
        }
        return accepted.map { (name: $0.name, sizeBytes: $0.sizeBytes) }
    }

    /// Paths that grew back since the last scan, for the "Back again" row badge.
    var regrownPaths: Set<String> {
        Set((delta?.regrown ?? []).map(\.path))
    }

    var blindSpots: [(path: String, reason: BlindSpotReason)] {
        recommendations?.blindSpots ?? []
    }
}
