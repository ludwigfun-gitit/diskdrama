import SwiftUI

/// F23's "Get me to…" sheet.
struct TargetSheet: View {

    @Bindable var model: AppModel

    @State private var targetGB: Double = 0
    @State private var isWorking = false

    private var currentFree: Int64 { model.disk.info?.availableBytes ?? 0 }
    private var totalBytes: Int64 { model.disk.info?.totalBytes ?? 0 }

    private var plan: TargetPlan? {
        guard let set = model.recommendations else { return nil }
        return TargetPlan.build(target: Int64(targetGB * 1_000_000_000),
                                currentFree: currentFree,
                                from: set,
                                excluding: model.ignoredPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let plan {
                content(plan)
            } else {
                EmptyPane(title: "Nothing scanned yet",
                          message: "Run a scan first and I can work out how to get you there.",
                          symbol: "target")
                    .frame(height: 200)
            }
            Divider()
            footer
        }
        .frame(width: 580)
        .background(Theme.panel)
        .onAppear {
            // Start somewhere useful rather than at zero: a round number
            // comfortably above where they are now.
            let currentGB = Double(currentFree) / 1_000_000_000
            targetGB = (currentGB * 1.5 / 10).rounded(.up) * 10
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Get me to").font(Theme.display(17)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Text("\(Int(targetGB))")
                        .font(Theme.mono(15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("GB free").font(Theme.ui(13)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.accent.opacity(0.38), lineWidth: 1))
                Spacer()
            }

            Slider(value: $targetGB,
                   in: 0...max(Double(totalBytes) / 1_000_000_000, 1),
                   step: 5)
                .tint(Theme.accent)

            if let plan {
                progressBar(plan)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    /// Two segments: what is already free, and what the plan would add. Showing
    /// them separately is the difference between "you'd get there" and "you're
    /// already most of the way there".
    private func progressBar(_ plan: TargetPlan) -> some View {
        let scale = max(Double(plan.targetBytes), 1)
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.text3)
                        .frame(width: geo.size.width * min(Double(plan.currentFreeBytes) / scale, 1))
                    Rectangle().fill(Theme.accent)
                        .frame(width: geo.size.width * min(Double(plan.plannedBytes) / scale, 1))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Theme.track)
            .clipShape(Capsule())

            HStack {
                Text("\(ByteFormat.compact(plan.currentFreeBytes)) free now, plus "
                     + "\(ByteFormat.compact(plan.plannedBytes)) from the plan below")
                    .font(Theme.body(13)).foregroundStyle(Theme.text2)
                Spacer()
                Text("\(ByteFormat.compact(plan.projectedFreeBytes)) / \(ByteFormat.compact(plan.targetBytes))")
                    .font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
            }
        }
    }

    private func content(_ plan: TargetPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(plan.steps) { step in
                    HStack(spacing: 12) {
                        // Actionable steps get a tick; the others get an empty
                        // box, because the app is not going to do them.
                        if step.isActionable {
                            SelectionTick(isOn: true)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.hairline2, lineWidth: 1)
                                .frame(width: 16, height: 16)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.item.classification.title)
                                .font(Theme.ui(13.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(step.note).font(Theme.body(12)).foregroundStyle(Theme.text3)
                        }
                        Spacer(minLength: 8)
                        Text(ByteFormat.compact(step.item.sizeBytes))
                            .font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .opacity(step.isActionable ? 1 : 0.62)
                }

                if !plan.isReachable {
                    unreachableNotice(plan)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(maxHeight: 280)
    }

    /// The one place besides the delete confirmation and the low-space alert
    /// where danger colour is warranted — it marks a promise the app *cannot*
    /// keep, which is exactly the kind of thing that should stop the eye.
    private func unreachableNotice(_ plan: TargetPlan) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.danger)
                .padding(.top, 1)
            Text(unreachableText(plan))
                .font(Theme.body(13)).lineSpacing(3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.danger.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(Theme.danger, lineWidth: 1))
    }

    private func unreachableText(_ plan: TargetPlan) -> String {
        var text = "\(ByteFormat.compact(plan.targetBytes)) isn't reachable. "
            + "Taking everything I'd advise lands you at \(ByteFormat.compact(plan.projectedFreeBytes)) — "
            + "\(ByteFormat.compact(plan.shortfallBytes)) short."
        if !plan.notOffered.isEmpty {
            let names = plan.notOffered.map { "\($0.name) (\(ByteFormat.compact($0.sizeBytes)))" }
            text += " The rest of the disk is \(names.joined(separator: " and "))"
                + " — I'm not going to suggest you delete either."
        }
        return text
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Spacer()
            Button("Cancel") { model.activeSheet = nil }
                .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 16, fontSize: 13.5))
                .disabled(isWorking)

            Button(action: run) {
                if isWorking {
                    HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Working…") }
                } else {
                    Text(plan.map { "Run this plan — \(ByteFormat.compact($0.actionableBytes))" }
                         ?? "Run this plan")
                }
            }
            .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
            .blockedWhile(model.actionBlockReason)
            .disabled(isWorking || (plan?.actionableBytes ?? 0) == 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// Executes only the actionable steps, through the same deletion path as
    /// everything else — F23 defers to F14/F15 semantics rather than having a
    /// private route to the filesystem.
    private func run() {
        guard let plan else { return }
        isWorking = true
        Task {
            await model.deleteBatch(plan.steps.filter(\.isActionable).map(\.item))
            isWorking = false
            model.activeSheet = nil
        }
    }
}
