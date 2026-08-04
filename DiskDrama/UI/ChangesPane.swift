import SwiftUI

/// What changed since the last scan (F20).
///
/// This view exists to answer one question, not to be a diff: *is this a new
/// problem, or the same one again?* Regrowth is therefore the whole headline and
/// ordinary growth sits below it, rather than the two being interleaved by size.
struct ChangesPane: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Changes since last scan",
                blurb: "What grew back since you last cleaned it — same folders, back again."
            ) { EmptyView() }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasNeverScanned {
            EmptyPane(
                title: "Nothing to compare yet",
                message: "Run a scan and I'll start tracking what comes back.",
                symbol: "clock.arrow.circlepath")
        } else if let delta = model.delta {
            if delta.isEmpty {
                EmptyPane(
                    title: "Nothing meaningful changed",
                    message: "Nothing crossed the threshold worth reporting between the last two scans.",
                    symbol: "equal.circle")
            } else {
                list(delta)
            }
        } else {
            // F20 is explicit that this is a different statement from "nothing
            // changed", and the two must not render the same way.
            EmptyPane(
                title: "First scan",
                message: "There's nothing to compare this against yet. After your next scan this is where regrowth shows up.",
                symbol: "clock.arrow.circlepath")
        }
    }

    private func list(_ delta: Delta) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(delta.regrown) { change in
                    ChangeRow(change: change, isRegrowth: true)
                }
                ForEach(otherChanges(delta)) { change in
                    ChangeRow(change: change, isRegrowth: false)
                }

                if !delta.regrown.isEmpty {
                    Callout(text: regrowthNote(count: delta.regrown.count))
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Everything that moved but did not come back from nothing, biggest change
    /// first regardless of direction — a 9 GB shrink is as worth seeing as a 9 GB
    /// growth.
    private func otherChanges(_ delta: Delta) -> [Delta.Change] {
        let regrown = Set(delta.regrown.map(\.path))
        return (delta.appeared + delta.grew + delta.shrank + delta.disappeared)
            .filter { !regrown.contains($0.path) }
            .sorted { abs($0.deltaBytes) > abs($1.deltaBytes) }
    }

    private func regrowthNote(count: Int) -> String {
        count == 1
            ? "This one came all the way back since you last cleaned it. Same tools, same habits — worth a watch if you don't want to keep repeating this."
            : "These \(count) came all the way back since you last cleaned them. Same tools, same habits — worth a watch if you don't want to keep repeating this."
    }
}

/// `0 GB → 21.4 GB` with the direction as an arrow.
///
/// The arrow carries accent only for regrowth. An ordinary increase is
/// information; a folder you already cleaned refilling is the thing this app
/// exists to catch, and the two should not look alike.
private struct ChangeRow: View {
    let change: Delta.Change
    let isRegrowth: Bool

    private var isIncrease: Bool { change.deltaBytes >= 0 }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.name)
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(PathDisplay.short(change.path))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Text(ByteFormat.compact(change.previousBytes))
                    .foregroundStyle(Theme.text3)
                Image(systemName: isIncrease ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isRegrowth ? Theme.accent : Theme.text3)
                Text(ByteFormat.compact(change.currentBytes))
                    .fontWeight(.bold)
                    .foregroundStyle(isRegrowth ? Theme.accent : Theme.text)
            }
            .font(Theme.mono(13))
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
