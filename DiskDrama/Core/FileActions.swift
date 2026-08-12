import AppKit

/// The two actions that hand off to something outside DiskDrama (F11, F12).
///
/// Both construct a `URL` from a path, which §5.1 marks as a main-thread hazard
/// on File-Provider-backed locations — `URL`'s own property accessors can make a
/// synchronous XPC call to `fileproviderd`. Both therefore build and use the URL
/// on GCD (§3.1: a detached `Task`'s continuation can still resume on main).
///
/// Neither reports success. Finder coming forward *is* the confirmation, and a
/// dialog on top of a working reveal is noise; the failure paths that matter
/// (the app is gone) are handled before the user ever gets a button.
enum FileActions {

    private static let queue = DispatchQueue(label: "com.bloo.diskdrama.fileactions", qos: .userInitiated)

    /// F11 — the escape hatch for manual judgement. Selects the item in Finder
    /// rather than opening it, so the user lands on the thing itself.
    /// Falls back to the nearest ancestor that can be opened.
    ///
    /// The guard used to return silently whenever `fileExists` said no, which
    /// covers two very different cases: the item is gone, and the item is there
    /// but macOS refuses to stat it. The second is common — every TCC-protected
    /// app container answers that way — and it turned Reveal in Finder into a
    /// button that did nothing at all, with the explanation going only to the
    /// log. Landing the user in the enclosing folder answers the question they
    /// actually asked ("what *is* this?") in every case, and `/` exists, so the
    /// walk up cannot fall off the end.
    static func revealInFinder(path: String) {
        queue.async {
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
            var candidate = (path as NSString).deletingLastPathComponent
            while candidate.count > 1 {
                if FileManager.default.fileExists(atPath: candidate) {
                    Log.app.info("reveal fell back to the enclosing folder")
                    NSWorkspace.shared.open(URL(fileURLWithPath: candidate))
                    return
                }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            Log.app.error("reveal failed — neither the path nor any ancestor could be opened")
        }
    }

    /// F12 — launch or activate the app that owns a Tier 2 item.
    ///
    /// DiskDrama never reaches into another app's managed storage; this is the
    /// whole of its involvement with Tier 2.
    static func openApp(bundleID: String) {
        queue.async {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.app.error("owning app not installed: \(bundleID, privacy: .public)")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}

/// Whether the apps named by Tier 2 rules are actually installed.
///
/// F12's failure case turns on this: an item whose owning app has been removed
/// must be re-tiered to Review first with a plain explanation ("Podcasts data but
/// Podcasts is gone — likely safe, review first"), not left showing an "Open
/// Podcasts" button that does nothing.
///
/// The check belongs at classification time rather than in the panel, because
/// the answer changes which tier the item is *in* — and therefore the sidebar
/// counts, the batch-approval eligibility, and whether it appears in a plan.
/// Deciding it in the view would leave every other surface disagreeing.
enum OwningAppLocator {

    /// Resolutions are cached for the process. LaunchServices lookups are cheap
    /// but not free, and classification asks the same handful of bundle IDs once
    /// per matching node across a whole tree.
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func isInstalled(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[bundleID] { return known }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        cache[bundleID] = installed
        return installed
    }
}
