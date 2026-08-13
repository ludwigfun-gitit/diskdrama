import SwiftUI

/// F14's confirmation.
///
/// States exactly what will be removed, how big it is, and what happens
/// afterwards — the last drawn from F09's explanation, so the sentence that
/// convinced the user to consider deleting it is the same sentence in front of
/// them when they commit.
struct DeleteConfirmSheet: View {

    @Bindable var model: AppModel
    let item: Recommendation
    let onScan: () -> Void

    @State private var isWorking = false

    private var mode: DeletionMode { model.moveToTrash ? .trash : .immediate }

    /// Guards run here too, so the sheet cannot offer a button that the service
    /// would refuse. Same function the service calls — not a second
    /// approximation of the rules that could drift out of step with it.
    private var refusal: DeletionService.Refusal? {
        DeletionService.guardPath(item.path)
    }

    /// Focus target for the sheet.
    ///
    /// Without this the first focusable control takes it, which is the Trash
    /// checkbox — so return committed nothing and the highlighted control was a
    /// toggle. Finder's Empty Trash and the system's other destructive
    /// confirmations focus the destructive button, and this now matches.
    private enum Field: Hashable { case confirm }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 14) {
                // Red on the icon chip regardless of mode: this dialog is the
                // destructive moment, and the handoff permits danger colour in
                // exactly two places, of which this is one.
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 36, height: 36)
                    .background(Theme.danger.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    Text("Delete \(item.classification.title)?")
                        .font(Theme.display(16.5))
                        .foregroundStyle(Theme.text)
                    Text(summary)
                        .font(Theme.body(13.5))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let refusal {
                Callout(text: refusal.errorDescription ?? "DiskDrama won't delete that.",
                        symbol: "hand.raised")
            } else {
                TrashToggle(moveToTrash: $model.moveToTrash)
            }

            if let error = model.deletionError {
                Callout(text: error, symbol: "exclamationmark.triangle")
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { model.activeSheet = nil }
                    .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 16, fontSize: 13.5))
                    .disabled(isWorking)

                if model.deletionNeedsRescan {
                    // The delete cannot succeed until the figures are current,
                    // so this is the only button that can change anything. F14's
                    // refusal was already right; what was missing was somewhere
                    // for the user to go after it.
                    Button("Rescan") {
                        model.activeSheet = nil
                        onScan()
                    }
                    .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
                    .focused($focus, equals: .confirm)
                } else {
                Button(action: confirm) {
                    if isWorking {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    } else {
                        Text(confirmLabel)
                    }
                }
                // The one place the button itself turns red. Wording changes
                // too — "Move to Trash" and "Delete permanently" are different
                // promises and must not look alike.
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5,
                                               isDestructive: !model.moveToTrash))
                .focused($focus, equals: .confirm)
                .disabled(isWorking || refusal != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        // Destructive primary, not the first focusable control — which was the
        // Trash checkbox, so return toggled a setting instead of confirming.
        .defaultFocus($focus, .confirm)
        .background(Theme.panel)
    }

    /// Size, scope, and the consequence from F09 — the same text the panel
    /// showed, not a shorter paraphrase written for the dialog.
    private var summary: String {
        var sentence = "\(ByteFormat.compact(item.sizeBytes))"
        if item.fileCount > 0 {
            sentence += " across \(ByteFormat.files(item.fileCount))"
        }
        sentence += ". " + item.classification.consequence
        if let rebuild = item.classification.rebuildCost {
            sentence += " " + rebuild
        }
        return sentence
    }

    private var confirmLabel: String {
        model.moveToTrash
            ? "Move \(ByteFormat.compact(item.sizeBytes)) to Trash"
            : "Delete \(ByteFormat.compact(item.sizeBytes)) permanently"
    }

    private func confirm() {
        isWorking = true
        let freeBefore = model.disk.info?.strictAvailableBytes ?? 0
        let mode: DeletionMode = model.moveToTrash ? .trash : .immediate
        Task {
            let succeeded = await model.delete(item)
            if succeeded {
                model.verify(expected: item.sizeBytes, mode: mode, freeBefore: freeBefore)
            }
            isWorking = false
            // Stay open on failure so the reason is readable — closing the
            // sheet on a refusal would leave the user with nothing but an
            // unchanged list and no explanation.
            if succeeded { model.activeSheet = nil }
        }
    }
}
