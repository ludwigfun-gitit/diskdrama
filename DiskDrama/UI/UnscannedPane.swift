import SwiftUI

/// The fourth card's pane: locations that have no tier.
///
/// This started as a sheet behind a "Show list" button on a callout repeated
/// under every tier. Both halves of that were wrong. The callout was global data
/// filed under three headings it had nothing to do with, and the sheet made the
/// one thing the app could not measure the one thing that took a click to see.
///
/// Blind spots that *can* be recognised from their path are shown in their own
/// tier, next to the results they qualify. What is left is genuinely
/// unmeasurable, and unmeasurable is a category, not an error — so it gets a
/// place to live rather than an interruption.
///
/// It is built to the same shape as `TierPane`: a list of rows, and one detail
/// bar at the foot carrying every action for whichever row is selected. Rows
/// with their own buttons made this pane read as a different kind of screen from
/// the three beside it, and the buttons had to compete with the row's own text
/// for width — which is how the longest name here rendered as a blank line.
struct UnscannedPane: View {

    @Bindable var model: AppModel
    let onScan: () -> Void

    /// Local, not on the model: nothing outside this pane needs to know, and
    /// there is no drill-in to keep a stack for.
    @State private var selectedPath: String?

    private var spots: [(path: String, reason: BlindSpotReason)] { model.unplacedBlindSpots }

    /// Grouped by where things stand *now*, not by what the scan recorded. This
    /// is what makes the buttons visible: excluding a failed location moves its
    /// row from the first group to the second, and un-excluding moves it to the
    /// third, so every action has somewhere to land.
    private func group(_ match: (BlindSpotState) -> Bool) -> [(path: String, reason: BlindSpotReason)] {
        spots.filter { match(model.state(of: $0)) }
    }

    /// Genuine read failures — something went wrong and still is wrong.
    private var failures: [(path: String, reason: BlindSpotReason)] {
        group { if case .unreadable = $0 { true } else { false } }
    }

    /// Locations skipped on purpose. Not failures, and listing them beside
    /// failures at the same visual weight is what made a decision the user
    /// already made read as an outstanding problem.
    private var deliberate: [(path: String, reason: BlindSpotReason)] {
        group { if case .excluded = $0 { true } else { false } }
    }

    /// No longer excluded, but this scan didn't read them. Their absence from
    /// the totals is now temporary, and saying so is the whole point of the
    /// group — it is where "Stop excluding" puts what it just acted on.
    private var pending: [(path: String, reason: BlindSpotReason)] {
        group { $0 == .pending }
    }

    private var selected: (path: String, reason: BlindSpotReason)? {
        spots.first { $0.path == selectedPath } ?? spots.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Not scanned", blurb: blurb) { EmptyView() }

            if spots.isEmpty && model.hiddenBlindSpotCount == 0 {
                emptyState
            } else if spots.isEmpty {
                VStack(spacing: 0) { Spacer(minLength: 0); hiddenNote; Spacer(minLength: 0) }
            } else {
                list
                if let spot = selected {
                    UnscannedDetail(model: model, spot: spot, onScan: onScan)
                }
            }
        }
    }

    /// States the consequence, not just the fact. A count of unread folders is
    /// only worth showing because of what it does to every other number.
    private var blurb: String {
        spots.isEmpty
            ? "Everything DiskDrama tried to read, it read."
            : "Nothing in here counts toward any total on the other tiers, which makes those figures a floor rather than a measurement."
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !failures.isEmpty {
                    sectionHeader(failures.count == 1 ? "1 location couldn't be read"
                                                     : "\(failures.count) locations couldn't be read")
                    rows(failures)
                }
                if !deliberate.isEmpty {
                    sectionHeader("Skipped on purpose")
                    rows(deliberate)
                }
                if !pending.isEmpty {
                    sectionHeader("Will be read on the next scan")
                    rows(pending)
                }
                hiddenNote
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Eyebrow(text: title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Keyed by path, not by index.
    ///
    /// Both sections render into the same `LazyVStack`, so two `ForEach`es keyed
    /// by offset each claimed identity 0 — and SwiftUI, seeing one identity twice
    /// in one container, kept one view and dropped the other. The casualty was
    /// always the first "Skipped on purpose" row, which rendered as a row-height
    /// blank: a location counted in every total, listed in no list, and visible
    /// only as an unexplained gap. A path is already unique here and already the
    /// thing the row is about.
    @ViewBuilder
    private func rows(_ list: [(path: String, reason: BlindSpotReason)]) -> some View {
        ForEach(list, id: \.path) { spot in
            UnscannedRow(
                spot: spot,
                isSelected: selected?.path == spot.path,
                action: { selectedPath = spot.path })
        }
    }

    /// Hiding a row must not quietly shrink the truth. The count stays on
    /// screen, so the totals are never described as more complete than they are —
    /// the user has only opted out of being told which ones, again, every time.
    @ViewBuilder
    private var hiddenNote: some View {
        if model.hiddenBlindSpotCount > 0 {
            let n = model.hiddenBlindSpotCount
            HStack(spacing: 6) {
                Text("\(n) more \(n == 1 ? "location is" : "locations are") hidden and still missing from the totals.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                Button("Manage in Settings") { model.isShowingSettings = true }
                    .buttonStyle(.plain)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.top, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "eye")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.text3)
            Text("No unreadable locations")
                .font(Theme.ui(14, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("Every total DiskDrama shows you is a complete measurement.")
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// One location, shaped like `ItemRow` so the two lists read as one app.
///
/// Where a tier row ends in a size, this ends in "—". The card in the sidebar
/// makes the same point: the whole claim of this pane is that these were never
/// measured, and a number here would be a guess wearing a reading's clothes.
private struct UnscannedRow: View {
    let spot: (path: String, reason: BlindSpotReason)
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var title: String {
        PathDisplay.friendlyName(spot.path) ?? (spot.path as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: action) { row }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("\(title), size unknown, at \(PathDisplay.short(spot.path))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(PathDisplay.short(spot.path))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            Text("—")
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, Theme.rowPaddingV)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(isSelected || isHovering ? Theme.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .animation(Theme.transition, value: isSelected)
    }
}


/// The foot of the pane, built to `ExplanationPanel`'s shape: what this is, then
/// every action that could change it, on one row.
///
/// No "Look inside". The contents were never read, so there is nothing to show —
/// and a button that opens an empty list is worse than no button.
private struct UnscannedDetail: View {

    @Bindable var model: AppModel
    let spot: (path: String, reason: BlindSpotReason)
    let onScan: () -> Void

    private var title: String {
        PathDisplay.friendlyName(spot.path) ?? (spot.path as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            Text(BlindSpotCopy.long(spot, state: model.state(of: spot)))
                .font(Theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(Theme.display(15))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("size unknown")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text3)
            Spacer(minLength: 0)
        }
    }

    /// Every button here has to be able to change something. An earlier version
    /// offered Retry and Ignore on every row regardless of reason, which meant a
    /// permission wall got a Retry that cannot move it and an already-excluded
    /// path got an Ignore greyed out to say so — a row whose only affordance was
    /// disabled, describing a fix the user had already applied.
    ///
    /// The styles carry meaning, not rank, and are not free to normalise.
    /// `QuietButtonStyle` marks the refusals — Dismiss, Skip for now, Not now,
    /// Never…, Stop looking here — every one of them "make this go away" rather
    /// than "do the thing". They stay reachable and stay unattractive, so nobody
    /// suppresses a finding because its escape hatch was the boldest control in
    /// reach. Flattening them to ghost for visual evenness reads tidier and
    /// quietly promotes the one action here with irreversible consequences.
    ///
    /// A sealed location correctly has no accent button: there is no primary
    /// action, because there is nothing to be done. Rows that *can* be resolved
    /// get one, which is what gives the row a top to its hierarchy.
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Reveal in Finder") { FileActions.revealInFinder(path: spot.path) }
                .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))

            if case .pending = model.state(of: spot) {
                // It will be read next time regardless; offering the scan now is
                // the only thing that brings that forward.
                Button("Scan now", action: onScan)
                    .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 14, fontSize: 12.5))
                Button("Stop looking here") { model.exclude(path: spot.path) }
                    .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
            } else if case .excluded = model.state(of: spot) {
                // "Scan anyway" is unexclude-then-rescan rather than a one-shot
                // override: the skip set is built once at scan start from
                // Settings.exclusions, so a genuine one-off would mean threading
                // a second exclusion list through the walk for one click.
                //
                // Withheld for DiskDrama's own cloud-storage defaults. The hang
                // it protects against is real and measured in minutes, so opting
                // in belongs in Settings as a considered choice, not as the
                // nearest button in a list of things that went wrong.
                if !Settings.isDefaultExclusion(spot.path) {
                    Button("Scan anyway") {
                        model.unexclude(path: spot.path)
                        onScan()
                    }
                    .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 14, fontSize: 12.5))
                }
                Button("Stop excluding") { model.unexclude(path: spot.path) }
                    .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
            } else {
                if spot.reason == .fullDiskAccessMissing {
                    Button("Grant access") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 14, fontSize: 12.5))
                }
                if BlindSpotCopy.retryCouldHelp(spot.reason) {
                    Button("Retry", action: onScan)
                        .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
                }
                // Named for what it does, not for the other feature. The app's
                // "Ignored" list (F18) still scans and still counts the folder;
                // this is the hard skip (F19) that stops it being read at all,
                // and two different mechanisms must not share a word.
                Button("Stop looking here") { model.exclude(path: spot.path) }
                    .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
            }

            // The genuine hide, and the only refusal in this bar — so this is
            // where QuietButtonStyle belongs.
            //
            // Named against "Stop looking here", not against Ignore. *Looking*
            // is what the scan does; *listing* is what this pane does, and those
            // are the two different things the user can switch off. The obvious
            // label was "Never mention this", which would have put a third
            // "Never…" beside F18's "Never suggest this" and F19's "Never look
            // in this folder" — three suppressions, one word, differing in a
            // noun. DD.B008 already treated exactly that as a bug.
            Button("Stop listing this") { model.hideBlindSpot(path: spot.path) }
                .buttonStyle(QuietButtonStyle(height: 29))

            Spacer(minLength: 8)

            if spot.reason == .fullDiskAccessMissing {
                Text("Needs a restart before a new scan can use it.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
            }
        }
    }
}
