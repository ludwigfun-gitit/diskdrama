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
                // The cyan is deliberately ~40° of hue from the accent so a
                // confidence signal never reads as a button.
                Circle()
                    .fill(Theme.glow)
                    .frame(width: 5, height: 5)
                    .shadow(color: Theme.glow, radius: 2.5)
                Text(confidence.label)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.glow)
            } else {
                Text(confidence.label)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private var metadataText: String {
        var parts = [ByteFormat.compact(item.sizeBytes)]
        if item.fileCount > 0 {
            parts.append("\(ByteFormat.count(item.fileCount)) files")
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

    private var confidence: ConfidenceBand {
        ConfidenceBand(item.classification.confidence)
    }

    // MARK: - Explanation

    /// Two columns: what it is, then what happens if it goes. The split is the
    /// design's and it maps exactly onto the two questions a person actually has,
    /// in the order they have them.
    private var explanation: some View {
        HStack(alignment: .top, spacing: 30) {
            Text(item.classification.whatThisIs)
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
        guard let rebuild = item.classification.rebuildCost else {
            return item.classification.consequence
        }
        return item.classification.consequence + " " + rebuild
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
                Button("Watch this") {}
                    .buttonStyle(GhostButtonStyle(height: 29, fontSize: 12.5))
                    .disabled(true)   // F21 — Step 11
            }

            Button(tier == .appManaged ? "Never suggest this" : "Not now") {}
                .buttonStyle(QuietButtonStyle(height: 29))
                .disabled(true)       // F17/F18 — Step 10

            Spacer(minLength: 8)

            trailingAction
        }
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
            Button("Delete \(ByteFormat.compact(item.sizeBytes))…") {}
                .buttonStyle(DeleteButtonStyle(isCautioned: tier == .reviewFirst))
                .disabled(true)       // F14 — Step 9
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
                note("About \(ByteFormat.count(count)) files in here — too many to list, and that count is itself the problem. "
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
                Text("\(ByteFormat.count(preview.totalFileCount)) files")
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

// MARK: - Delete button

/// The delete affordance.
///
/// Tier 1 is a normal accent button; Tier 3 is outlined in the danger color, per
/// the resolved design. Note this is the *opener* — the confirmation behind it is
/// where the Trash toggle lives and where the real safety decision is made.
struct DeleteButtonStyle: ButtonStyle {
    let isCautioned: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 15)
            .frame(height: 29)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .stroke(isCautioned ? Theme.danger : .clear, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.transition, value: configuration.isPressed)
            .animation(Theme.transition, value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        guard isCautioned else { return .white }
        return isHovering && isEnabled ? .white : Theme.danger
    }

    private var background: Color {
        guard isCautioned else { return Theme.accent }
        return isHovering && isEnabled ? Theme.danger : .clear
    }
}
