import SwiftUI

/// A04's deletion-mode checkbox — the app's single most important control.
///
/// It appears on every confirmation, pre-set from the global default and
/// adjustable for that job only. Two things about it are not styling details:
///
/// - **The consequence line changes with the state.** Not a static caption
///   about what the checkbox means, but a plain sentence about what will happen
///   if you press the button as things currently stand.
/// - **The primary button changes colour and wording with it** (see
///   `DeleteConfirmSheet`). Turning off the undo is the one moment this app
///   spends red, and the button has to look different from the safe path, not
///   merely say something different.
struct TrashToggle: View {

    @Binding var moveToTrash: Bool
    /// The batch sheet nests this in a bordered container that already has a
    /// border; the single-item sheet needs its own.
    var showsBorder: Bool = true

    var body: some View {
        Button {
            withAnimation(Theme.transition) { moveToTrash.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                checkbox
                VStack(alignment: .leading, spacing: 3) {
                    Text("Move to Trash")
                        .font(Theme.ui(13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(consequence)
                        .font(Theme.body(12.5))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.accent.opacity(0.10))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.accent.opacity(0.38), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: showsBorder ? 9 : 0, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Move to Trash")
        .accessibilityValue(moveToTrash ? "on. \(consequence)" : "off. \(consequence)")
        .accessibilityAddTraits(moveToTrash ? [.isButton, .isSelected] : .isButton)
    }

    /// Stated as an outcome, not as a description of the setting. "Recoverable"
    /// and "there is no undo" are the two facts that decide whether someone
    /// should press the button.
    private var consequence: String {
        moveToTrash
            ? "Recoverable from the Trash. The space frees up when you empty it."
            : "Removed right now. The space frees immediately and there is no undo."
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(moveToTrash ? Theme.accent : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(moveToTrash ? Theme.accent : Theme.hairline2, lineWidth: 1)
            }
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.content)
                    .opacity(moveToTrash ? 1 : 0)
            }
            .frame(width: 17, height: 17)
            .padding(.top, 1)
    }
}

/// The small square tick used for per-item selection in the batch sheet.
struct SelectionTick: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? Theme.accent : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isOn ? Theme.accent : Theme.hairline2, lineWidth: 1)
            }
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.content)
                    .opacity(isOn ? 1 : 0)
            }
            .frame(width: 16, height: 16)
    }
}
