import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menubar: MenubarController?
    private let scanEngine = ScanEngine()
    private var progressObservation: (any NSObjectProtocol)?

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
        menubar.onScanRequested = { [weak self] in self?.beginScan() }
        menubar.onScanStopRequested = { [weak self] in self?.stopScan() }
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

    /// F06 entry point from the dropdown. Until the main window exists (Step 6),
    /// progress and results surface in the dropdown and the unified log.
    private func beginScan() {
        guard !scanEngine.isRunning else { return }

        scanEngine.start { [weak self] result in
            self?.menubar?.showScanStatus(
                "Scanned \(ByteFormat.compact(result.totalSizeBytes)) — \(result.blindSpots.count) blind spots"
            )
        }
        menubar?.showScanStatus("Scanning…", canStop: true)
        observeScanState()
    }

    /// Re-arms `withObservationTracking`, which only ever fires once per
    /// registration.
    ///
    /// The re-arm happens **first, unconditionally**. Doing it at the end of the
    /// success path — as this originally did — means the first change that fails
    /// the guard silently ends observation forever. That is exactly what happened
    /// on the first real scan: one early tick arrived with no progress yet, the
    /// guard returned, tracking was never re-armed, and the dropdown sat on
    /// "Scanning…" for fifteen minutes looking like a hang. The stall was real,
    /// but this bug is what made it indistinguishable from a dead app.
    private func observeScanState() {
        withObservationTracking {
            _ = scanEngine.progress
            _ = scanEngine.stall
            _ = scanEngine.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.scanEngine.isRunning { self.observeScanState() }
                self.renderScanState()
            }
        }
    }

    /// F07's stop. A stalled walk cannot honour a cancel flag — the loop that
    /// would read it is not running — so past the abandon threshold this disowns
    /// the walk instead of asking it to stop.
    private func stopScan() {
        if scanEngine.stall?.isAbandonable == true {
            scanEngine.abandon()
            menubar?.showScanStatus("Scan abandoned — that folder wasn't responding.", canStop: false)
        } else {
            scanEngine.cancel()
            menubar?.showScanStatus("Stopping…", canStop: false)
        }
    }

    private func renderScanState() {
        guard scanEngine.isRunning else { return }

        // A stall outranks progress: when the walk is wedged, the last progress
        // figure is stale and showing it is what makes an app look frozen.
        if let stall = scanEngine.stall {
            let folder = (stall.path as NSString).lastPathComponent
            menubar?.showScanStatus(
                stall.isAbandonable
                    ? "Still reading “\(folder)” — \(Int(stall.seconds))s. It may be very large."
                    : "Reading “\(folder)”…",
                canStop: true
            )
            return
        }

        if let progress = scanEngine.progress {
            menubar?.showScanStatus(
                "Scanning… \(progress.entriesVisited) items, \(ByteFormat.compact(progress.bytesSoFar))",
                canStop: true
            )
        }
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
