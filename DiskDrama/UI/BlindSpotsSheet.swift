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

    /// Genuine read failures — something went wrong.
    private var failures: [(path: String, reason: BlindSpotReason)] {
        spots.filter { $0.reason != .excludedByUser }
    }

    /// Locations that were skipped on purpose. Not failures, and listing them
    /// beside failures at the same visual weight is what made a decision the
    /// user already made read as an outstanding problem.
    private var deliberate: [(path: String, reason: BlindSpotReason)] {
        spots.filter { $0.reason == .excludedByUser }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if !failures.isEmpty {
                        sectionHeader(failures.count == 1 ? "1 location couldn't be read"
                                                         : "\(failures.count) locations couldn't be read")
                        rows(failures)
                    }
                    if !deliberate.isEmpty {
                        sectionHeader("Skipped on purpose")
                        rows(deliberate)
                    }
                }
            }
            .frame(maxHeight: 340)
            Divider()
            footer
        }
        .frame(width: 640)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failures.isEmpty ? "Nothing failed to read" : "Locations missing from the totals")
                .font(Theme.display(17))
                .foregroundStyle(Theme.text)
            Text(failures.isEmpty
                 ? "Everything DiskDrama tried to read, it read. The locations below were skipped deliberately, so nothing here is a problem to fix."
                 : "Anything inside these is missing from every total DiskDrama shows you. That makes the figures a floor rather than a measurement.")
                .font(Theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Eyebrow(text: title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func rows(_ list: [(path: String, reason: BlindSpotReason)]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { index, spot in
            row(spot)
            if index != list.count - 1 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
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
                Text(BlindSpotCopy.long(spot))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions(for: spot).padding(.top, 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Every button here has to be able to change something. The previous
    /// version offered Retry and Ignore on every row regardless of reason, which
    /// meant a permission wall got a Retry that cannot move it and an
    /// already-excluded path got an Ignore greyed out to say so — a row whose
    /// only affordance was disabled, describing a fix the user had already
    /// applied.
    @ViewBuilder
    private func actions(for spot: (path: String, reason: BlindSpotReason)) -> some View {
        HStack(spacing: 7) {
            if spot.reason == .excludedByUser {
                // "Scan anyway" is unexclude-then-rescan rather than a one-shot
                // override: the skip set is built once at scan start from
                // Settings.exclusions, so a genuine one-off would mean threading
                // a second exclusion list through the walk for one click.
                //
                // Withheld for DiskDrama's own cloud-storage defaults. The hang
                // it protects against is real and measured in minutes, so
                // opting in belongs in Settings as a considered choice, not as
                // the nearest button in a list of things that went wrong.
                if !BlindSpotCopy.isDiskDramasOwnSkip(spot) {
                    Button("Scan anyway") {
                        model.unexclude(path: spot.path)
                        model.activeSheet = nil
                        onScan()
                    }
                    .buttonStyle(AccentButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))
                }
                Button("Stop excluding") { model.unexclude(path: spot.path) }
                    .buttonStyle(GhostButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))
            } else {
                if spot.reason == .fullDiskAccessMissing {
                    Button("Grant access") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(AccentButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))
                }
                if BlindSpotCopy.retryCouldHelp(spot.reason) {
                    Button("Retry") {
                        model.activeSheet = nil
                        onScan()
                    }
                    .buttonStyle(GhostButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12.5))
                }
                // Named for what it does, not for the other feature. The app's
                // "Ignored" list (F18) still scans and still counts the folder;
                // this is the hard skip (F19) that stops it being read at all,
                // and two different mechanisms must not share a word.
                Button("Stop looking here") { model.exclude(path: spot.path) }
                    .buttonStyle(QuietButtonStyle(height: 26, fontSize: 12.5))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if failures.contains(where: { $0.reason == .fullDiskAccessMissing }) {
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


/// The one place blind-spot wording lives.
///
/// The callout shows the same locations inline for short lists and the sheet
/// shows them in full, so the two would otherwise be two copies of the same
/// sentences drifting apart at their own pace.
@MainActor
enum BlindSpotCopy {

    /// A location DiskDrama skipped on its own initiative rather than one the
    /// user chose. Attribution matters: "you told DiskDrama not to look here" is
    /// false for these, and it buries the actual reason.
    static func isDiskDramasOwnSkip(_ spot: (path: String, reason: BlindSpotReason)) -> Bool {
        spot.reason == .excludedByUser && Settings.isDefaultExclusion(spot.path)
    }

    /// One line, for the inline callout.
    static func short(_ spot: (path: String, reason: BlindSpotReason)) -> String {
        if isDiskDramasOwnSkip(spot) { return "Skipped by default — entering it can hang for minutes." }
        switch spot.reason {
        case .fullDiskAccessMissing: return "Needs Full Disk Access."
        case .permissionDenied:      return "Permission denied — owned by the system or another user."
        case .unreadable:            return "Couldn't be opened."
        case .excludedByUser:        return "You told DiskDrama not to look here."
        }
    }

    /// The fuller sentence, for the sheet.
    static func long(_ spot: (path: String, reason: BlindSpotReason)) -> String {
        if isDiskDramasOwnSkip(spot) {
            let name = PathDisplay.friendlyName(spot.path) ?? "This location"
            return "DiskDrama skips \(name) by default. Entering a cloud-storage root can hang for minutes "
                 + "while macOS decides what to download, so it is left alone unless you opt in from Settings."
        }
        switch spot.reason {
        case .fullDiskAccessMissing:
            return "macOS is withholding this until DiskDrama has Full Disk Access."
        case .permissionDenied:
            return "Permission denied. This one is owned by another user or by the system, and Full Disk Access won't change that."
        case .unreadable:
            return "Couldn't be opened — an offline volume, a broken link, or a folder the filesystem is unhappy with."
        case .excludedByUser:
            return "You told DiskDrama not to look here, so it was skipped."
        }
    }

    /// Whether retrying could plausibly change the answer.
    ///
    /// A macOS permission wall does not move because you asked twice, and an
    /// excluded path is filtered out of the walk before it is ever reached — so
    /// the button would do nothing either way. Offering it anyway teaches people
    /// that DiskDrama's buttons are decorative.
    static func retryCouldHelp(_ reason: BlindSpotReason) -> Bool {
        switch reason {
        case .unreadable, .fullDiskAccessMissing: true
        case .permissionDenied, .excludedByUser:  false
        }
    }
}
