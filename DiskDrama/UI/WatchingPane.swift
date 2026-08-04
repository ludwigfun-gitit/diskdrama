import SwiftUI

/// F21 — the known offenders.
///
/// This is the hygiene loop's memory. A watch says "I have cleaned this before
/// and expect to again", and the app takes on the job of noticing rather than
/// leaving the user to remember.
struct WatchingPane: View {

    @Bindable var model: AppModel

    private var active: [WatchedPath] { model.watches.filter(\.isActive) }
    private var retired: [WatchedPath] { model.watches.filter { !$0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Watching",
                blurb: "Folders you've cleaned before. When one grows back to roughly the size it "
                     + "was when you last dealt with it, DiskDrama says so."
            ) { EmptyView() }

            if model.watches.isEmpty {
                EmptyPane(
                    title: "Nothing on watch",
                    message: "Use \"Watch this\" on anything that keeps coming back. "
                           + "You'll get told when it does, instead of finding out when the disk fills up.",
                    symbol: "eye")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(active, id: \.path) { watch in
                    row(watch, isRetired: false)
                }
                if !retired.isEmpty {
                    Text("Retired")
                        .font(Theme.eyebrow()).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2).padding(.top, 18).padding(.bottom, 6)
                    ForEach(retired, id: \.path) { watch in
                        row(watch, isRetired: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func row(_ watch: WatchedPath, isRetired: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: isRetired ? "eye.slash" : "eye")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isRetired ? Theme.text3 : Theme.accent)
                .frame(width: 26, height: 26)
                .background((isRetired ? Theme.text3 : Theme.accent).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(watch.name)
                    .font(Theme.ui(13.5, weight: .semibold))
                    .foregroundStyle(isRetired ? Theme.text2 : Theme.text)
                    .lineLimit(1)
                Text(subtitle(watch, isRetired: isRetired))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if !isRetired {
                Button("Stop watching") { model.unwatch(watch) }
                    .buttonStyle(QuietButtonStyle(height: 24, fontSize: 11.5))
            }

            Text(ByteFormat.compact(watch.thresholdBytes))
                .font(Theme.mono(13.5, weight: .semibold))
                .foregroundStyle(isRetired ? Theme.text3 : Theme.text)
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    /// States the threshold in words, because "21.4 GB" on its own doesn't say
    /// whether that is the trigger or the current size.
    private func subtitle(_ watch: WatchedPath, isRetired: Bool) -> String {
        if isRetired {
            return "Retired — \(watch.retiredReason ?? "no longer being watched")"
        }
        var text = "Tells you when it passes \(ByteFormat.compact(watch.thresholdBytes))"
        if let notified = watch.lastNotifiedAt {
            text += " · last flagged \(RelativeTime.phrase(notified))"
        }
        return text
    }
}
