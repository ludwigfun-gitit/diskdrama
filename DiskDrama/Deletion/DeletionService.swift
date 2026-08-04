import Foundation

/// The only code in DiskDrama that removes anything (F14–F16).
///
/// ## Everything here is deliberately paranoid
///
/// This is the app's single irreversible-ish operation, and the blast radius of
/// a bug is somebody's work. Three properties are load-bearing:
///
/// 1. **One legal call site.** Every deletion in the app goes through
///    `perform(_:mode:)`. There is no other `removeItem` or `trashItem` in the
///    codebase, so there is exactly one place to audit (§1: one legal call site
///    for a sensitive operation, not many).
/// 2. **A structural allowlist, not a blocklist.** A path is refused unless it
///    sits *inside* a configured scan root. Enumerating what to forbid means
///    being wrong about one entry; requiring membership means an unanticipated
///    path is refused by default.
/// 3. **Off main via GCD.** `FileManager.trashItem` / `removeItem` block on
///    File Provider for synced paths (§2.2), and §3.1 rules out `Task.detached`
///    — its continuation can still resume on main. GCD gives the thread
///    guarantee.
enum DeletionService {

    /// Why a deletion was refused before anything was touched.
    ///
    /// These are guards, not errors — reaching one means the app was about to
    /// do something it should not, and the right response is to stop and say
    /// so, never to proceed with a warning.
    enum Refusal: Error, LocalizedError, Equatable {
        case outsideScanRoots(String)
        case isScanRoot
        case isHomeDirectory
        case systemLocation
        case doesNotExist
        case changedSinceScan(recorded: Int64, current: Int64)

        var errorDescription: String? {
            switch self {
            case .outsideScanRoots:
                "That folder is outside the places you asked DiskDrama to look, so it won't touch it."
            case .isScanRoot:
                "That's one of your scan roots. DiskDrama deletes things it finds, never the places it looks."
            case .isHomeDirectory:
                "That's your home folder."
            case .systemLocation:
                "That's a system location. Cleaning those is a different and more dangerous product."
            case .doesNotExist:
                "That folder isn't there any more — something else removed it since the last scan."
            case .changedSinceScan(let recorded, let current):
                "This folder is \(ByteFormat.compact(current)) now, not the \(ByteFormat.compact(recorded)) "
                + "from the last scan. Rescan before deleting so you're acting on what's actually there."
            }
        }
    }

    struct Outcome: Sendable {
        let path: String
        let name: String
        /// Bytes as recorded at scan time — what the log and the reclaimed
        /// total are computed from.
        let sizeBytes: Int64
        let mode: DeletionMode
        /// Where it landed in the Trash, for F16. Nil in immediate mode.
        let trashedPath: String?
    }

    /// Size drift beyond this fails F14's precondition. 10% rather than exact:
    /// a build folder ticks over constantly and refusing on a single new object
    /// file would make the feature unusable, while a tenth of the folder
    /// appearing or vanishing means the scan's picture is genuinely stale.
    static let driftTolerance = 0.10

    /// Above this file count the subtree is not re-measured before deleting.
    ///
    /// Verifying a 1.2-million-entry folder means walking all of it, and the
    /// walk can take minutes — long enough that the user would be staring at a
    /// spinner wondering whether the app had hung. Existence and the guards
    /// still apply; only the drift comparison is skipped, and the report says
    /// so rather than implying a check that didn't happen.
    static let verificationCeiling = 200_000

    private static let queue = DispatchQueue(label: "com.bloo.diskdrama.deletion", qos: .userInitiated)

    // MARK: - Guards

    /// Everything that must be true before a path may be deleted.
    ///
    /// Synchronous, and callable from a confirmation sheet to disable its own
    /// button — the check that runs at execution time is the same one the UI
    /// used to decide what to offer.
    ///
    /// Main-actor because the allowlist comes from `Settings`. Only the *guard*
    /// is on main; every byte of file I/O below still runs on `queue`.
    @MainActor
    static func guardPath(_ path: String) -> Refusal? {
        let normalized = canonical(path)

        if normalized == canonical(NSHomeDirectory()) { return .isHomeDirectory }
        if normalized == "/" { return .isHomeDirectory }

        // Belt and braces over the allowlist. A scan root could in principle be
        // configured somewhere here; that would not make deleting from it a
        // good idea. The blueprint's "Not this app" excludes system cleanup
        // outright.
        let systemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/var", "/Applications"]
        if systemPrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) {
            return .systemLocation
        }

        let roots = Settings.shared.scanRoots.map(canonical)
        if roots.contains(normalized) { return .isScanRoot }

        // The allowlist itself: inside a root, not merely not-forbidden.
        guard roots.contains(where: { normalized.hasPrefix($0 + "/") }) else {
            return .outsideScanRoots(normalized)
        }

        return nil
    }

    /// One canonical spelling of a path, computed without consulting the disk.
    ///
    /// `standardizingPath` alone is not safe here: it collapses `/private/tmp`
    /// to `/tmp` **only when the path exists**. So an item that had just been
    /// deleted normalized differently from the scan root containing it, the
    /// prefix comparison failed, and the guard reported "outside the places you
    /// asked me to look" for a folder that was plainly inside one. Caught by
    /// testing a batch containing an already-deleted item.
    ///
    /// The refusal erred safe, but it erred *confusingly* — and a guard whose
    /// answer depends on filesystem timing is not one to leave in the only code
    /// that deletes things. The `/private` collapse is now unconditional.
    private static func canonical(_ path: String) -> String {
        var result = (path as NSString).expandingTildeInPath
        result = (result as NSString).standardizingPath
        for synonym in ["/private/tmp", "/private/var", "/private/etc"] {
            if result == synonym || result.hasPrefix(synonym + "/") {
                return String(result.dropFirst("/private".count))
            }
        }
        return result
    }

    // MARK: - Verification (F14's precondition)

    struct Verification: Sendable {
        let currentSizeBytes: Int64
        /// False when the item was too large to re-measure. The UI says so
        /// rather than presenting an unchecked item as checked.
        let didMeasure: Bool
    }

    /// Re-measures the item as it is *now*, off main.
    @MainActor
    static func verify(path: String, fileCount: Int) async throws -> Verification {
        if let refusal = guardPath(path) { throw refusal }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard FileManager.default.fileExists(atPath: path) else {
                    continuation.resume(throwing: Refusal.doesNotExist)
                    return
                }
                guard fileCount <= verificationCeiling else {
                    continuation.resume(returning: Verification(currentSizeBytes: 0, didMeasure: false))
                    return
                }
                let walked = FileTreeWalker.walk(roots: [path],
                                                 exclusions: [],
                                                 control: ScanControl()) { _ in }
                continuation.resume(returning: Verification(
                    currentSizeBytes: walked.totalSizeBytes, didMeasure: true))
            }
        }
    }

    // MARK: - Execution

    /// Deletes one item in the requested mode (A04).
    ///
    /// The guards run again here even though the sheet already ran them. The
    /// sheet's copy informs the user; this one is the enforcement, and it is
    /// deliberately not skipped on the assumption that a caller checked — the
    /// whole point of one legal call site is that the check lives at it.
    @MainActor
    static func perform(_ item: Recommendation, mode: DeletionMode) async throws -> Outcome {
        if let refusal = guardPath(item.path) { throw refusal }

        let verification = try await verify(path: item.path, fileCount: item.fileCount)
        if verification.didMeasure {
            let recorded = Double(item.sizeBytes)
            let current = Double(verification.currentSizeBytes)
            if recorded > 0, abs(current - recorded) / recorded > driftTolerance {
                throw Refusal.changedSinceScan(recorded: item.sizeBytes,
                                               current: verification.currentSizeBytes)
            }
        }

        let path = item.path
        let name = item.name
        let size = item.sizeBytes

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // URL is constructed here, on the background queue, never on
                // main — §5.2. Its property accessors can hit File Provider.
                let url = URL(fileURLWithPath: path)
                do {
                    switch mode {
                    case .trash:
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                        Log.app.notice("moved to Trash — \(ByteFormat.compact(size), privacy: .public)")
                        continuation.resume(returning: Outcome(
                            path: path, name: name, sizeBytes: size, mode: .trash,
                            trashedPath: (trashedURL as URL?)?.path))

                    case .immediate:
                        try FileManager.default.removeItem(at: url)
                        Log.app.notice("deleted permanently — \(ByteFormat.compact(size), privacy: .public)")
                        continuation.resume(returning: Outcome(
                            path: path, name: name, sizeBytes: size, mode: .immediate,
                            trashedPath: nil))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Undo (F16)

    /// Puts a trashed item back where it came from.
    ///
    /// Only ever called for Trash-mode entries — an immediate deletion has
    /// nowhere to come back from, which is why the log renders no undo action
    /// for one rather than a button that fails.
    @MainActor
    static func restore(from trashedPath: String, to originalPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let source = URL(fileURLWithPath: trashedPath)
                let destination = URL(fileURLWithPath: originalPath)
                do {
                    guard FileManager.default.fileExists(atPath: trashedPath) else {
                        // The Trash was emptied. Nothing to restore, and saying
                        // so is better than a generic failure.
                        throw Refusal.doesNotExist
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: source, to: destination)
                    Log.app.notice("restored from Trash")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
