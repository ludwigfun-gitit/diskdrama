import Foundation
import Observation

/// Owns scan lifecycle and the state the UI observes (F06, F07).
///
/// `@MainActor @Observable` so views can read `phase` and `progress` directly.
/// The actual traversal never runs here — it is dispatched to a background queue
/// via **GCD**, deliberately not `Task.detached`.
///
/// §3.1 is the reason and it is worth restating: Swift Concurrency's cooperative
/// pool can schedule a task's continuation on the main thread under load *even
/// for a detached task*. The body starts off main; what happens after an `await`
/// is the runtime's choice. For a multi-minute filesystem walk that is not a
/// theoretical concern. GCD gives thread guarantees; Swift Concurrency gives
/// scheduling hints — so the walk gets GCD, and the boundary back to the main
/// actor is crossed exactly once, explicitly, when it finishes.
@MainActor
@Observable
final class ScanEngine {

    enum Phase: Equatable {
        case idle
        case scanning
        case paused
        case finishing        // walk done, classifying and persisting
        case failed(String)
    }

    /// A directory the walk has been sitting on long enough to be worth saying so.
    struct Stall: Equatable {
        let path: String
        let seconds: TimeInterval
        /// Past this, the user is offered a way out rather than just an
        /// explanation — §2.3's "abandon and continue option after 10s".
        var isAbandonable: Bool { seconds >= ScanEngine.abandonOfferAfter }
    }

    /// Say something is slow before the user starts wondering if it crashed.
    nonisolated static let stallVisibleAfter: TimeInterval = 2
    /// Offer a way out.
    nonisolated static let abandonOfferAfter: TimeInterval = 10

    private(set) var phase: Phase = .idle
    private(set) var progress: FileTreeWalker.Progress?
    private(set) var lastResult: ScanResult?

    /// Tiered recommendations from the last completed scan (F08). Built on the
    /// scan queue, not here — it is a full tree walk and does not belong on main.
    private(set) var recommendations: RecommendationSet?

    /// Non-nil while the traversal has been stuck on one directory. Set by the
    /// watchdog on the main actor, not by the walk — the whole point is that it
    /// works when the walk is too blocked to report anything.
    private(set) var stall: Stall?

    private var control: ScanControl?
    private var watchdog: Timer?

    /// Bumped on every start and on abandon. A walk whose generation no longer
    /// matches has been orphaned and its result is dropped on arrival.
    ///
    /// This is how cancel works when the walk is blocked in an uninterruptible
    /// `open()`: the flag cannot be polled, because the loop that would poll it is
    /// not running. So the engine stops waiting instead. The orphaned thread
    /// finishes whenever the filesystem lets it go, finds its generation stale,
    /// and exits without touching anything.
    private var generation = 0

    private let queue = DispatchQueue(label: "com.bloo.diskdrama.scan", qos: .utility)

    var isRunning: Bool {
        phase == .scanning || phase == .paused || phase == .finishing
    }

    // MARK: - Control

    /// Starts a scan. No-op if one is already running — F06 makes "no scan
    /// already in progress" a precondition, and two concurrent walks would race
    /// to write snapshots.
    func start(completion: (@MainActor (ScanResult) -> Void)? = nil) {
        guard !isRunning else { return }

        let roots = Settings.shared.scanRoots
        let exclusions = Settings.shared.exclusionSet
        let control = ScanControl()
        self.control = control

        generation += 1
        let thisGeneration = generation

        phase = .scanning
        progress = nil
        stall = nil
        startWatchdog()

        Log.scan.notice("""
        scan starting — roots=\(roots.count, privacy: .public) \
        exclusions=\(exclusions.count, privacy: .public) \
        fullDiskAccess=\(FullDiskAccess.isGranted(), privacy: .public)
        """)

        queue.async {
            let result = FileTreeWalker.walk(
                roots: roots,
                exclusions: exclusions,
                control: control
            ) { progress in
                // Throttled to 10/sec inside the walker. Hopping to main per
                // filesystem entry is what §10.2 is a scar from.
                Task { @MainActor [weak self] in
                    guard let self, self.generation == thisGeneration, self.isRunning else { return }
                    self.progress = progress
                    self.stall = nil
                }
            }

            Task { @MainActor [weak self] in
                self?.finish(result, generation: thisGeneration, completion: completion)
            }
        }
    }

    // MARK: - Stall watchdog

    /// Polls the walk's published activity from the main actor.
    ///
    /// Deliberately independent of the walk. A progress callback fires from inside
    /// the loop, so it goes silent exactly when there is something worth saying;
    /// this timer keeps running regardless of what the filesystem is doing to that
    /// thread. Half a second is far below human perception of "stuck" and costs
    /// one uncontended lock acquisition.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForStall() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkForStall() {
        guard phase == .scanning, let control else { stall = nil; return }

        let activity = control.currentActivity
        guard !activity.path.isEmpty else { return }

        let elapsed = Date().timeIntervalSince(activity.since)
        guard elapsed >= Self.stallVisibleAfter else {
            if stall != nil { stall = nil }
            return
        }

        let newStall = Stall(path: activity.path, seconds: elapsed)
        if stall?.path != newStall.path {
            Log.scan.notice("""
            slow directory — stalled \(Int(elapsed), privacy: .public)s on a single folder
            """)
        }
        stall = newStall
    }

    /// Gives up on a walk that is wedged in an uninterruptible filesystem call.
    ///
    /// The thread is not killed — it cannot be, and killing a thread mid-`open()`
    /// would leak whatever `fts` holds. It is *disowned*: the generation moves on,
    /// the engine returns to idle, and the orphan's eventual result is discarded.
    /// It costs one background thread sitting in the kernel until the filesystem
    /// releases it, which is the correct trade against a permanently frozen app.
    func abandon() {
        guard isRunning else { return }
        let stalledPath = stall?.path ?? "unknown"
        Log.scan.error("""
        abandoning scan — wedged in an uninterruptible filesystem call; \
        orphaned thread will exit on its own. path=\(stalledPath, privacy: .private)
        """)
        control?.cancel()      // in case it is merely slow rather than truly stuck
        control = nil
        generation += 1        // everything in flight is now stale
        watchdog?.invalidate()
        watchdog = nil
        stall = nil
        progress = nil
        phase = .idle
    }

    /// F07: halts traversal, resumable within the session.
    func pause() {
        guard phase == .scanning else { return }
        control?.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        control?.resume()
        phase = .scanning
    }

    /// F07: discards partial results. The previous snapshot stays authoritative.
    ///
    /// Also the path a paused-overnight scan takes — the blueprint treats an
    /// abandoned pause as a cancel, and there is no partial state worth reviving
    /// a day later against a disk that has since moved on.
    func cancel() {
        guard isRunning else { return }
        control?.cancel()
        Log.scan.notice("scan cancelled by user")
    }

    // MARK: - Completion

    private func finish(_ result: ScanResult,
                        generation resultGeneration: Int,
                        completion: (@MainActor (ScanResult) -> Void)?) {
        // An abandoned walk eventually returns. Its generation is stale, so it is
        // dropped here rather than overwriting whatever the app has since done.
        guard resultGeneration == generation else {
            Log.scan.notice("orphaned scan returned after abandon — result discarded")
            return
        }

        control = nil
        progress = nil
        stall = nil
        watchdog?.invalidate()
        watchdog = nil

        guard !result.wasCancelled else {
            phase = .idle
            lastResult = nil
            Log.scan.notice("scan discarded — cancelled after \(result.visitedEntryCount, privacy: .public) entries")
            return
        }

        lastResult = result
        phase = .finishing

        let duration = result.completedAt.timeIntervalSince(result.startedAt)
        Log.scan.notice("""
        scan complete — entries=\(result.visitedEntryCount, privacy: .public) \
        total=\(ByteFormat.precise(result.totalSizeBytes), privacy: .public) \
        blindSpots=\(result.blindSpots.count, privacy: .public) \
        slowDirs=\(result.slowDirectories.count, privacy: .public) \
        seconds=\(String(format: "%.1f", duration), privacy: .public)
        """)

        for slow in result.slowDirectories.prefix(5) {
            Log.scan.notice("""
            slow directory — \(String(format: "%.1f", slow.seconds), privacy: .public)s \
            at \(slow.path, privacy: .private)
            """)
        }

        let set = RecommendationBuilder.build(from: result)
        recommendations = set
        Log.scan.notice("""
        classified — reclaimable=\(ByteFormat.precise(set.totalReclaimableBytes), privacy: .public) \
        safe=\(set.inTier(.safe).count, privacy: .public)/\(ByteFormat.compact(set.reclaimableBytes(in: .safe)), privacy: .public) \
        appManaged=\(set.inTier(.appManaged).count, privacy: .public) \
        review=\(set.inTier(.reviewFirst).count, privacy: .public)/\(ByteFormat.compact(set.reclaimableBytes(in: .reviewFirst)), privacy: .public)
        """)
        for rec in set.recommendations.prefix(12) {
            Log.scan.notice("""
            → T\(rec.tier.rawValue, privacy: .public) \
            \(ByteFormat.compact(rec.sizeBytes), privacy: .public) \
            \(rec.classification.title, privacy: .public) \
            [\(rec.classification.key, privacy: .public)] \
            at \(rec.path, privacy: .private)
            """)
        }

        completion?(result)
        phase = .idle
    }
}
