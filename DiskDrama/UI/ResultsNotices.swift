import SwiftUI

/// The notices that belong to the scan, not to a tier.
///
/// Every one of these reads global state — Full Disk Access, the last deletion,
/// the blind spots — and every one of them used to live inside `TierPane`.
/// `MainWindow` builds a fresh `TierPane` per selected tier, so the same
/// sentence rendered under Safe to delete, App-managed and Review first, three
/// times, remounting on every switch. Blind spots left too, but the other
/// way: most can be recognised from their path, so they sit in the tier that
/// recognises them, and only the unrecognisable ones get a pane of their own.
struct ResultsNotices: View {

    @Bindable var model: AppModel
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            reducedModeBanner
            deletionNotice
        }
    }

    /// F05's failure case, made permanent: without Full Disk Access the app
    /// runs in reduced mode, and the banner offers the walkthrough again rather
    /// than leaving the user to wonder why the numbers look thin. Dismissable,
    /// because a banner you cannot silence is an app that nags.
    @ViewBuilder
    private var reducedModeBanner: some View {
        if !model.hasFullDiskAccess && !model.hasDismissedAccessBanner {
            HStack(spacing: 11) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 14)).foregroundStyle(Theme.text3)
                Text("Running with blind spots — a lot of reclaimable space lives in places I can't "
                     + "read without Full Disk Access.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Fix this") { model.isShowingOnboarding = true }
                    .buttonStyle(GhostButtonStyle(height: 24, horizontalPadding: 10, fontSize: 12))
                Button("Dismiss") { model.dismissAccessBanner() }
                    .buttonStyle(QuietButtonStyle(height: 24, fontSize: 12))
            }
            .padding(.horizontal, 26).padding(.vertical, 10)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        } else if model.lastScanMissedProtectedLocations {
            // Access has since been granted, but these totals were produced
            // without it. Simply hiding the banner here would read as "all
            // good" at the exact moment the numbers are still short.
            //
            // No Dismiss: one press of the button resolves it, and it clears
            // itself on the next scan however that scan is started.
            HStack(spacing: 11) {
                Image(systemName: "eye")
                    .font(.system(size: 14)).foregroundStyle(Theme.accent)
                Text("Full Disk Access is on now — but these totals came from a scan that ran "
                     + "without it, so they're still missing those places.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Scan again", action: onScan)
                    .buttonStyle(GhostButtonStyle(height: 24, horizontalPadding: 10, fontSize: 12))
            }
            .padding(.horizontal, 26).padding(.vertical, 10)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    /// Something went wrong, or resolved itself, outside a confirmation dialog.
    ///
    /// The only place this used to appear was inside the delete sheets, which
    /// works right up until the answer is "there is no sheet" — an item that has
    /// already been removed by something else is now taken off the list without
    /// opening one, and that has to be sayable somewhere.
    @ViewBuilder
    private var deletionNotice: some View {
        if let message = model.deletionError, model.activeSheet == nil {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                Text(message)
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { model.deletionError = nil }
                    .buttonStyle(QuietButtonStyle(height: 24, fontSize: 12))
            }
            .padding(.horizontal, 26).padding(.vertical, 10)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            // Same reasoning as the sheet: a second refusal carrying the same
            // sentence still has to look like a second refusal.
            .id(model.refusalCount)
            .transition(.opacity)
            .animation(Theme.transition, value: model.refusalCount)
        }
    }
}
