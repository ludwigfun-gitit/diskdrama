import SwiftUI

/// The main window's root view (A09, F08).
///
/// Chrome bar, 262px rail, flexible content pane. The window follows the system
/// appearance — the Light/Dark switch in the prototype was a convenience for
/// reviewing the design, not a feature, and every color resolves through dynamic
/// `NSColor` so nothing here branches on appearance.
struct MainWindow: View {

    @Bindable var model: AppModel
    let onScan: () -> Void
    let onStopScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                Sidebar(model: model)
                contentPane
            }
        }
        .background(Theme.content)
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingOnboarding) {
            OnboardingSheet(model: model, onScan: onScan)
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .delete(let item):  DeleteConfirmSheet(model: model, item: item)
            case .batchClean(let t): BatchCleanSheet(model: model, tier: t)
            case .target:            TargetSheet(model: model)
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("DiskDrama")
                .font(Theme.ui(13.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                // A fixed gap rather than a centred status. The status updates
                // continuously — a path, then a tick count, then "Scanned 2
                // hours ago" — and centring would re-centre it on every change,
                // so the one element on this bar that moves would also never sit
                // still. Left at a constant offset, only the text changes.
                .padding(.trailing, 20)

            // The status sits with the title rather than against the buttons.
            // The spacer used to come first, which meant every pixel of the gap
            // went to the spacer and the status was squeezed against the right
            // edge — with a whole empty title bar beside it. Now the status is
            // offered the room first and the spacer takes what's left.
            scanStatus

            Spacer(minLength: 12)

            Button {
                model.activeSheet = .target
            } label: {
                Label("Set a target", systemImage: "target")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.hasNeverScanned)
            .accessibilityLabel("Get me to a free-space target")
            // The buttons are what the user acts on, so they keep their full
            // size and the status is the thing that gives way in a narrow
            // window — never the other way round.
            .layoutPriority(1)

            Button(action: model.scanEngine.isRunning ? onStopScan : onScan) {
                Label(model.scanEngine.isRunning ? "Stop" : "Scan",
                      systemImage: model.scanEngine.isRunning ? "stop.circle" : "magnifyingglass")
            }
            .buttonStyle(AccentButtonStyle())
            .accessibilityLabel(model.scanEngine.isRunning ? "Stop the scan" : "Scan for reclaimable space")
            .layoutPriority(1)
        }
        // Left inset clears the traffic lights, which the system draws over this
        // bar because the window uses a full-size content view.
        .padding(.leading, 78)
        // 26, not 14: the same trailing inset the content pane uses, so Scan
        // lines up with the pane's action button, the size column and the
        // explanation panel's trailing control rather than sitting 11pt proud
        // of all of them.
        .padding(.trailing, 26)
        .frame(height: Theme.titleBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            // The bar *is* the bottom edge while a scan runs, so starting one
            // shifts nothing on this bar.
            if model.scanEngine.isRunning {
                ScanProgressLine(fraction: model.scanProgressFraction,
                                 isStalled: model.scanEngine.stall != nil)
            } else {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }

    /// One line of state, in priority order: a stall outranks progress, because
    /// when the walk is wedged the last progress figure is stale and showing it
    /// is exactly what makes an app look frozen.
    @ViewBuilder
    private var scanStatus: some View {
        if let stall = model.scanEngine.stall {
            // The full path here, not the two-component tail: this bar has the
            // width for it, and middle truncation keeps both the part that says
            // *where* and the folder name that says *what* — losing only the
            // middle, which is the least useful part to keep.
            //
            // The work done so far is carried alongside, explicitly labelled.
            // A stalled walk reports nothing, so this figure is frozen — but a
            // frozen number that says "so far" is evidence the scan got
            // somewhere, where a bare timer climbing past ten minutes reads as
            // nothing having happened at all.
            let folder = PathDisplay.short(stall.path)
            statusText(stall.isAbandonable
                ? "Still reading “\(folder)” — \(RelativeTime.elapsed(stall.seconds))\(scannedSoFar)"
                : "Reading “\(folder)”…")
        } else if let progress = model.scanEngine.progress {
            statusText("\(ByteFormat.count(progress.entriesVisited)) items · \(ByteFormat.compact(progress.bytesSoFar))")
        } else if model.scanEngine.phase == .finishing {
            statusText("Finishing up…")
        } else if let notice = model.scanNotice {
            statusText(notice)
        } else if let scannedAt = model.lastScanAt {
            statusText("Scanned \(RelativeTime.phrase(scannedAt))")
        }
    }

    /// Only shown once there is something to report, so a stall in the first
    /// second doesn't claim "0 items".
    private var scannedSoFar: String {
        guard let progress = model.scanEngine.progress, progress.entriesVisited > 0 else { return "" }
        return " · \(ByteFormat.count(progress.entriesVisited)) items so far"
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12.5))
            .foregroundStyle(Theme.text3)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: - Content

    private var contentPane: some View {
        // Notices wrap every pane, not just the tiers.
        //
        // `deletionError` is the app's only channel for "that didn't work", and
        // `ResultsNotices` is its only renderer — but it used to render inside
        // the `.tier` case alone. "Put back" lives on History and sets exactly
        // that property when a restore fails, so the one failure a user could
        // provoke from that pane was the one guaranteed never to be shown. The
        // reduced-mode banner is global truth too and loses nothing by being
        // visible everywhere.
        VStack(spacing: 0) {
            ResultsNotices(model: model, onScan: onScan)
            paneBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ContentWash())
    }

    @ViewBuilder
    private var paneBody: some View {
        Group {
            switch model.pane {
            case .tier(let tier):
                // Notices first, and outside `TierPane`: they describe the scan
                // rather than the tier, and `TierPane` is rebuilt per tier, so
                // anything inside it is duplicated across all three and remounts
                // on every switch.
                // The banners stay out here: they are full-width bars about the
                // scan as a whole, and `TierPane` is rebuilt per tier, so
                // anything inside it renders once per tier and remounts on every
                // switch. Blind spots went the other way — they are now split
                // across the tiers that recognise them, so they live inside.
                TierPane(model: model, tier: tier, onScan: onScan)
            case .unscanned:      UnscannedPane(model: model, onScan: onScan)
            case .cloud:          CloudPane(model: model)
            case .changes:        ChangesPane(model: model)
            case .history:        HistoryPane(model: model)
            case .watching:       WatchingPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ContentWash())
    }
}
