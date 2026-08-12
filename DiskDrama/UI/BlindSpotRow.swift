import SwiftUI

/// Which tier a blind spot belongs under, if any.
///
/// The premise: `KnowledgeBase.classify` works on path and name alone and never
/// needed the contents. A location that failed to read can still be recognised
/// for what it is — a build directory is a build directory whether or not it
/// could be enumerated — so the same rules that tier a scanned folder can tier
/// an unscanned one, and it lands beside the results it actually relates to.
///
/// What it cannot do is invent a tier for a path no rule recognises.
/// `~/Library/Mobile Documents` is not "safe", "app-managed" or "review first";
/// it is unmeasured. Those get `nil` here and live in their own pane rather than
/// being distributed across three tiers they have no claim to — which is what
/// made the old global callout, repeated identically under every tier, feel
/// like a misfiled fact.
/// A blind spot as it stands *now*, not as the scan recorded it.
///
/// The snapshot is history and Settings is current, and the two disagree the
/// moment the user acts. Excluding a location the scan failed to read does not
/// rewrite the scan, so a list rendered straight from the snapshot cannot show
/// the user's own action landing — which is exactly what made "Stop looking
/// here" look broken. It did precisely what it says, wrote the exclusion, and
/// nothing on screen moved, because the row was describing a scan that had
/// already finished.
enum BlindSpotState: Equatable {
    /// The scan could not read it, and nothing since has changed that.
    case unreadable(BlindSpotReason)
    /// Currently in `Settings.exclusions`. `wasSkipped` distinguishes "the scan
    /// skipped it because it was already excluded" from "the scan failed on it
    /// and the user has since told DiskDrama to stop trying".
    case excluded(wasSkipped: Bool)
    /// Skipped by this scan, but no longer excluded — so the next scan will read
    /// it. Without this state, "Stop excluding" had nowhere to move the row to.
    case pending
}

@MainActor
enum BlindSpotTiering {

    static func tier(for spot: (path: String, reason: BlindSpotReason)) -> Tier? {
        let name = (spot.path as NSString).lastPathComponent
        return KnowledgeBase.classify(path: spot.path, name: name)?.result.tier
    }
}


/// One blind spot, with whatever actions can actually change it.
///
/// Shared by the per-tier section and the Not-scanned pane so the two cannot
/// drift: the same location described one way in a tier and another way in the
/// pane would be worse than either wording alone.
struct BlindSpotRow: View {

    @Bindable var model: AppModel
    let spot: (path: String, reason: BlindSpotReason)
    let onScan: () -> Void

    var body: some View {
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
                Text(BlindSpotCopy.long(spot, state: model.state(of: spot)))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions.padding(.top, 1)
        }
    }

    /// Every button here has to be able to change something. An earlier version
    /// offered Retry and Ignore on every row regardless of reason, which meant a
    /// permission wall got a Retry that cannot move it and an already-excluded
    /// path got an Ignore greyed out to say so — a row whose only affordance was
    /// disabled, describing a fix the user had already applied.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 7) {
            if spot.reason == .excludedByUser {
                // "Scan anyway" is unexclude-then-rescan rather than a one-shot
                // override: the skip set is built once at scan start from
                // Settings.exclusions, so a genuine one-off would mean threading
                // a second exclusion list through the walk for one click.
                //
                // Withheld for DiskDrama's own cloud-storage defaults. The hang
                // it protects against is real and measured in minutes, so opting
                // in belongs in Settings as a considered choice, not as the
                // nearest button in a list of things that went wrong.
                if !BlindSpotCopy.isDiskDramasOwnSkip(spot) {
                    Button("Scan anyway") {
                        model.unexclude(path: spot.path)
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
                    Button("Retry", action: onScan)
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
}


/// The one place blind-spot wording lives.
///
/// The per-tier section and the Not-scanned pane describe the same locations, so
/// the two would otherwise be two copies of the same sentences drifting apart at
/// their own pace.
@MainActor
enum BlindSpotCopy {

    /// A location DiskDrama skipped on its own initiative rather than one the
    /// user chose. Attribution matters: "you told DiskDrama not to look here" is
    /// false for these, and it buries the actual reason.
    static func isDiskDramasOwnSkip(_ spot: (path: String, reason: BlindSpotReason)) -> Bool {
        spot.reason == .excludedByUser && Settings.isDefaultExclusion(spot.path)
    }

    /// One line, for the compact per-tier list.
    static func short(_ spot: (path: String, reason: BlindSpotReason)) -> String {
        if isDiskDramasOwnSkip(spot) { return "Skipped by default — entering it can hang for minutes." }
        switch spot.reason {
        case .fullDiskAccessMissing: return "Needs Full Disk Access."
        case .permissionDenied:      return "Permission denied — owned by the system or another user."
        case .unreadable:            return "Couldn't be opened."
        case .excludedByUser:        return "You told DiskDrama not to look here."
        }
    }

    /// The fuller sentence, for a full row, in terms of where things stand now.
    static func long(_ spot: (path: String, reason: BlindSpotReason), state: BlindSpotState) -> String {
        switch state {
        case .pending:
            return "No longer excluded. DiskDrama didn't read it during this scan, so it isn't in any total "
                 + "yet — the next scan will include it."
        case .excluded(wasSkipped: false):
            return "DiskDrama has stopped looking here. This scan couldn't read it anyway; the next one "
                 + "won't try, and its size stays unknown by design."
        case .excluded(wasSkipped: true), .unreadable:
            return long(spot)
        }
    }

    /// The fuller sentence, for a full row.
    static func long(_ spot: (path: String, reason: BlindSpotReason)) -> String {
        if isDiskDramasOwnSkip(spot) {
            let name = PathDisplay.friendlyName(spot.path) ?? "This location"
            return "DiskDrama skips \(name) by default — the iCloud Drive, Google Drive, OneDrive and Dropbox "
                 + "roots all live behind the same File Provider. Entering one can hang for minutes while macOS "
                 + "decides what to download, so it is left alone unless you opt in from Settings."
        }
        switch spot.reason {
        case .fullDiskAccessMissing:
            return "macOS is withholding this until DiskDrama has Full Disk Access."
        case .permissionDenied:
            // Named accurately because the reader's next move depends on it.
            // "Owned by another user or by the system" sent people looking for a
            // permission to change; the common case is a sandboxed app's own
            // container, which macOS refuses to open for anyone and which no
            // setting in Full Disk Access unlocks. There is no fix, and saying so
            // is more use than implying one exists somewhere off screen.
            return "macOS refuses to open this one, and Full Disk Access doesn't lift it — sandboxed app "
                 + "containers and other system-protected folders are sealed this way. There's nothing to fix here."
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
