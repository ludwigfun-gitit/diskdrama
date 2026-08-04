import SwiftUI

/// The content pane for one tier (F08).
///
/// Sorting is size-descending, which the builder already applied globally and
/// which survives filtering by tier. The tail is collapsed rather than listed:
/// eleven rows where six of them are 40 MB caches buries the 21 GB row that
/// actually matters, and the point of this screen is that the biggest thing is
/// unmissable.
struct TierPane: View {

    @Bindable var model: AppModel
    let tier: Tier
    let onScan: () -> Void

    /// Below this many rows there is nothing to gain from collapsing.
    private static let collapseThreshold = 6
    /// How many stay visible when the tail is collapsed.
    private static let visibleWhenCollapsed = 5

    @State private var isTailExpanded = false

    private var items: [Recommendation] { model.items(in: tier) }

    private var visibleItems: [Recommendation] {
        guard !isTailExpanded, items.count > Self.collapseThreshold else { return items }
        return Array(items.prefix(Self.visibleWhenCollapsed))
    }

    private var tailItems: [Recommendation] {
        guard !isTailExpanded, items.count > Self.collapseThreshold else { return [] }
        return Array(items.dropFirst(Self.visibleWhenCollapsed))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: tier.title, blurb: tier.blurb) {
                // A08: batch approval exists for Tier 1 and nowhere else. App-
                // managed routes to the owning app; Review first is strictly one
                // at a time, on purpose — so neither gets a button here.
                if tier.allowsBatchApproval && !items.isEmpty {
                    Button("Clean all \(items.count)…") {}
                        .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 14))
                        .disabled(true)   // F15 — Step 9
                }
            }

            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    ItemRow(
                        item: item,
                        isSelected: model.selection(in: tier)?.path == item.path,
                        badge: model.regrownPaths.contains(item.path) ? "Back again" : nil,
                        action: { model.select(item, in: tier) })
                }

                if !tailItems.isEmpty {
                    TailRow(count: tailItems.count,
                            sizeBytes: tailItems.reduce(0) { $0 + $1.sizeBytes }) {
                        withAnimation(Theme.transition) { isTailExpanded = true }
                    }
                }

                notOnThisList
                blindSpotNotice
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .id(tier)   // resets tail expansion when the tier changes
    }

    /// The Review tier states what it deliberately left out. Without this the
    /// biggest things on the disk are simply absent, and absence reads as an
    /// oversight rather than as a judgement call.
    @ViewBuilder
    private var notOnThisList: some View {
        if tier == .reviewFirst, let excluded = notOnThisListText {
            Callout(text: excluded).padding(.top, 10)
        }
    }

    private var notOnThisListText: String? {
        guard let set = model.recommendations else { return nil }
        let recommended = Set(set.recommendations.map(\.path))
        let notable = set.largestNonRecommendable
            .filter { !recommended.contains($0.path) }
            .prefix(2)
        guard !notable.isEmpty else { return nil }
        let phrases = notable.map { "\($0.name) (\(ByteFormat.compact($0.sizeBytes)))" }
        return "Not on this list: \(phrases.joined(separator: " and ")). "
            + "\(notable.count == 1 ? "It's" : "They're") among the biggest things on the disk and I'd leave "
            + "\(notable.count == 1 ? "it" : "both") alone."
    }

    /// F06 is explicit that unreadable locations are recorded and shown, never
    /// guessed at. A total computed over a tree with holes in it is a floor, not
    /// a measurement, and the user is entitled to know which.
    @ViewBuilder
    private var blindSpotNotice: some View {
        let spots = model.blindSpots
        if !spots.isEmpty {
            let missingAccess = spots.filter { $0.reason == .fullDiskAccessMissing }.count
            Callout(
                text: missingAccess > 0
                    ? "I couldn't read \(spots.count) location\(spots.count == 1 ? "" : "s") — \(missingAccess) of them need Full Disk Access. The totals above are a floor, not the whole picture."
                    : "I couldn't read \(spots.count) location\(spots.count == 1 ? "" : "s"), so the totals above are a floor rather than the whole picture.",
                symbol: "eye.slash")
            .padding(.top, 10)
        }
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if model.hasNeverScanned {
            EmptyPane(
                title: "Nothing scanned yet",
                message: "Run a scan and I'll sort what I find into what's safe to delete, what another app owns, and what you should look at yourself.",
                symbol: "sparkle.magnifyingglass"
            ) {
                Button("Scan", action: onScan)
                    .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
            }
        } else {
            EmptyPane(
                title: emptyTitle,
                message: emptyMessage,
                symbol: tier == .safe ? "checkmark.circle" : "tray")
        }
    }

    private var emptyTitle: String {
        switch tier {
        case .safe:        "Nothing safe to clean up"
        case .appManaged:  "Nothing another app is holding"
        case .reviewFirst: "Nothing that needs your judgement"
        }
    }

    /// F08's failure case: with nothing to suggest, say where the space actually
    /// went. An empty list on its own is indistinguishable from a scan that
    /// silently failed.
    private var emptyMessage: String {
        let base: String
        switch tier {
        case .safe:        base = "No caches or build output worth reclaiming turned up in the last scan."
        case .appManaged:  base = "None of the apps I know about are sitting on storage you'd clear from inside them."
        case .reviewFirst: base = "Nothing ambiguous enough to need a second opinion."
        }
        guard let largest = model.recommendations?.largestNonRecommendable.first else { return base }
        return base + " Your space is mostly \(largest.name) (\(ByteFormat.compact(largest.sizeBytes))) — nothing I'd advise deleting."
    }
}

// MARK: - Pane header

/// Title, one-line description, and the pane's single batch action.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let blurb: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.display(19))
                    .foregroundStyle(Theme.text)
                Text(blurb)
                    .font(Theme.body(13.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

// MARK: - Rows

/// One recommendation.
///
/// Selection is a neutral hover-tint fill plus an accent *title* — never an
/// accent-filled row and never a colored border. Both were tried during design
/// and rejected: a filled row makes a list of eleven look like eleven buttons,
/// and the handoff's border rule is that colored borders do not exist in this
/// app at all.
struct ItemRow: View {
    let item: Recommendation
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { row }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            // A custom button style collapses its children into one unlabelled
            // element, so the label is stated rather than inferred. Size before
            // path: the number is what the row is for, and a screen-reader user
            // should not have to sit through a long path to reach it.
            .accessibilityLabel(
                "\(item.classification.title), \(ByteFormat.compact(item.sizeBytes))"
                + (badge.map { ", \($0)" } ?? "")
                + ", at \(PathDisplay.short(item.path))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.classification.title)
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Text(PathDisplay.short(item.path))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            if let badge { RowBadge(text: badge) }

            Text(ByteFormat.compact(item.sizeBytes))
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(Theme.text)
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

/// The collapsed remainder.
private struct TailRow: View {
    let count: Int
    let sizeBytes: Int64
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { row }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("Show \(count) smaller items, \(ByteFormat.compact(sizeBytes)) in total")
    }

    private var row: some View {
        HStack(spacing: 12) {
            Text("\(count) smaller items").font(Theme.ui(13))
            Spacer()
            Text(ByteFormat.compact(sizeBytes)).font(Theme.mono(13.5, weight: .semibold))
        }
        .foregroundStyle(isHovering ? Theme.accent : Theme.text3)
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, Theme.rowPaddingV)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(isHovering ? Theme.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

// MARK: - Copy

extension Tier {
    /// The pane's one-line description. Lifted verbatim from the handoff — the
    /// wording is the product's voice, and paraphrasing it here would be the
    /// first crack in a tone the whole design depends on.
    var blurb: String {
        switch self {
        case .safe:
            "Caches and build output that the tools rebuild themselves. Nothing here is something you made."
        case .appManaged:
            "Another app owns this storage and clears it better than I could. I'll point you at the right screen instead of reaching in."
        case .reviewFirst:
            "Your data, or close enough that I won't guess. One at a time — there's no batch button on this tier, on purpose."
        }
    }
}
