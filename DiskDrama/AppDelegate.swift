import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menubar: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no menu bar of its own. Step 6 flips this to
        // `.regular` while the main window is open and back on close, which is
        // the standard shape for a menubar app that also owns a real window.
        NSApp.setActivationPolicy(.accessory)

        // The monitor starts first and deliberately does not depend on the store.
        // If persistence is broken the app degrades to monitor-only rather than
        // refusing to launch — same honesty the scanner applies to blind spots.
        let menubar = MenubarController()
        menubar.start()
        self.menubar = menubar

        _ = DataStore.shared
        logLaunchDiagnostics()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // F04: quitting cancels any in-flight scan and discards partial results.
        // Nothing to cancel yet — the scan engine arrives in Step 3, and this is
        // where its cancellation hangs.
        menubar?.stop()
        menubar = nil
    }

    /// One line at launch, so a session that starts with "is it even reading the
    /// right volume" has an answer without attaching a debugger. Includes the
    /// purgeable split behind DD.B001, the Full Disk Access state the scan engine
    /// depends on, and whether the bundled faces actually registered.
    ///
    /// Read it with:
    /// `log show --predicate 'subsystem == "com.bloo.diskdrama"' --last 5m --style compact`
    private func logLaunchDiagnostics() {
        let fontsOK = NSFontManager.shared.availableFontFamilies
        let hasGrotesk = fontsOK.contains("Space Grotesk")
        let hasEpilogue = fontsOK.contains("Epilogue")

        guard let info = DiskInfo.read() else {
            Log.app.error("launch — volume unreadable at \(DiskInfo.bootVolumePath, privacy: .public)")
            return
        }

        Log.app.notice("""
        launch — total=\(ByteFormat.precise(info.totalBytes), privacy: .public) \
        available=\(ByteFormat.precise(info.availableBytes), privacy: .public) \
        strict=\(ByteFormat.precise(info.strictAvailableBytes), privacy: .public) \
        purgeable=\(ByteFormat.precise(info.purgeableBytes), privacy: .public) \
        fullDiskAccess=\(FullDiskAccess.isGranted(), privacy: .public) \
        fonts(SpaceGrotesk=\(hasGrotesk, privacy: .public), Epilogue=\(hasEpilogue, privacy: .public)) \
        store=\(DataStore.shared.state.container != nil ? "ready" : "FAILED", privacy: .public) \
        roots=\(Settings.shared.scanRoots.count, privacy: .public) \
        exclusions=\(Settings.shared.exclusions.count, privacy: .public)
        """)

        // A font that silently fails to register renders as the system face and
        // is easy to miss for several steps. Say so at launch rather than letting
        // it be discovered as "the headings look slightly off".
        if !hasGrotesk || !hasEpilogue {
            Log.app.error("bundled font failed to register — check ATSApplicationFontsPath and Contents/Resources")
        }
    }
}
