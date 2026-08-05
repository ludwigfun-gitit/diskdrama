import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menubar: MenubarController?
    private var mainWindow: MainWindowController?
    private let scanEngine = ScanEngine()
    private let disk = DiskMonitor()
    private lazy var model = AppModel(scanEngine: scanEngine, disk: disk)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory at rest: no Dock icon, no app menu, nothing in ⌘-Tab.
        // `MainWindowController` flips this to `.regular` while the window is
        // open and back again on close.
        NSApp.setActivationPolicy(.accessory)

        // Built now, drawn later. An accessory app shows no menu bar, but the
        // window can open at any moment and flip the policy to `.regular` — and
        // key equivalents are matched against this menu whether it is on screen
        // or not.
        AppMenu.install(target: self,
                        settings: #selector(showSettingsFromMenu),
                        scan: #selector(scanFromMenu))

        // The monitor starts first and deliberately does not depend on the store.
        // If persistence is broken the app degrades to monitor-only rather than
        // refusing to launch — same honesty the scanner applies to blind spots.
        disk.start()

        let menubar = MenubarController(monitor: disk)
        menubar.start()
        menubar.onScanRequested = { [weak self] in self?.beginScan() }
        menubar.onScanStopRequested = { [weak self] in self?.stopScan() }
        menubar.onOpenWindowRequested = { [weak self] in self?.openMainWindow() }

        // F25: the monitor already polls; the alert rides that rather than
        // adding a second timer.
        disk.onThresholdCrossed = { [weak self] info, isCritical in
            self?.handleLowSpace(info, isCritical: isCritical)
        }
        // The one model → menubar edge. `refreshDisplay()` re-renders from the
        // reading already in hand, so a threshold edit retints immediately
        // without forcing a fresh volume read.
        model.onThresholdsChanged = { [weak self] in self?.menubar?.refreshDisplay() }
        // TCC changes while the user is away in System Settings, and sends no
        // notification when it does. Coming back to the app is the moment to
        // re-ask, and it costs a few stat calls.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshAccessState() }
        }

        menubar.onSettingsRequested = { [weak self] in
            self?.openMainWindow()
            self?.model.isShowingSettings = true
        }
        self.menubar = menubar

        mainWindow = MainWindowController(
            model: model,
            onScan: { [weak self] in self?.beginScan() },
            onStopScan: { [weak self] in self?.stopScan() })

        // The dropdown is the surface people see most, so it carries the last
        // scan's headline from launch rather than only after a fresh scan.
        // Costs one store read, measured at ~0.1s in Step 6.
        model.loadPersistedState()
        refreshMenubarSummary()

        logLaunchDiagnostics()
    }

    /// F25 — the monitor/advisor fusion point.
    ///
    /// The alert is only worth interrupting for because it carries the answer
    /// with it: not "you're low on space" (which the user can see) but "here is
    /// what you could get back and where the biggest of it is". With no scan
    /// data it offers a first scan instead of quoting stale numbers.
    private func handleLowSpace(_ info: DiskInfo, isCritical: Bool) {
        let settings = Settings.shared

        // Quiet period, bypassed by a *further* crossing — going from low to
        // critical is new information and should not be swallowed by a timer
        // that started when the first alert fired.
        if !isCritical, let last = settings.lastAlertAt,
           Date().timeIntervalSince(last) < settings.alertQuietPeriodSeconds {
            Log.app.notice("low-space alert suppressed — inside the quiet period")
            return
        }
        settings.lastAlertAt = Date()

        let free = ByteFormat.compact(info.availableBytes)
        let body: String

        if let set = model.recommendations, set.totalReclaimableBytes > 0 {
            let biggest = set.recommendations
                .filter { $0.tier != .appManaged }
                .max(by: { $0.sizeBytes < $1.sizeBytes })
            var text = "Last scan found \(ByteFormat.compact(set.totalReclaimableBytes)) you can get back"
            if let biggest {
                text += " — biggest is \(biggest.classification.title), \(ByteFormat.compact(biggest.sizeBytes))."
            } else {
                text += "."
            }
            body = text
        } else {
            body = "I haven't scanned yet, so I can't tell you what's reclaimable. Open DiskDrama and run a scan."
        }

        Notifier.post(title: "\(free) free.", body: body, category: .lowSpace,
                      id: "low-space-\(isCritical ? "critical" : "low")")
        Log.app.notice("low-space alert posted — critical=\(isCritical, privacy: .public)")
    }

    /// Keeps the dropdown's reclaimable line in step with the last scan. The
    /// menubar renders it; it does not go looking for scan results itself.
    private func refreshMenubarSummary() {
        guard let set = model.recommendations, set.totalReclaimableBytes > 0 else {
            menubar?.reclaimableSummary = nil
            return
        }
        let biggest = set.recommendations
            .filter { $0.tier != .appManaged }
            .max(by: { $0.sizeBytes < $1.sizeBytes })
        var detail = model.lastScanAt.map { "Last scan \(RelativeTime.phrase($0))." } ?? ""
        if let biggest {
            detail += " Biggest: \(biggest.classification.title), \(ByteFormat.compact(biggest.sizeBytes))."
        }
        menubar?.reclaimableSummary = (set.totalReclaimableBytes, detail)
        menubar?.refreshDisplay()
    }

    /// A09's main surface. Also the target of the dropdown's ⌘O.
    @objc private func showSettingsFromMenu() {
        openMainWindow()
        model.isShowingSettings = true
    }

    @objc private func scanFromMenu() {
        beginScan()
    }

    private func openMainWindow() {
        mainWindow?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("applicationWillTerminate — tearing down monitor and cancelling any scan")
        // F04: quitting cancels any in-flight scan and discards partial results.
        scanEngine.cancel()
        disk.stop()
        menubar?.stop()
        menubar = nil
    }

    /// F06's entry point, from the dropdown's "Scan Now" and the window's Scan
    /// button alike. Both surfaces report progress; neither owns it.
    private func beginScan() {
        guard !scanEngine.isRunning else { return }

        model.scanNotice = nil

        scanEngine.start { [weak self] result in
            guard let self else { return }
            menubar?.showScanStatus(
                "Scanned \(ByteFormat.compact(result.totalSizeBytes)) — \(result.blindSpots.count) blind spots"
            )
            // Free space almost always moved during a scan of any length, and
            // the sidebar sits directly above a figure the user just watched
            // being recalculated.
            disk.refresh()
            // F17: "reappears next scan" — expired by the event rather than by
            // a timestamp, so there is no sweep to run.
            model.clearSnoozes()
            model.checkWatches()
            // A scan is the other moment the answer can have changed — and the
            // moment the "granted, but the results predate it" banner has to
            // stand down.
            model.refreshAccessState()
            refreshMenubarSummary()
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
            let folder = (scanEngine.stall?.path as NSString?)?.lastPathComponent
            scanEngine.abandon()
            let notice = folder.map { "Scan abandoned — “\($0)” wasn't responding." }
                ?? "Scan abandoned — that folder wasn't responding."
            menubar?.showScanStatus(notice, canStop: false)
            model.scanNotice = notice
        } else {
            scanEngine.cancel()
            menubar?.showScanStatus("Stopping…", canStop: false)
            model.scanNotice = "Scan cancelled — showing the previous results."
        }
    }

    private func renderScanState() {
        guard scanEngine.isRunning else { return }

        // A stall outranks progress: when the walk is wedged, the last progress
        // figure is stale and showing it is what makes an app look frozen.
        if let stall = scanEngine.stall {
            let folder = PathDisplay.tail(stall.path)
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
