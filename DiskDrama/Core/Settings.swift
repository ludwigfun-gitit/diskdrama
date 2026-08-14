import Foundation
import Observation

/// User configuration.
///
/// ## Why this is `UserDefaults` and not SwiftData
///
/// The split across DiskDrama's persistence is *configuration* vs *history*.
/// Records — snapshots, the cleanup log, watches, the ignore list — are
/// SwiftData. Settings are not, for two concrete reasons:
///
/// 1. **They are read before the store exists.** The menubar thresholds are
///    needed at launch, and the app must degrade to monitor-only if the store
///    fails to open. Settings that live inside the store would take the monitor
///    down with it.
/// 2. **Exclusions are read inside the scan's inner loop.** The traversal checks
///    every directory it descends into against the exclusion set, millions of
///    times per scan, on a background thread. Reaching into a `ModelContext`
///    from there is precisely the wrong shape; a plain `Set<String>` snapshotted
///    into the scan is right.
///
/// Note the deliberate asymmetry with F18/F19, which sound similar but are not:
/// the **ignore list** (F18, "stop suggesting this") is SwiftData because it is
/// user history consulted once per scan, while **exclusions** (F19, "don't even
/// look") live here because they are configuration consulted constantly.
@MainActor
@Observable
final class Settings {

    static let shared = Settings()

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Monitor thresholds (F01)

    /// Below this, the menubar goes amber. Default 5 GB, matching v0.
    var lowThresholdBytes: Int64 {
        get { read(.lowThreshold) ?? 5_000_000_000 }
        set { write(.lowThreshold, newValue) }
    }

    /// Below this, red. Default 1 GB, matching v0.
    var criticalThresholdBytes: Int64 {
        get { read(.criticalThreshold) ?? 1_000_000_000 }
        set { write(.criticalThreshold, newValue) }
    }

    /// Seconds between volume polls. Default 10 minutes, matching v0.
    var pollIntervalSeconds: Double {
        get { read(.pollInterval) ?? 600 }
        set { write(.pollInterval, newValue) }
    }

    // MARK: - Scan scope (A03, F19)

    /// Roots the scan walks. Default: the home directory (A03's resolution).
    ///
    /// Full-volume and system domains stay out — the blueprint's "Not this app"
    /// excludes system-level cleanup requiring elevated privileges, and a tool
    /// that offers to delete from `/System` is a different, more dangerous
    /// product.
    var scanRoots: [String] {
        get { defaults.stringArray(forKey: Key.scanRoots.rawValue) ?? [NSHomeDirectory()] }
        set { defaults.set(newValue, forKey: Key.scanRoots.rawValue) }
    }

    /// Folders never scanned, never counted, never recommended (F19).
    var exclusions: [String] {
        get { defaults.stringArray(forKey: Key.exclusions.rawValue) ?? Self.defaultExclusions }
        set { defaults.set(newValue, forKey: Key.exclusions.rawValue) }
    }

    /// Snapshot of the exclusion set for the scan's inner loop. Taken once at
    /// scan start; the scan does not observe changes made while it runs.
    var exclusionSet: Set<String> { Set(exclusions) }

    /// Paths the operating system refused to let DiskDrama delete.
    ///
    /// Learned rather than declared. ~/Library/Caches/CloudKit needed a hand-
    /// written rule because nothing knew macOS owned it; this is so the next such
    /// folder does not. A permission refusal is a durable fact about a path — the
    /// system will refuse again — so remembering it is the difference between
    /// discovering the wall once and walking into it after every scan.
    var undeletablePaths: [String] {
        get { defaults.stringArray(forKey: Key.undeletablePaths.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: Key.undeletablePaths.rawValue) }
    }

    /// Blind spots the user never wants listed again.
    ///
    /// Distinct from `exclusions`, which is about what the *scan* does. This is
    /// only about what the pane *shows*. Excluding a sealed folder changes
    /// nothing measurable — it was already unreadable — so "stop looking here"
    /// could only move its row between two headings on the same screen, never
    /// off it. Someone who has read "there is nothing to fix here" once should
    /// be able to stop being told, without the app pretending the gap closed.
    var hiddenBlindSpots: [String] {
        get { defaults.stringArray(forKey: Key.hiddenBlindSpots.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: Key.hiddenBlindSpots.rawValue) }
    }

    /// The two File Provider roots on a modern Mac.
    ///
    /// The preflight locked `~/Library/Mobile Documents` (iCloud Drive) out of the
    /// defaults because that is where the XPC hang risk of `architectural-rules.md`
    /// §5.1 concentrates, and the reclaimable-space case for synced files is weak.
    /// `~/Library/CloudStorage` is the same problem wearing a different name:
    /// since macOS 12.3 every third-party provider — Google Drive, OneDrive,
    /// Dropbox — mounts there through File Provider too.
    ///
    /// Naming the two provider roots rather than a list of vendor folder names
    /// keeps this vendor-agnostic. The familiar `~/Google Drive` and
    /// `~/OneDrive` entries in a home directory are symlinks into
    /// `~/Library/CloudStorage`, and the scan does not follow symlinks, so they
    /// are covered without being enumerated.
    ///
    /// Both are opt-in-able from Settings — this sets the default, which is what
    /// A03 left open, rather than reopening A03 itself.
    static var defaultExclusions: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Mobile Documents",
            home + "/Library/CloudStorage",
        ]
    }

    /// Whether a path is one of DiskDrama's own default skips rather than
    /// something the user chose.
    ///
    /// The distinction matters wherever the UI attributes the decision. Telling
    /// someone "you told DiskDrama not to look here" about a folder DiskDrama
    /// skipped on its own initiative is simply untrue, and it hides the reason —
    /// which is not preference but the File Provider hang described above.
    static func isDefaultExclusion(_ path: String) -> Bool {
        defaultExclusions.contains(path)
    }

    /// Nodes smaller than this are not persisted into a snapshot (they still
    /// count toward every total). 50 MB — below it, an item is not a disk-space
    /// problem and the delta has nothing useful to say about it.
    var pruneFloorBytes: Int64 {
        get { read(.pruneFloor) ?? 50_000_000 }
        set { write(.pruneFloor, newValue) }
    }

    // MARK: - Deletion (A04)

    /// Global default deletion mode, pre-setting the checkbox on every
    /// confirmation dialog. **Trash**, deliberately — the safe default, and the
    /// only one that leaves F16's undo available.
    var defaultDeletionMode: DeletionMode {
        get {
            defaults.string(forKey: Key.deletionMode.rawValue)
                .flatMap(DeletionMode.init(rawValue:)) ?? .trash
        }
        set { defaults.set(newValue.rawValue, forKey: Key.deletionMode.rawValue) }
    }

    // MARK: - Alerts (F25)

    /// Minimum gap between low-space notifications, so crossing a threshold
    /// repeatedly does not turn into nagging. Default 6 hours. Re-alerting on a
    /// *further* threshold crossing bypasses this.
    var alertQuietPeriodSeconds: Double {
        get { read(.alertQuietPeriod) ?? 6 * 3600 }
        set { write(.alertQuietPeriod, newValue) }
    }

    var lastAlertAt: Date? {
        get { defaults.object(forKey: Key.lastAlertAt.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastAlertAt.rawValue) }
    }

    // MARK: - Target planner (F23)

    /// Free-space goal for "Get me to…". Nil until the user sets one.
    var freeSpaceTargetBytes: Int64? {
        get { read(.freeSpaceTarget) }
        set {
            if let newValue { write(.freeSpaceTarget, newValue) }
            else { defaults.removeObject(forKey: Key.freeSpaceTarget.rawValue) }
        }
    }

    // MARK: - Presentation

    /// Stay a menubar-only app: no Dock icon, even while the window is open.
    ///
    /// Default off, which keeps the behaviour the app has had — `.accessory`
    /// while only the status item is showing, `.regular` once the window opens.
    ///
    /// The trade is real and worth knowing before flipping it: an `.accessory`
    /// application does not own the system menu bar, so with this on, DiskDrama's
    /// own menu bar never appears and whatever app was last active keeps it while
    /// DiskDrama's window is focused.
    var menuBarOnly: Bool {
        get { defaults.bool(forKey: Key.menuBarOnly.rawValue) }
        set { defaults.set(newValue, forKey: Key.menuBarOnly.rawValue) }
    }

    // MARK: - Onboarding (F05)

    /// How far onboarding got, so it can be resumed rather than restarted.
    ///
    /// Step 2 is the Full Disk Access step, and the correct answer to a stubborn
    /// grant is to relaunch — which without this would throw the user back to
    /// step 1 and lose the thing they restarted to finish. A resume that forgets
    /// where it was is worse than no resume: it makes restarting feel like a
    /// punishment for following the instructions.
    var onboardingStep: Int {
        get { defaults.integer(forKey: Key.onboardingStep.rawValue) }
        set { defaults.set(newValue, forKey: Key.onboardingStep.rawValue) }
    }

    /// What the user said mostly fills this Mac.
    ///
    /// A guiding question with teeth: it picks the tier the app opens on and the
    /// emphasis of the first-scan reveal. No placebo questions — an answer that
    /// changes nothing devalues the ones that do, and users notice.
    var primaryUse: String {
        get { defaults.string(forKey: Key.primaryUse.rawValue) ?? "everything" }
        set { defaults.set(newValue, forKey: Key.primaryUse.rawValue) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding.rawValue) }
    }

    /// The reduced-mode banner is dismissable but must come back — F05 specifies
    /// a *persistent, dismissable* banner offering to re-run the walkthrough.
    var fullDiskAccessBannerDismissedAt: Date? {
        get { defaults.object(forKey: Key.fdaBannerDismissed.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.fdaBannerDismissed.rawValue) }
    }

    // MARK: - Storage plumbing

    private enum Key: String {
        case lowThreshold        = "monitor.lowThresholdBytes"
        case criticalThreshold   = "monitor.criticalThresholdBytes"
        case pollInterval        = "monitor.pollIntervalSeconds"
        case scanRoots           = "scan.roots"
        case exclusions          = "scan.exclusions"
        case pruneFloor          = "scan.pruneFloorBytes"
        case deletionMode        = "deletion.defaultMode"
        case menuBarOnly         = "ui.menuBarOnly"
        case alertQuietPeriod    = "alerts.quietPeriodSeconds"
        case lastAlertAt         = "alerts.lastAt"
        case freeSpaceTarget     = "planner.freeSpaceTargetBytes"
        case completedOnboarding = "onboarding.completed"
        case onboardingStep      = "onboarding.step"
        case primaryUse          = "onboarding.primaryUse"
        case fdaBannerDismissed  = "onboarding.fdaBannerDismissedAt"
        case hiddenBlindSpots    = "scan.hiddenBlindSpots"
        case undeletablePaths    = "deletion.refusedByOS"
    }

    /// `object(forKey:)` rather than `integer(forKey:)` so an unset key is
    /// distinguishable from a deliberate zero — the difference between "no
    /// threshold configured, use the default" and "the user set it to zero".
    private func read(_ key: Key) -> Int64? {
        defaults.object(forKey: key.rawValue) as? Int64
            ?? (defaults.object(forKey: key.rawValue) as? NSNumber)?.int64Value
    }

    private func read(_ key: Key) -> Double? {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.doubleValue
    }

    private func write(_ key: Key, _ value: Int64) {
        defaults.set(NSNumber(value: value), forKey: key.rawValue)
    }

    private func write(_ key: Key, _ value: Double) {
        defaults.set(NSNumber(value: value), forKey: key.rawValue)
    }
}
