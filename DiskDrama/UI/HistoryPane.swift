import SwiftUI

/// The cleanup log (F22).
///
/// Every row names the mode it ran in. A04's ripples make this load-bearing
/// rather than cosmetic: a Trash-mode job is recoverable and an immediate one is
/// not, and a log that did not distinguish them would have to render undo
/// buttons it cannot honour.
struct HistoryPane: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Cleanup history",
                blurb: "Every cleanup DiskDrama has run for you, oldest tricks and all."
            ) { EmptyView() }

            if let verification = model.lastVerification {
                Callout(text: verification.message,
                        symbol: verification.mode == .trash ? "trash" : "checkmark.circle")
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if model.cleanupLog.isEmpty {
                EmptyPane(
                    title: "No cleanups yet",
                    message: "Anything you delete through DiskDrama is recorded here — what it was, how big it was, and whether it went to the Trash or straight out.",
                    symbol: "clock")
            } else {
                list
            }
        }
    }

    /// States the two figures separately. "Freed" means the volume actually
    /// has the space back; anything still in the Trash does not, however much
    /// nicer one large number would look.
    private var footer: String {
        let count = model.cleanupLog.count
        var text = "\(ByteFormat.compact(model.allTimeFreedBytes)) freed all-time, "
            + "across \(count) cleanup\(count == 1 ? "" : "s")."
        let trashed = model.allTimeTrashedBytes
        if trashed > 0 {
            text += " A further \(ByteFormat.compact(trashed)) is in the Trash — "
                + "that space comes back when you empty it."
        }
        return text
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.cleanupLog) { entry in
                    HistoryRow(entry: entry, blockReason: model.destructiveBlockReason) { Task { await model.undo(entry) } }
                }
                Text(footer)
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

private struct HistoryRow: View {
    let entry: CleanupEntry
    /// A restore writes the folder back while the walk may be counting its
    /// parent — the same integrity problem as a deletion, in reverse.
    var blockReason: String? = nil
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(Theme.ui(13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(RelativeTime.phrase(entry.performedAt)) · \(outcomePhrase)")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            // F16: undo exists only for Trash-mode jobs that are still there.
            // An immediate deletion renders *no* button rather than a disabled
            // one — a greyed-out Undo implies the data is recoverable and just
            // isn't right now, which is the opposite of true.
            if entry.isRestorable {
                Button("Put back", action: onUndo)
                    .buttonStyle(GhostButtonStyle(height: 24, horizontalPadding: 10, fontSize: 12))
                    .blockedWhile(blockReason)
            }

            Text(ByteFormat.compact(entry.sizeBytes))
                .font(Theme.mono(13.5, weight: .semibold))
                .foregroundStyle(entry.restoredAt == nil ? Theme.text : Theme.text3)
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var symbol: String {
        switch entry.outcome {
        case .restored: "arrow.uturn.backward"
        case .failed:   "exclamationmark.triangle"
        case .partial:  "trash.slash"
        case .succeeded: entry.mode == .trash ? "trash" : "trash.slash"
        }
    }

    /// States the mode plainly. "Moved to Trash" and "deleted permanently" are
    /// different facts about the user's data and the log is where they go to
    /// check which one happened.
    private var outcomePhrase: String {
        if entry.restoredAt != nil { return "restored" }
        switch entry.outcome {
        case .failed:  return "failed"
        case .partial: return entry.mode == .trash ? "partly moved to Trash" : "partly deleted"
        default:       return entry.mode == .trash ? "moved to Trash" : "deleted permanently"
        }
    }
}
