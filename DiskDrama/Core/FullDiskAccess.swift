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
