import AppKit

/// Detects whether the app currently holds Full Disk Access, and opens the
/// System Settings pane where the user grants it.
///
/// ## Why this is a probe and not an API call
///
/// macOS exposes no `isFullDiskAccessGranted` query. The only way to know is to
/// attempt a read of a path TCC protects and see whether it fails — the standard
/// technique, named in the preflight so it wouldn't be "discovered" mid-build.
///
/// Two properties of FDA worth keeping in mind while reading this file:
///
/// - **It cannot be prompted for.** Unlike most TCC permissions there is no
///   consent dialog to trigger; the user grants it manually in System Settings.
///   So a failed probe is not something to retry — it is something to explain
///   (F05).
/// - **It is bound to the code signature.** Changing the bundle identifier or
///   the signing identity makes the app a different subject to TCC and drops the
///   grant. DiskDrama moved from v0's `com.unruly.diskdrama` to
///   `com.bloo.diskdrama`, so the grant has to be given once to the new bundle.
enum FullDiskAccess {

    /// Paths TCC protects that are readable by any app *with* Full Disk Access
    /// and by essentially nothing without it.
    ///
    /// Several are used rather than one because any individual path can be
    /// missing for innocent reasons — a Mac where Safari has never run has no
    /// `~/Library/Safari`, and a bare probe of it would report "denied" on a
    /// machine that has actually granted access. The distinction that matters is
    /// *readable* vs *exists-but-refused*, so the probe only trusts a path that
    /// is actually present.
    private static var probePaths: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Safari",
            home + "/Library/Application Support/com.apple.TCC",
            "/Library/Application Support/com.apple.TCC",
        ]
    }

    /// Whether the app can currently read TCC-protected locations.
    ///
    /// Cheap (a handful of `stat`/`opendir` calls on local paths) and safe to
    /// call from the main thread. It never touches an iCloud-backed path, so
    /// §5.1's XPC concern does not apply.
    static func isGranted() -> Bool {
        let fm = FileManager.default
        for path in probePaths {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue  // absent for unrelated reasons — proves nothing either way
            }
            if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }

    /// Locations TCC protects, which the scan must not enter without a grant.
    ///
    /// ## Why skipping these is mandatory, not an optimisation
    ///
    /// The obvious assumption is that touching a protected folder without
    /// permission returns `EPERM`, which a scanner handles as an ordinary
    /// unreadable directory. **It does not.** Measured on this machine,
    /// 2026-08-04, with the identical traversal code:
    ///
    /// | context | `~/Music` |
    /// |---|---|
    /// | shell process holding Full Disk Access | 769 entries, 2.24 GB, **0.04s** |
    /// | this app, no grant | **blocked in `open()` for 10+ minutes**, 0% CPU |
    ///
    /// The syscall does not fail — it hangs. A background app with no windows
    /// cannot resolve whatever consent round-trip it is waiting on, so the walk
    /// simply stops forever on the first protected folder it meets. Since
    /// `~/Desktop`, `~/Documents` and `~/Downloads` are all protected and all sit
    /// directly in the default scan root, an ungranted scan would reliably hang
    /// within seconds of starting.
    ///
    /// So without a grant these are skipped up front and recorded as blind spots.
    /// That is not a workaround bolted on — it is precisely F05's specified
    /// reduced mode: "scan works but marks unreadable locations as blind spots and
    /// says what it's missing." The hang is what forced the honest behaviour to be
    /// built first rather than last.
    ///
    /// The list is Apple's documented set and does not churn often, but it is not
    /// load-bearing on its own: `ScanEngine`'s stall watchdog remains the backstop
    /// for anything protected that is not named here.
    static var protectedPaths: [String] {
        let home = NSHomeDirectory()
        return [
            // "Files and Folders" — the dangerous ones, directly inside the
            // default scan root.
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
            home + "/Music",
            home + "/Pictures",
            home + "/Movies",
            home + "/.Trash",

            // Full-Disk-Access-only locations inside ~/Library.
            home + "/Library/Mail",
            home + "/Library/Safari",
            home + "/Library/Messages",
            home + "/Library/Cookies",
            home + "/Library/Calendars",
            home + "/Library/Suggestions",
            home + "/Library/HomeKit",
            home + "/Library/IdentityServices",
            home + "/Library/Sharing",
            home + "/Library/Trial",
            home + "/Library/PersonalizationPortrait",
            home + "/Library/Metadata/CoreSpotlight",
            home + "/Library/Application Support/AddressBook",
            home + "/Library/Application Support/com.apple.TCC",
            home + "/Library/Containers/com.apple.mail",
        ]
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    ///
    /// The app cannot add itself to that list; the user does. F05's onboarding
    /// pairs this with live polling of `isGranted()` so the walkthrough advances
    /// by itself the moment the toggle is flipped.
    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
