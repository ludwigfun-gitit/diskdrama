import SwiftUI

/// The fixed-bottom explanation panel (F09–F13).
///
/// This is where the app earns its keep. Everything above it is a list of
/// folders and numbers, which any disk tool can produce; this panel is the part
/// that says what a thing *is*, what happens if it goes, and how sure it is —
/// and it is the reason the user can make the call without going and reading a
/// Stack Overflow thread about `DerivedData`.
///
/// Two rules it holds to:
///
/// - **Never invent an explanation.** An unrecognised folder says so, in as many
///   words, and lands in Review first. F09 names a confident-sounding guess as
///   the failure case, and it would be the single fastest way to get someone to
///   delete something they needed.
/// - **State consequence, not category.** "Build artifacts" is a category.
///   "Xcode rebuilds it on your next build — one slow clean build per project"
///   is a consequence, and it is the only one of the two that helps.
struct ExplanationPanel: View {

    @Bindable var model: AppModel
    let tier: Tier
    let item: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            breadcrumb
            header
            explanation
            if model.lookInsideOpen { lookInside }
            actions
        }
        // A05: generated on first view, for the item actually opened. A cache
        // hit resolves without touching the network, and `.task(id:)` re-fires
        // when the subject changes rather than on every re-render.
        .task(id: item.fingerprint) {
            model.explanations.requestIfNeeded(for: item)
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: - Breadcrumb (F13)

    /// Only present once the user has descended. The design has no breadcrumb
    /// because it never shows a drilled-in state, but F13 requires a path back
    /// and an unmarked one-way descent would be worse than not offering it.
    @ViewBuilder
    private var breadcrumb: some View {
        // Ancestors only. The header states the current item, so including it
        // here would print the same name twice in adjacent lines.
        let ancestors = model.breadcrumb(in: tier).dropLast()
        if !ancestors.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(ancestors.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    Button(crumb.name) { model.popDrill(in: tier, to: index) }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Back to \(crumb.name)")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.classification.title)
                .font(Theme.display(15))
                .foregroundStyle(Theme.text)
            metadata
            Spacer(minLength: 0)
        }
    }

    /// Size, scale, and how sure the app is — the last of which F09 requires and
    /// most tools omit entirely.
    private var metadata: some View {
        HStack(spacing: 6) {
            // The separator belongs to whichever branch follows, not to the text
            // before it — carrying it in `metadataText` printed "· ·" on every
            // item that doesn't get the live dot.
            Text(metadataText + " ·")
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.text3)

            if confidence.showsLiveDot {
                // The cyan is deliberately ~33° of hue from the accent so a
                // confidence signal never reads as a button.
                GlowDot(size: 5)
                Text(confidence.label)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.glow)
            } else {
                Text(confidence.label)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.text3)
            }

            explanationSource
            Spacer(minLength: 0)
        }
    }

    /// Where the prose in the two columns came from.
    ///
    /// The user is being asked to delete files on the strength of this text, so
    /// "a rule table recognised the folder name" and "a model looked at it"
    /// are different claims and are labelled differently. Silently swapping
    /// richer text in and letting it read as the same source would be the
    /// dishonest option.
    @ViewBuilder
    private var explanationSource: some View {
        switch model.explanations.state(for: item) {
        case .loading:
            HStack(spacing: 5) {
                Text("·").foregroundStyle(Theme.text3)
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("looking closer…").foregroundStyle(Theme.text3)
            }
            .font(Theme.mono(12.5))
        case .ready:
            // Named rather than a generic "looked closer". With two possible
            // sources the reader is entitled to know whether the text they're
            // about to act on was written on their own machine or in a
            // datacentre — those have different reliability and different
            // privacy properties, and the difference is not the app's to hide.
            //
            // The name replaces "looked closer" instead of following it. This
            // is one line in a single-line metadata row; carrying both wrapped
            // it onto three lines and broke the row's baseline.
            Text("· \(model.explanations.sourceName ?? "looked closer")")
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.glow)
                .lineLimit(1)
                .fixedSize()
        case .failed(let reason):
            Text("· couldn't look closer")
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.text3)
                .help(reason)
        case .idle, .unavailable:
            EmptyView()
        }
    }

    /// The model's answer when it has one, the rule table's otherwise.
    private var aiExplanation: Explanation? {
        if case .ready(let explanation) = model.explanations.state(for: item) {
            return explanation
        }
        return nil
    }

    private var metadataText: String {
        var parts = [ByteFormat.compact(item.sizeBytes)]
        if item.fileCount > 0 {
            parts.append(ByteFormat.files(item.fileCount))
        }
        if let days = item.daysSinceModified, days >= 30 {
            parts.append("untouched \(staleness(days))")
        }
        return parts.joined(separator: " · ")
    }

    private func staleness(_ days: Int) -> String {
        switch days {
        case ..<60:  "a month"
        case ..<365: "\(days / 30) months"
        case ..<730: "over a year"
        default:     "over \(days / 365) years"
        }
    }

    /// The model's confidence once it has one — it looked at the item, the
    /// rule table only matched a path. Where they disagree, the more informed
    /// number is the one to show.
    private var confidence: ConfidenceBand {
        ConfidenceBand(aiExplanation?.confidence ?? item.classification.confidence)
    }

    // MARK: - Explanation

    /// Two columns: what it is, then what happens if it goes. The split is the
    /// design's and it maps exactly onto the two questions a person actually has,
    /// in the order they have them.
    private var explanation: some View {
        HStack(alignment: .top, spacing: 30) {
            Text(aiExplanation?.whatThisIs ?? item.classification.whatThisIs)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(consequence)
                // F12: a Tier 2 item needs the route to the right screen, not
                // just the app's name. Emphasized because it is an instruction
                // the user is about to follow, not background.
                if let pointer = item.classification.owningApp?.pointer {
                    Text(pointer).foregroundStyle(Theme.text)
                }
                if let personal = personalNote {
                    // The one part of the panel that is about *this* user's
                    // history rather than about the folder. Given full-strength
                    // text because it is the sentence most likely to change the
                    // decision.
                    Text(personal).foregroundStyle(Theme.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.body(13.5))
        .lineSpacing(4)
        .foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Rebuild cost is folded in rather than given its own row: "it regenerates"
    /// and "regenerating costs you six minutes a project" are one thought, and
    /// splitting them lets a reader take the first half and stop.
    private var consequence: String {
        let base = aiExplanation?.consequenceOfDeleting ?? item.classification.consequence
        guard let rebuild = aiExplanation.map({ $0.rebuildCost }) ?? item.classification.rebuildCost else {
            return base
        }
        return base + " " + rebuild
    }

    private var personalNote: String? {
        if let entry = model.lastCleanup(of: item.path) {
            return "You cleaned this \(RelativeTime.phrase(entry.performedAt)) — it came back."
        }
        if model.regrownPaths.contains(item.path) {
            return "This came back since the scan before last."
        }
        return nil
    }

    // MARK: - Look inside (F10)

    @ViewBuilder
    private var lookInside: some View {
        VStack(spacing: 0) {
            if model.isLoadingPreview {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Reading the folder…")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else if let preview = model.preview {
                PreviewTable(preview: preview, item: item) { entry in
                    model.drill(into: entry, in: tier)
                }
            }
        }
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Actions

    /// Which buttons exist is the tier's whole meaning made operable. Tier 2 has
    /// no delete action at all — not a disabled one, none — because DiskDrama
    /// reaching into another app's managed storage is something the product does
    /// not do, and a greyed-out button would imply it merely can't right now.
    private var actions: some View {
        HStack(spacing: 8) {
            if item.fileCount > 0 || model.lookInsideOpen {
                Button(model.lookInsideOpen ? "Hide contents" : "Look inside") {
                    withAnimation(Theme.transition) { model.toggleLookInside(for: item) }
                }
                .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
            }

            Button("Reveal in Finder") { FileActions.revealInFinder(path: item.path) }
                .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))

            if tier == .safe {
                let watching = model.isWatching(item)
                Button(watching ? "Watching" : "Watch this") {
                    if watching {
                        if let w = model.watches.first(where: { $0.path == item.path }) {
                            model.unwatch(w)
                        }
                    } else {
                        model.watch(item)
                    }
                }
                .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
            }

            // F17 vs F18. Tier 2 gets the permanent one because DiskDrama can
            // never act on those items anyway — "not now" would just mean
            // "show me the same thing I can't use again next scan".
            if tier == .appManaged {
                neverMenu
            } else {
                Button("Not now") { model.snooze(item) }
                    .buttonStyle(QuietButtonStyle(height: 29))
                neverMenu
            }

            Spacer(minLength: 8)

            trailingAction
        }
    }

    /// Both "stop showing me this" actions, in one control.
    ///
    /// They are easy to confuse and the difference is exactly the one Settings
    /// spells out: ignoring keeps the folder in the totals and merely stops
    /// offering it, while excluding takes it out of the scan altogether, so its
    /// size becomes unknown by design. A button in this row has space for one or
    /// two words — "Never" on its own, which is what was here, says neither of
    /// those things. A menu has the room to say both.
    ///
    /// It also keeps the row the width it already was, rather than adding a
    /// sixth button to a row that is tight at the minimum window size.
    private var neverMenu: some View {
        Menu {
            Button("Never suggest this") { model.dismiss(item) }
            Button("Never look in this folder") { model.exclude(path: item.path) }
        } label: {
            Text("Never…")
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle(height: 29))
        .fixedSize()
        .accessibilityLabel("Never suggest or never scan this folder")
    }

    @ViewBuilder
    private var trailingAction: some View {
        if let app = item.classification.owningApp, let bundleID = app.bundleID {
            Button {
                FileActions.openApp(bundleID: bundleID)
            } label: {
                Label("Open \(app.name)", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 15, fontSize: 12.5))
            .accessibilityLabel("Open \(app.name)")
        } else if tier.allowsDeletion {
            // Accent on every tier, Review included.
            //
            // The resolved HTML drew this one danger-outlined, but that is a
            // defect in the handoff rather than an intention: the README states
            // twice that red is confined to delete confirmations and the
            // low-space alert, and the HTML's own caption on screen 3c says
            // "tiers are told apart by where they sit and what they say, not by
            // colour". Corrected by Ludwig, 2026-08-04.
            //
            // The substantive reason is that the confirm sheet's Trash toggle
            // recolours *its* button to danger when the user turns undo off, and
            // that recolouring is the app's single most important safety signal.
            // Spending red one screen earlier, on a button that only opens a
            // dialog, is what would blunt it.
            Button("Delete \(ByteFormat.compact(item.sizeBytes))…") {
                model.presentDeleteSheet(for: item)
            }
            .buttonStyle(AccentButtonStyle(height: 29, horizontalPadding: 15, fontSize: 12.5))
        }
    }
}

// MARK: - Confidence

/// How the app talks about its own certainty (F09).
///
/// Three bands rather than a percentage. "0.75" invites the reader to do
/// arithmetic they have no basis for; "reasonably confident" is the actual
/// content of the number.
struct ConfidenceBand {
    let label: String
    /// Only high confidence gets the live cyan indicator. Lighting it up for a
    /// low-confidence item would turn a warning into decoration.
    let showsLiveDot: Bool

    init(_ value: Double) {
        switch value {
        case 0.9...:
            label = "high confidence"
            showsLiveDot = true
        case KnowledgeBase.lowConfidenceFloor...:
            label = "reasonably confident"
            showsLiveDot = false
        default:
            label = "low confidence"
            showsLiveDot = false
        }
    }
}

// MARK: - Preview table

/// The "biggest things inside" table (F10), and the way into F13.
private struct PreviewTable: View {
    let preview: DirectoryPreview.Result
    let item: Recommendation
    let onDrill: (DirectoryPreview.Entry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            switch preview.notEnumerated {
            case .tooManyEntries(let count):
                note("About \(ByteFormat.files(count)) in here — too many to list, and that count is itself the problem. "
                     + "A folder this shape slows every backup and every tool that walks your disk.")
            case .unreadable:
                note("I couldn't read inside this folder, so I can't show you what's in it. "
                     + "That usually means it needs Full Disk Access.")
            case nil:
                if preview.entries.isEmpty {
                    note("Nothing inside big enough to list separately.")
                } else {
                    rows
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Eyebrow(text: "Biggest things inside")
            Spacer()
            if preview.totalFileCount > 0 {
                Text(ByteFormat.files(preview.totalFileCount))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(preview.entries) { entry in
                PreviewRow(entry: entry) { onDrill(entry) }
            }
            if preview.remainderCount > 0 {
                HStack(spacing: 14) {
                    Text("\(preview.remainderCount) more")
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    Text(ByteFormat.compact(preview.remainderBytes))
                        .font(Theme.mono(12.5, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 66, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12.5))
            .lineSpacing(3)
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

private struct PreviewRow: View {
    let entry: DirectoryPreview.Entry
    let onDrill: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onDrill) {
            HStack(spacing: 14) {
                Text(entry.name)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let modified = entry.newestModifiedAt {
                    Text(RelativeTime.compact(modified))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text3)
                }
                Text(ByteFormat.compact(entry.sizeBytes))
                    .font(Theme.mono(12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(entry.name), \(ByteFormat.compact(entry.sizeBytes)). Look inside.")
    }
}
