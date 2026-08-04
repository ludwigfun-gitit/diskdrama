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
        case watching
    }

    let scanEngine: ScanEngine
    let disk: DiskMonitor

    /// F09's deeper prose (A05). Local classification still does all the
    /// tiering; this only enriches the item the user is looking at.
    let explanations = ExplanationService()

    /// F19's Settings surface, which also carries the API key (A02).
    var isShowingSettings = false

    /// F05. Shown once, on the first launch with no prior state.
    var isShowingOnboarding = !Settings.shared.hasCompletedOnboarding

    // MARK: - Deletion (F14–F16)

    enum ActiveSheet: Identifiable {
        case delete(Recommendation)
        case batchClean(Tier)
        case target

        var id: String {
            switch self {
            case .delete(let item):  "delete-\(item.path)"
            case .batchClean(let t): "batch-\(t.rawValue)"
            case .target:            "target"
            }
        }
    }

    var activeSheet: ActiveSheet?

    /// A04: the per-job deletion mode, pre-set from the global default and
    /// **reset every time a sheet opens**. A user who flips one job to
    /// permanent must not find the next job silently pre-flipped too — that is
    /// precisely the setting where a sticky value does damage.
    var moveToTrash = true

    /// F24's running figure. Deliberately separate from the volume reading:
    /// Trash-mode bytes are *not* reclaimed until the Trash is emptied, so this
    /// counts only what actually left the disk.
    private(set) var reclaimedThisSessionBytes: Int64 = 0
    /// Bytes moved to the Trash this session — recoverable, and still occupying
    /// the disk. Reported separately rather than folded into the figure above,
    /// which would be a claim the app cannot back up.
    private(set) var trashedThisSessionBytes: Int64 = 0

    /// Items deleted in this session, so they leave the list immediately
    /// without waiting for a rescan.
    private var deletedPaths: Set<String> = []

    // MARK: - Snooze / dismiss (F17, F18)

    /// F18 — "never suggest this". Still scanned, still counted toward totals,
    /// simply never offered. Survives rescans.
    private(set) var ignoredPaths: Set<String> = []
    /// F17 — "not now". Hidden until the next scan, then back.
    private(set) var snoozedPaths: Set<String> = []

    /// The last thing that went wrong, for the sheet to show.
    var deletionError: String?

    func presentDeleteSheet(for item: Recommendation) {
        moveToTrash = Settings.shared.defaultDeletionMode == .trash
        deletionError = nil
        activeSheet = .delete(item)
    }

    func presentBatchSheet(for tier: Tier) {
        moveToTrash = Settings.shared.defaultDeletionMode == .trash
        deletionError = nil
        activeSheet = .batchClean(tier)
    }

    /// F14. Returns true when the item actually went.
    @discardableResult
    func delete(_ item: Recommendation, batchID: UUID? = nil) async -> Bool {
        let mode: DeletionMode = moveToTrash ? .trash : .immediate
        do {
            let outcome = try await DeletionService.perform(item, mode: mode)
            record(outcome, batchID: batchID)
            deletedPaths.insert(outcome.path)
            if mode == .trash {
                trashedThisSessionBytes += outcome.sizeBytes
            } else {
                reclaimedThisSessionBytes += outcome.sizeBytes
            }
            disk.refresh()
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.app.error("deletion refused or failed: \(message, privacy: .public)")
            deletionError = message
            // A failed item is still logged, so the history shows the attempt
            // rather than silently omitting it.
            recordFailure(item, mode: mode, detail: message, batchID: batchID)
            return false
        }
    }

    /// F15. One batch ID across the job so the log can summarise it as a job
    /// rather than as N unrelated rows.
    func deleteBatch(_ items: [Recommendation]) async {
        let batchID = UUID()
        let freeBefore = disk.info?.strictAvailableBytes ?? 0
        let mode: DeletionMode = moveToTrash ? .trash : .immediate
        var expected: Int64 = 0

        for item in items {
            if await delete(item, batchID: batchID) { expected += item.sizeBytes }
        }
        verify(expected: expected, mode: mode, freeBefore: freeBefore)
        loadPersistedState()
    }

    // MARK: - Verify reclaimed space (F24)

    struct Verification: Sendable {
        let expectedBytes: Int64
        let observedBytes: Int64
        let mode: DeletionMode
        let message: String
    }

    /// What the app is willing to claim after a job, and why.
    private(set) var lastVerification: Verification?

    /// Mode-aware, per A04's ripple.
    ///
    /// The comparison uses `strictAvailableBytes` — the reading that *excludes*
    /// purgeable space. The friendlier number macOS shows everywhere includes a
    /// pool the system shuffles on its own, so it can move without anything
    /// being reclaimed and fail to move when something was. That is exactly the
    /// wrong yardstick for "did that deletion actually work", and keeping both
    /// readings since Step 1 is what makes this answerable at all.
    func verify(expected: Int64, mode: DeletionMode, freeBefore: Int64) {
        guard expected > 0 else { return }
        disk.refresh()
        let after = disk.info?.strictAvailableBytes ?? freeBefore
        let observed = after - freeBefore

        let message: String
        switch mode {
        case .trash:
            // Never claim reclaimed space for something still on the disk.
            message = "\(ByteFormat.compact(expected)) moved to the Trash. That space comes back "
                + "when you empty it — until then it is still on the disk."
        case .immediate:
            let drift = abs(observed - expected)
            let tolerance = max(Int64(Double(expected) * 0.05), 50_000_000)
            if drift <= tolerance {
                message = "\(ByteFormat.compact(expected)) deleted, and the volume shows about "
                    + "\(ByteFormat.compact(observed)) more free. That matches."
            } else if observed < expected {
                message = "\(ByteFormat.compact(expected)) deleted, but the volume only shows "
                    + "\(ByteFormat.compact(observed)) more free so far. APFS can take a moment to "
                    + "release space, and local snapshots may still be holding some of it — it "
                    + "usually catches up within a few minutes."
            } else {
                message = "\(ByteFormat.compact(expected)) deleted, and the volume shows "
                    + "\(ByteFormat.compact(observed)) more free — more than expected, because "
                    + "something else released space at the same time."
            }
        }

        lastVerification = Verification(expectedBytes: expected, observedBytes: observed,
                                        mode: mode, message: message)
        Log.app.notice("verified — expected=\(ByteFormat.compact(expected), privacy: .public) observed=\(ByteFormat.compact(observed), privacy: .public) mode=\(mode.rawValue, privacy: .public)")
    }

    /// F16. Only offered for Trash-mode entries that are still restorable.
    func undo(_ entry: CleanupEntry) async {
        guard let trashedPath = entry.trashedPath else { return }
        do {
            try await DeletionService.restore(from: trashedPath, to: entry.path)
            markRestored(entry)
            // A restore re-consumes space, so the session totals have to move
            // back — otherwise the app would keep claiming it freed something
            // that is once again on the disk.
            trashedThisSessionBytes = max(0, trashedThisSessionBytes - entry.sizeBytes)
            deletedPaths.remove(entry.path)
            disk.refresh()
            loadPersistedState()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.app.error("restore failed: \(message, privacy: .public)")
            deletionError = message
        }
    }

    // MARK: - Cleanup log writes (F22)

    private func record(_ outcome: DeletionService.Outcome, batchID: UUID?) {
        guard let container = DataStore.shared.state.container else { return }
        let context = ModelContext(container)
        let entry = CleanupEntry(path: outcome.path, name: outcome.name,
                                 sizeBytes: outcome.sizeBytes, mode: outcome.mode,
                                 outcome: .succeeded, batchID: batchID)
        entry.trashedPath = outcome.trashedPath
        context.insert(entry)
        try? context.save()
        cleanupLog.insert(entry, at: 0)
    }

    private func recordFailure(_ item: Recommendation, mode: DeletionMode,
                               detail: String, batchID: UUID?) {
        guard let container = DataStore.shared.state.container else { return }
        let context = ModelContext(container)
        let entry = CleanupEntry(path: item.path, name: item.name,
                                 sizeBytes: item.sizeBytes, mode: mode,
                                 outcome: .failed, batchID: batchID)
        entry.failureDetail = detail
        context.insert(entry)
        try? context.save()
    }

    private func markRestored(_ entry: CleanupEntry) {
        guard let container = DataStore.shared.state.container else { return }
        let context = ModelContext(container)
        let id = entry.id
        var descriptor = FetchDescriptor<CleanupEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let stored = try? context.fetch(descriptor).first {
            stored.restoredAt = Date()
            stored.outcomeRaw = DeletionOutcome.restored.rawValue
            try? context.save()
        }
    }

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

    /// Bytes that actually left the disk, all-time.
    ///
    /// Trash-mode jobs are **excluded**: those bytes are still occupying the
    /// volume until the Trash is emptied. A04's ripple into F24 is explicit
    /// that a Trash job must not claim reclaimed space, and a footer reading
    /// "264 MB freed" while half of it sits in the Trash is the same false
    /// claim in a quieter place.
    var allTimeFreedBytes: Int64 {
        cleanupLog
            .filter { $0.outcome != .failed && $0.restoredAt == nil && $0.mode == .immediate }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Bytes sitting in the Trash from past jobs — recoverable, and still
    /// taking up room. Reported next to the freed figure rather than folded
    /// into it.
    var allTimeTrashedBytes: Int64 {
        cleanupLog
            .filter { $0.outcome != .failed && $0.restoredAt == nil && $0.mode == .trash }
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
            watches = try context.fetch(FetchDescriptor<WatchedPath>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            watchedCount = watches.filter(\.isActive).count
            ignoredPaths = Set(try context.fetch(FetchDescriptor<IgnoredPath>()).map(\.path))
            snoozedPaths = Set(try context.fetch(FetchDescriptor<SnoozedPath>()).map(\.path))

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

    /// Deleted items leave the list immediately rather than lingering until the
    /// next scan — a row you just deleted still sitting there reads as a
    /// failure, and clicking it again would fail the existence guard.
    func items(in tier: Tier) -> [Recommendation] {
        (recommendations?.inTier(tier) ?? []).filter {
            !deletedPaths.contains($0.path)
                && !ignoredPaths.contains($0.path)
                && !snoozedPaths.contains($0.path)
        }
    }

    /// F17: hidden now, back after the next scan.
    func snooze(_ item: Recommendation) {
        snoozedPaths.insert(item.path)
        write { context in context.insert(SnoozedPath(path: item.path, snapshotID: UUID())) }
    }

    /// F18: hidden for good, until un-ignored in Settings.
    func dismiss(_ item: Recommendation) {
        ignoredPaths.insert(item.path)
        write { context in context.insert(IgnoredPath(path: item.path, name: item.name)) }
    }

    func unignore(path: String) {
        ignoredPaths.remove(path)
        write { context in
            let rows = (try? context.fetch(FetchDescriptor<IgnoredPath>())) ?? []
            for row in rows where row.path == path { context.delete(row) }
        }
    }

    /// Snoozes are cleared wholesale when a scan lands — that *is* F17's
    /// "reappears next scan", and expiring them by event rather than by
    /// timestamp means there is no sweep to run and nothing to leak.
    func clearSnoozes() {
        snoozedPaths.removeAll()
        write { context in
            for row in (try? context.fetch(FetchDescriptor<SnoozedPath>())) ?? [] {
                context.delete(row)
            }
        }
    }

    /// F19 — "don't even look". Unlike F18 this changes what the *scanner*
    /// does, so it lives in `Settings` where the scan's inner loop can read it
    /// synchronously, not in the store.
    func exclude(path: String) {
        var current = Settings.shared.exclusions
        guard !current.contains(path) else { return }
        current.append(path)
        Settings.shared.exclusions = current
    }

    func unexclude(path: String) {
        Settings.shared.exclusions = Settings.shared.exclusions.filter { $0 != path }
    }

    // MARK: - Watches (F21)

    private(set) var watches: [WatchedPath] = []

    /// A06: the default threshold is the size the item had when it was last
    /// cleaned — "back to where it was when you dealt with it" is the event
    /// worth being told about, and it needs no number from the user.
    func watch(_ item: Recommendation) {
        let lastCleanedSize = cleanupLog.first { $0.path == item.path }?.sizeBytes ?? item.sizeBytes
        write { context in
            context.insert(WatchedPath(path: item.path, name: item.name,
                                       sizeAtLastClean: lastCleanedSize))
        }
        loadPersistedState()
    }

    func unwatch(_ watch: WatchedPath) {
        let path = watch.path
        write { context in
            for row in (try? context.fetch(FetchDescriptor<WatchedPath>())) ?? []
            where row.path == path { context.delete(row) }
        }
        loadPersistedState()
    }

    var isWatching: (Recommendation) -> Bool {
        { [watches] item in watches.contains { $0.path == item.path && $0.isActive } }
    }

    /// Checked after every scan. The scan has just measured everything, so this
    /// costs nothing beyond a dictionary lookup — no second walk.
    func checkWatches() {
        guard let set = recommendations else { return }
        let sizes = Dictionary(set.recommendations.map { ($0.path, $0.sizeBytes) },
                               uniquingKeysWith: { first, _ in first })

        for watch in watches where watch.isActive {
            guard let current = sizes[watch.path] else {
                // F21's failure case: the watched path is gone entirely. The
                // watch retires itself rather than firing forever against
                // nothing.
                retire(watch, reason: "the folder is no longer there")
                continue
            }
            guard current >= watch.thresholdBytes, watch.thresholdBytes > 0 else { continue }

            // One notification per regrowth, not one per scan. Without this a
            // watch on something that stays large becomes a daily nag and the
            // user turns notifications off entirely.
            if let last = watch.lastNotifiedAt, Date().timeIntervalSince(last) < 12 * 3600 { continue }

            Notifier.post(
                title: "\(watch.name) is back",
                body: "\(PathDisplay.short(watch.path)) is at \(ByteFormat.compact(current)) — "
                    + "about where it was when you last cleaned it.",
                category: .watchExceeded,
                id: "watch-\(watch.path)")
            markNotified(watch)
        }
    }

    private func retire(_ watch: WatchedPath, reason: String) {
        let path = watch.path
        write { context in
            for row in (try? context.fetch(FetchDescriptor<WatchedPath>())) ?? []
            where row.path == path {
                row.retiredAt = Date()
                row.retiredReason = reason
            }
        }
        loadPersistedState()
    }

    private func markNotified(_ watch: WatchedPath) {
        let path = watch.path
        write { context in
            for row in (try? context.fetch(FetchDescriptor<WatchedPath>())) ?? []
            where row.path == path { row.lastNotifiedAt = Date() }
        }
    }

    private func write(_ body: (ModelContext) -> Void) {
        guard let container = DataStore.shared.state.container else { return }
        let context = ModelContext(container)
        body(context)
        try? context.save()
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

// MARK: - Full Disk Access (F05)

extension AppModel {
    var hasFullDiskAccess: Bool { FullDiskAccess.isGranted() }

    /// Dismissal is remembered but not permanent — it re-arms if the user
    /// dismisses it and later grants access and revokes it again, because at
    /// that point it is news rather than nagging.
    var hasDismissedAccessBanner: Bool {
        Settings.shared.fullDiskAccessBannerDismissedAt != nil
    }

    func dismissAccessBanner() {
        Settings.shared.fullDiskAccessBannerDismissedAt = Date()
    }
}
