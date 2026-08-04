import SwiftUI

/// F15 — batch approval, Tier 1 only (A08).
///
/// Everything starts checked, because everything on this tier regenerates and
/// the default is the whole job. The user unchecks what they would rather keep,
/// and the total moves as they do — so the number on the button is always the
/// number they are about to act on.
struct BatchCleanSheet: View {

    @Bindable var model: AppModel
    let tier: Tier

    @State private var selected: Set<String> = []
    @State private var isWorking = false
    @State private var progress: Int = 0

    private var items: [Recommendation] { model.items(in: tier) }
    private var chosen: [Recommendation] { items.filter { selected.contains($0.path) } }
    private var totalBytes: Int64 { chosen.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            box
            totals
            actions
        }
        .frame(width: 540)
        .background(Theme.panel)
        .onAppear { selected = Set(items.map(\.path)) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clean all \(items.count) safe items?")
                .font(Theme.display(17))
                .foregroundStyle(Theme.text)
            Text("Every one of these regenerates on its own. Uncheck anything you'd rather keep.")
                .font(Theme.body(13.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var box: some View {
        VStack(spacing: 0) {
            // The mode toggle sits above the list, not beside the button: it
            // governs the whole job and has to be read before the items, not
            // discovered next to the thing that commits them.
            TrashToggle(moveToTrash: $model.moveToTrash, showsBorder: false)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.path != items.last?.path {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private func row(_ item: Recommendation) -> some View {
        Button {
            if selected.contains(item.path) { selected.remove(item.path) }
            else { selected.insert(item.path) }
        } label: {
            HStack(spacing: 11) {
                SelectionTick(isOn: selected.contains(item.path))
                Text(item.classification.title)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ByteFormat.compact(item.sizeBytes))
                    .font(Theme.mono(12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("\(item.classification.title), \(ByteFormat.compact(item.sizeBytes))")
        .accessibilityAddTraits(selected.contains(item.path) ? [.isButton, .isSelected] : .isButton)
    }

    private var totals: some View {
        HStack {
            Text("\(chosen.count) of \(items.count) selected")
                .font(Theme.body(13))
                .foregroundStyle(Theme.text2)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Total").font(Theme.ui(13)).foregroundStyle(Theme.text2)
                Text(ByteFormat.compact(totalBytes))
                    .font(Theme.mono(19, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.deletionError {
                Callout(text: error, symbol: "exclamationmark.triangle")
            }
            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { model.activeSheet = nil }
                    .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 16, fontSize: 13.5))
                    .disabled(isWorking)

                Button(action: run) {
                    if isWorking {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("\(progress) of \(chosen.count)…")
                        }
                    } else {
                        Text(model.moveToTrash
                             ? "Move \(chosen.count) to Trash"
                             : "Delete \(chosen.count) permanently")
                    }
                }
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5,
                                               isDestructive: !model.moveToTrash))
                .disabled(isWorking || chosen.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private func run() {
        isWorking = true
        progress = 0
        let batch = chosen
        Task {
            // One at a time, not concurrently. A parallel sweep would be faster
            // and would also make a partial failure much harder to describe —
            // F14/F15 require reporting exactly what remains, and sequential
            // execution is what makes "it stopped here" a true statement.
            for item in batch {
                await model.delete(item, batchID: batchIdentifier)
                progress += 1
            }
            isWorking = false
            model.activeSheet = nil
        }
    }

    /// Stable for the lifetime of this sheet, so every item in one press of the
    /// button shares a batch ID and the log can summarise the job.
    @State private var batchIdentifier = UUID()
}
