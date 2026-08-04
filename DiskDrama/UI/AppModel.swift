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

    /// F09's deeper prose (A05). Local classification still does all the
    /// tiering; this only enriches the item the user is looking at.
    let explanations = ExplanationService()

    /// Minimal API-key entry until Step 10 builds the real Settings surface.
    var isShowingAPIKeySheet = false

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
        guard selectionByTier[tier] != recommendation.path else { return }
        selectionByTier[tier] = recommendation.path
        resetDetailState(for: tier)
    }

    // MARK: - Drill-down (F13)

    /// Items descended into, below the selected row. Per tier, like the
    /// selection — walking three levels into a build folder and losing the trail
    /// by glancing at another tier would make the feature not worth having.
    private var drillStackByTier: [Tier: [Recommendation]] = [:]

    /// What the explanation panel is describing: the deepest thing drilled into,
    /// or the selected row when nothing has been.
    func detailItem(in tier: Tier) -> Recommendation? {
        drillStackByTier[tier]?.last ?? selection(in: tier)
    }

    /// The trail back up, selected row first. One element means no drilling has
    /// happened and the panel shows no breadcrumb.
    func breadcrumb(in tier: Tier) -> [Recommendation] {
        guard let root = selection(in: tier) else { return [] }
        return [root] + (drillStackByTier[tier] ?? [])
    }

    /// F13: same recommendation treatment one level down. The child is classified
    /// through the same knowledge base as anything else — an unrecognised child
    /// gets the same explicit "I can't tell what this is" rather than inheriting
    /// its parent's confident explanation, which would be a lie by association.
    func drill(into entry: DirectoryPreview.Entry, in tier: Tier) {
        let matched = KnowledgeBase.classify(path: entry.path, name: entry.name)?.result
            ?? KnowledgeBase.unknown(name: entry.name)

        // A subtree rule matches its children too, so a child would otherwise
        // inherit the parent's *title* — the panel would read "iOS device support
        // files" for one specific device folder, and descending would look like
        // only the numbers changed. The prose still describes what kind of thing
        // this is and stays; the name is the child's own.
        let classification = Classification(
            key: matched.key, tier: matched.tier, title: entry.name,
            whatThisIs: matched.whatThisIs, consequence: matched.consequence,
            rebuildCost: matched.rebuildCost, owningApp: matched.owningApp,
            confidence: matched.confidence)

        let item = Recommendation(
            path: entry.path, name: entry.name, classification: classification,
            sizeBytes: entry.sizeBytes, logicalBytes: entry.logicalBytes,
            fileCount: entry.fileCount, newestModifiedAt: entry.newestModifiedAt)

        drillStackByTier[tier, default: []].append(item)
        resetDetailState(for: tier, keepingSelection: true)
    }

    /// Returns to a level in the breadcrumb. Index 0 is the selected row.
    func popDrill(in tier: Tier, to index: Int) {
        let stack = drillStackByTier[tier] ?? []
        guard index < stack.count else { return }
        drillStackByTier[tier] = Array(stack.prefix(index))
        resetDetailState(for: tier, keepingSelection: true)
    }

    private func resetDetailState(for tier: Tier, keepingSelection: Bool = false) {
        if !keepingSelection { drillStackByTier[tier] = [] }
        lookInsideOpen = false
        preview = nil
        previewPath = nil
    }

    // MARK: - Look inside (F10)

    var lookInsideOpen = false
    private(set) var preview: DirectoryPreview.Result?
    private(set) var isLoadingPreview = false
    private var previewPath: String?

    func toggleLookInside(for item: Recommendation) {
        lookInsideOpen.toggle()
        guard lookInsideOpen, previewPath != item.path else { return }

        previewPath = item.path
        preview = nil
        isLoadingPreview = true

        DirectoryPreview.load(path: item.path,
                              fileCount: item.fileCount,
                              from: scanEngine.lastResult) { [weak self] result in
            guard let self, previewPath == item.path else { return }
            preview = result
            isLoadingPreview = false
        }
    }

    // MARK: - History lookup

    /// The most recent cleanup of this exact path, for the explanation panel's
    /// "you cleaned this and it came back" line.
    func lastCleanup(of path: String) -> CleanupEntry? {
        cleanupLog.first { $0.path == path && $0.restoredAt == nil }
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
