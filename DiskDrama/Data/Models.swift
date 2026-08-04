import Foundation
import SwiftData

// MARK: - Shared vocabulary

/// The three recommendation tiers (F08).
///
/// Raw values are stable and persisted — never renumber them.
enum Tier: Int, Codable, CaseIterable, Sendable {
    /// Regenerates automatically. Build artifacts, caches, package manager
    /// stores. The only tier with a batch action (A08).
    case safe = 1
    /// Belongs to another app and is cleared *through* that app. Carries an
    /// "Open <App>" pointer and deliberately has no delete button — DiskDrama
    /// never reaches into another app's managed storage.
    case appManaged = 2
    /// Personal or ambiguous. Strictly one item at a time, explanation first.
    /// Anything the classifier cannot confidently place lands here by default.
    case reviewFirst = 3

    var title: String {
        switch self {
        case .safe:        "Safe to delete"
        case .appManaged:  "App-managed"
        case .reviewFirst: "Review first"
        }
    }

    var subtitle: String {
        switch self {
        case .safe:        "Regenerates on its own"
        case .appManaged:  "Clear it from the owning app"
        case .reviewFirst: "Your data — read before acting"
        }
    }

    /// A08: batch approval exists for Tier 1 and nowhere else.
    var allowsBatchApproval: Bool { self == .safe }

    /// Tier 2 routes to the owning app instead of offering deletion.
    var allowsDeletion: Bool { self != .appManaged }
}

/// A04 — how a deletion is carried out. Global default in Settings, overridable
/// per job via the checkbox on every confirmation dialog.
enum DeletionMode: String, Codable, Sendable {
    /// Recoverable. Space frees only when the Trash is emptied — which is why
    /// F24 must never report a Trash job's bytes as reclaimed.
    case trash
    /// Gone now. No undo. F16 renders no undo action for these, rather than a
    /// dead button.
    case immediate

    var isUndoable: Bool { self == .trash }
}

/// How a deletion job ended. Partial is a real outcome, not an error case —
/// F14/F15 require reporting exactly what remains rather than a half-done job
/// presented as success.
enum DeletionOutcome: String, Codable, Sendable {
    case succeeded
    case partial
    case failed
    case restored
}

/// Why a location could not be read (F06). Recorded and shown; never guessed at.
enum BlindSpotReason: String, Codable, Sendable {
    case fullDiskAccessMissing
    case permissionDenied
    case unreadable
    case excludedByUser
}

// MARK: - Scan snapshots

/// One completed scan.
///
/// Only *completed* scans are persisted. A cancelled or interrupted scan is
/// discarded entirely and the previous snapshot stays authoritative (F06/F07) —
/// a half-populated snapshot would poison the delta comparison silently.
@Model
final class Snapshot {
    /// Stable identity for the explanation cache and delta pairing.
    var id: UUID = UUID()
    var startedAt: Date = Date.distantPast
    var completedAt: Date = Date.distantPast

    /// Scan roots this snapshot actually covered (A03).
    var rootPaths: [String] = []

    /// Total bytes attributed across all roots, and how many filesystem entries
    /// were visited. Both are roll-ups over the *full* in-memory tree, not over
    /// the pruned `items` below — otherwise the headline totals would silently
    /// under-report everything beneath the prune floor.
    var totalScannedBytes: Int64 = 0
    var visitedEntryCount: Int = 0

    /// Volume free space at completion, both readings (see `DiskInfo`).
    var volumeAvailableBytes: Int64 = 0
    var volumeStrictAvailableBytes: Int64 = 0
    var volumeTotalBytes: Int64 = 0

    /// The prune floor this snapshot was written with. Persisted because it is a
    /// property *of the snapshot*, not of the current build — comparing two
    /// snapshots written under different floors without knowing it would produce
    /// phantom deltas.
    var pruneFloorBytes: Int64 = 0

    @Relationship(deleteRule: .cascade, inverse: \SnapshotItem.snapshot)
    var items: [SnapshotItem] = []

    @Relationship(deleteRule: .cascade, inverse: \BlindSpot.snapshot)
    var blindSpots: [BlindSpot] = []

    init(id: UUID = UUID(), startedAt: Date, completedAt: Date, rootPaths: [String]) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.rootPaths = rootPaths
    }
}

/// A single persisted node from a scan.
///
/// ## Why these are pruned
///
/// A full home-directory tree is millions of nodes. SwiftData was chosen on the
/// premise that DiskDrama's data is "small, mostly append-only" (preflight §Data
/// model), and handing it a million-row insert per scan would quietly break that
/// premise rather than the choice being wrong.
///
/// So the full tree lives in memory for the session, and what gets persisted is:
/// every recommendation item regardless of size, plus every node above the prune
/// floor. That is exactly what F20's delta needs — the delta is about meaningful
/// consumers regrowing, not about individual small files appearing.
@Model
final class SnapshotItem {
    /// Absolute path. Unique within a snapshot.
    var path: String = ""
    /// Display name — the last path component, stored rather than derived so the
    /// UI never has to do path arithmetic on the main thread.
    var name: String = ""

    /// Bytes actually occupied on disk (`st_blocks * 512`), summed over the
    /// subtree. This is what frees when the item is deleted, and it is the number
    /// every reclaim figure in the app is built from.
    var sizeBytes: Int64 = 0
    /// Sum of `st_size`. Kept because it is what Finder shows, so a divergence
    /// (sparse files, APFS clones, compression) can be explained rather than
    /// leaving the user to notice the app and Finder disagree.
    var logicalBytes: Int64 = 0

    var fileCount: Int = 0
    var isDirectory: Bool = true
    /// Newest modification time in the subtree — "when was this last touched"
    /// is one of the strongest staleness signals in an explanation.
    var newestModifiedAt: Date?

    /// Classification. `tierRaw` is stored; `tier` is the typed accessor.
    var tierRaw: Int = Tier.reviewFirst.rawValue
    /// Which knowledge-base rule matched, or nil if nothing did. Also the cache
    /// key that lets an explanation survive across scans.
    var classificationKey: String?
    /// 0…1. Low confidence forces Tier 3 and an explicit "I can't tell what this
    /// contains" in the UI (F09's failure case).
    var confidence: Double = 0

    /// Whether this node is offered as a recommendation or is only present to
    /// give the delta something to compare against.
    var isRecommendation: Bool = false

    var snapshot: Snapshot?

    var tier: Tier {
        get { Tier(rawValue: tierRaw) ?? .reviewFirst }
        set { tierRaw = newValue.rawValue }
    }

    /// Identity for the explanation cache (A05): an explanation stays valid while
    /// the thing it describes hasn't changed. Size and mtime together are enough —
    /// content changed means size or mtime moved.
    var fingerprint: String {
        let stamp = newestModifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "\(path)|\(sizeBytes)|\(stamp)"
    }

    init(path: String, name: String, sizeBytes: Int64, logicalBytes: Int64,
         fileCount: Int, isDirectory: Bool, newestModifiedAt: Date?) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.newestModifiedAt = newestModifiedAt
    }
}

/// A location the scan could not read (F06).
///
/// Recorded per snapshot and surfaced in the results. The app states what it
/// could not see rather than presenting a partial picture as complete — an
/// advisor that quietly under-reports is worse than one that admits a gap.
@Model
final class BlindSpot {
    var path: String = ""
    var reasonRaw: String = BlindSpotReason.unreadable.rawValue
    var snapshot: Snapshot?

    var reason: BlindSpotReason {
        get { BlindSpotReason(rawValue: reasonRaw) ?? .unreadable }
        set { reasonRaw = newValue.rawValue }
    }

    init(path: String, reason: BlindSpotReason) {
        self.path = path
        self.reasonRaw = reason.rawValue
    }
}

// MARK: - Cleanup log (F22)

/// One deletion, restore, or watch event. Append-only, survives restarts.
///
/// The log is also the undo ledger (F16) and the verification record (F24), so
/// it stores the mode the job ran in — without it, the log cannot tell whether
/// an entry is recoverable and would have to render undo buttons that may be
/// dead.
@Model
final class CleanupEntry {
    var id: UUID = UUID()
    var performedAt: Date = Date.distantPast
    var path: String = ""
    var name: String = ""
    var sizeBytes: Int64 = 0

    var modeRaw: String = DeletionMode.trash.rawValue
    var outcomeRaw: String = DeletionOutcome.succeeded.rawValue

    /// Groups the items of one batch job (F15) so the log can summarise
    /// "Freed 38.2 GB across 11 items" instead of listing eleven unrelated rows.
    var batchID: UUID?

    /// Populated on partial or failed outcomes: exactly what went wrong and
    /// which app held the file, in the words the user will see.
    var failureDetail: String?

    /// Set when the item is restored from the Trash (F16). A restore re-consumes
    /// space, so verification totals have to account for it explicitly.
    var restoredAt: Date?

    var mode: DeletionMode {
        get { DeletionMode(rawValue: modeRaw) ?? .trash }
        set { modeRaw = newValue.rawValue }
    }

    var outcome: DeletionOutcome {
        get { DeletionOutcome(rawValue: outcomeRaw) ?? .succeeded }
        set { outcomeRaw = newValue.rawValue }
    }

    /// F16: undo exists only for Trash-mode jobs whose items are still there.
    /// Immediate-mode entries render no undo action at all.
    var isRestorable: Bool {
        mode.isUndoable && restoredAt == nil && outcome != .failed
    }

    init(path: String, name: String, sizeBytes: Int64,
         mode: DeletionMode, outcome: DeletionOutcome,
         batchID: UUID? = nil, performedAt: Date = Date()) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.modeRaw = mode.rawValue
        self.outcomeRaw = outcome.rawValue
        self.batchID = batchID
        self.performedAt = performedAt
    }
}

// MARK: - Hygiene loop

/// A known offender being watched for regrowth (F21).
@Model
final class WatchedPath {
    var path: String = ""
    var name: String = ""
    var createdAt: Date = Date.distantPast

    /// A06: default threshold is the size the item had when it was last cleaned;
    /// an absolute override can be set per watch.
    var thresholdBytes: Int64 = 0
    var sizeAtLastClean: Int64 = 0
    var hasManualThreshold: Bool = false

    var lastNotifiedAt: Date?

    /// F21's failure case: the watched path disappeared entirely, so the watch
    /// retires itself with a note in the log rather than firing against nothing.
    var retiredAt: Date?
    var retiredReason: String?

    var isActive: Bool { retiredAt == nil }

    init(path: String, name: String, sizeAtLastClean: Int64) {
        self.path = path
        self.name = name
        self.sizeAtLastClean = sizeAtLastClean
        self.thresholdBytes = sizeAtLastClean
        self.createdAt = Date()
    }
}

/// F18 — "never suggest this". Still scanned and still counted toward totals;
/// simply never recommended. Reviewable and reversible in Settings.
///
/// Distinct from an exclusion (F19), which means "don't even look" and lives in
/// `Settings` because the scan needs it synchronously in its inner loop.
@Model
final class IgnoredPath {
    var path: String = ""
    var name: String = ""
    var addedAt: Date = Date.distantPast

    init(path: String, name: String) {
        self.path = path
        self.name = name
        self.addedAt = Date()
    }
}

/// F17 — "not now". Hidden from the current results, reappears on the next scan.
///
/// Scoped to the snapshot it was snoozed against rather than being kept in
/// memory: "reappears next scan" has to survive a quit, and tying it to the
/// snapshot id makes it expire by construction when a new scan lands, with no
/// sweep to run and nothing to leak.
@Model
final class SnoozedPath {
    var path: String = ""
    var snapshotID: UUID = UUID()
    var snoozedAt: Date = Date.distantPast

    init(path: String, snapshotID: UUID) {
        self.path = path
        self.snapshotID = snapshotID
        self.snoozedAt = Date()
    }
}

// MARK: - AI explanation cache (A05, F09)

/// A generated per-item explanation, cached against the item's scan fingerprint.
///
/// Explanations are generated on first view only, never for the whole tree — so
/// token spend tracks genuine curiosity rather than scan size (preflight §AI
/// mechanism). Keying on the fingerprint means an explanation survives rescans
/// for as long as the item itself hasn't changed.
@Model
final class CachedExplanation {
    /// `path|size|mtime`, matching `SnapshotItem.fingerprint`.
    @Attribute(.unique) var fingerprint: String = ""

    var whatThisIs: String = ""
    var consequenceOfDeleting: String = ""
    var rebuildCost: String?
    var confidence: Double = 0

    var generatedAt: Date = Date.distantPast
    /// Which model produced it — a cache written by an older model should be
    /// identifiable rather than indistinguishable.
    var modelIdentifier: String = ""

    init(fingerprint: String, whatThisIs: String, consequenceOfDeleting: String,
         rebuildCost: String?, confidence: Double, modelIdentifier: String) {
        self.fingerprint = fingerprint
        self.whatThisIs = whatThisIs
        self.consequenceOfDeleting = consequenceOfDeleting
        self.rebuildCost = rebuildCost
        self.confidence = confidence
        self.modelIdentifier = modelIdentifier
        self.generatedAt = Date()
    }
}
