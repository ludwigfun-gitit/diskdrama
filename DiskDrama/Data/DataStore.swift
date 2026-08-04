import Foundation
import SwiftData

/// Owns the SwiftData stack.
///
/// ## Failure is a first-class outcome here
///
/// `ModelContainer` construction throws, and a store that cannot open is not a
/// detail to swallow — every persisted feature (history, watches, delta) depends
/// on it. Following Visuals' two-phase launch lesson (§10.5: `DatabaseManager.init`
/// throws and callers must handle it), this exposes the failure rather than
/// force-trying and crashing on launch.
///
/// The monitor (F01–F04) deliberately does not depend on this at all. If the
/// store cannot open, the menubar still works and the app degrades to
/// monitor-only rather than refusing to start — the same honesty the scanner
/// applies to blind spots.
@MainActor
final class DataStore {

    enum StoreState {
        case ready(ModelContainer)
        case failed(Error)

        var container: ModelContainer? {
            if case .ready(let container) = self { return container }
            return nil
        }
    }

    static let shared = DataStore()

    private(set) var state: StoreState

    /// Everything persisted. Order is irrelevant; completeness is not — a model
    /// missing here fails at runtime on first use, not at compile time.
    private static let schema = Schema([
        Snapshot.self,
        SnapshotItem.self,
        BlindSpot.self,
        CleanupEntry.self,
        WatchedPath.self,
        IgnoredPath.self,
        SnoozedPath.self,
        CachedExplanation.self,
    ])

    private init() {
        do {
            state = .ready(try Self.makeContainer())
            Log.app.notice("store opened at \(Self.storeDirectory.path, privacy: .private)")
        } catch {
            state = .failed(error)
            Log.app.error("store failed to open: \(error.localizedDescription, privacy: .public)")
        }
    }

    var context: ModelContext? {
        state.container.map { ModelContext($0) }
    }

    // MARK: - Location

    /// `~/Library/Application Support/DiskDrama/`.
    ///
    /// Not the sandbox container (there isn't one) and not `~/Documents` — this
    /// is machine-local state that should not sync, follow the user to another
    /// Mac, or appear in a backup as user documents.
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("DiskDrama", isDirectory: true)
    }

    private static func makeContainer() throws -> ModelContainer {
        // Create the directory explicitly. It normally exists on macOS, but the
        // URL being valid is not the same as the directory existing (§9.2 caught
        // exactly this on iOS), and the cost of being certain is one call.
        try FileManager.default.createDirectory(at: storeDirectory,
                                                withIntermediateDirectories: true)

        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appendingPathComponent("DiskDrama.store"),
            // Local only. Nothing in this store should ever leave the machine —
            // it is a map of the user's disk, including paths that carry
            // project and client names.
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// Background persistence.
///
/// Scan results are written off the main thread — a snapshot write is thousands
/// of inserts and belongs nowhere near the UI. `@ModelActor` gives a context
/// isolated to its own actor, which is the supported way to touch SwiftData off
/// main; `ModelContext` is not `Sendable` and cannot simply be handed to a task.
@ModelActor
actor BackgroundStore {

    /// Writes a completed scan and prunes history to `keepingLast` snapshots.
    ///
    /// Old snapshots are dropped because the delta always compares against the
    /// immediately previous scan (A07) — pinned baselines are explicitly Future
    /// scope — so unbounded history buys nothing and costs disk on a machine
    /// already short of it. Keeping a few rather than one leaves room to look
    /// back without the store growing without limit.
    func save(_ snapshot: Snapshot, keepingLast keep: Int = 5) throws {
        modelContext.insert(snapshot)
        try modelContext.save()

        var descriptor = FetchDescriptor<Snapshot>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        let all = try modelContext.fetch(descriptor)
        guard all.count > keep else { return }

        for stale in all.dropFirst(keep) {
            modelContext.delete(stale)   // cascades to items and blind spots
        }
        try modelContext.save()
    }

    /// The most recent completed snapshot, or nil if none has ever run.
    func latestSnapshot() throws -> Snapshot? {
        var descriptor = FetchDescriptor<Snapshot>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Persists a scan and returns the delta against the scan before it (F20).
    ///
    /// Both halves happen on this actor because they are one logical operation and
    /// both touch `modelContext`, which is isolated here. The delta is reduced to
    /// a `Sendable` value before it crosses back — `SnapshotItem` is a model
    /// object and must not escape its context.
    func persistAndComputeDelta(
        result: ScanResult,
        recommendations: RecommendationSet,
        volume: DiskInfo?,
        pruneFloorBytes: Int64
    ) throws -> Delta? {

        let previous = try latestSnapshot()

        let snapshot = SnapshotWriter.makeSnapshot(
            from: result,
            recommendations: recommendations,
            volume: volume,
            pruneFloorBytes: pruneFloorBytes)

        // Delta is computed before the save so `previous` is unambiguously the
        // scan before this one, whatever the history-pruning rule does next.
        let delta = previous.flatMap { DeltaComputer.compare(previous: $0, current: snapshot) }

        try save(snapshot)
        return delta
    }
}
