import SwiftUI

/// DD.B004 — the locations the scan could not read, named.
///
/// F06 already required that unreadable locations be recorded and shown rather
/// than guessed at, and the callout said how many. It did not say *which*, which
/// left the user with a number they could not act on or judge: four unreadable
/// locations might be four empty caches or the entire Photos library, and
/// nothing on screen distinguished those. For an app whose whole claim is
/// completeness, an unexplained hole in the total is the worst thing to leave
/// unexplained.
///
/// Everything here comes from data the scan already produced — `blindSpots`
/// carries a path and a reason for each — so this is a window onto existing
/// facts, not new plumbing.
struct BlindSpotsSheet: View {

    @Bindable var model: AppModel
    let onScan: () -> Void

    private var spots: [(path: String, reason: BlindSpotReason)] {
        model.blindSpots.sorted { $0.path < $1.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                        row(spot)
                        if index != spots.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            Divider()
            footer
        }
        .frame(width: 620)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spots.count == 1 ? "1 location couldn't be read" : "\(spots.count) locations couldn't be read")
                .font(Theme.display(17))
                .foregroundStyle(Theme.text)
            Text("Anything inside these is missing from every total DiskDrama shows you. "
                 + "That makes the figures a floor rather than a measurement.")
                .font(Theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private func row(_ spot: (path: String, reason: BlindSpotReason)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(PathDisplay.friendlyName(spot.path) ?? PathDisplay.short(spot.path))
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if PathDisplay.friendlyName(spot.path) != nil {
                    Text(PathDisplay.short(spot.path))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(explanation(for: spot.reason))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            HStack(spacing: 7) {
                // Only offered when it is actually the fix. A "Grant access"
                // button next to a symlink loop would be a button that cannot
                // work, which is worse than no button.
                if spot.reason == .fullDiskAccessMissing {
                    Button("Grant access") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(AccentButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))
                }
                Button("Retry") {
                    model.activeSheet = nil
                    onScan()
                }
                .buttonStyle(GhostButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))

                // Ignoring routes to the exclusion list, which is the existing
                // "stop looking here" mechanism — so the choice is visible and
                // reversible in Settings rather than buried in a per-scan flag
                // the user can never find again.
                Button("Ignore") { model.exclude(path: spot.path) }
                    .buttonStyle(QuietButtonStyle(height: 26, fontSize: 12.5))
                    .disabled(spot.reason == .excludedByUser)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Says what went wrong in terms of what the user can do about it, not in
    /// terms of the errno that produced it.
    private func explanation(for reason: BlindSpotReason) -> String {
        switch reason {
        case .fullDiskAccessMissing:
            "macOS is withholding this until DiskDrama has Full Disk Access."
        case .permissionDenied:
            "Permission denied. This one is owned by another user or by the system, and Full Disk Access won't change that."
        case .unreadable:
            "Couldn't be opened — an offline volume, a broken link, or a folder the filesystem is unhappy with."
        case .excludedByUser:
            "You've told DiskDrama not to look here. Remove it from “Never look here” in Settings to include it again."
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if spots.contains(where: { $0.reason == .fullDiskAccessMissing }) {
                Text("Granting access needs DiskDrama restarted before a new scan can use it.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)
            Button("Done") { model.activeSheet = nil }
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
