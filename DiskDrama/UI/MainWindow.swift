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
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("DiskDrama")
                .font(Theme.ui(13.5, weight: .semibold))
                .foregroundStyle(Theme.text)

            Spacer(minLength: 12)

            scanStatus

            // F23's planner. Present because it is part of the window's identity
            // in the handoff, disabled until the flow behind it exists.
            Button {
            } label: {
                Label("Get me to…", systemImage: "target")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(true)
            .accessibilityLabel("Get me to a free-space target")

            Button(action: model.scanEngine.isRunning ? onStopScan : onScan) {
                Label(model.scanEngine.isRunning ? "Stop" : "Scan",
                      systemImage: model.scanEngine.isRunning ? "stop.circle" : "magnifyingglass")
            }
            .buttonStyle(AccentButtonStyle())
            .accessibilityLabel(model.scanEngine.isRunning ? "Stop the scan" : "Scan for reclaimable space")
        }
        // Left inset clears the traffic lights, which the system draws over this
        // bar because the window uses a full-size content view.
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(height: Theme.titleBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    /// One line of state, in priority order: a stall outranks progress, because
    /// when the walk is wedged the last progress figure is stale and showing it
    /// is exactly what makes an app look frozen.
    @ViewBuilder
    private var scanStatus: some View {
        if let stall = model.scanEngine.stall {
            let folder = (stall.path as NSString).lastPathComponent
            statusText(stall.isAbandonable
                ? "Still reading “\(folder)” — \(Int(stall.seconds))s"
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

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12.5))
            .foregroundStyle(Theme.text3)
            .lineLimit(1)
    }

    // MARK: - Content

    private var contentPane: some View {
        Group {
            switch model.pane {
            case .tier(let tier): TierPane(model: model, tier: tier, onScan: onScan)
            case .changes:        ChangesPane(model: model)
            case .history:        HistoryPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ContentWash())
    }
}
