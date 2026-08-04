import SwiftUI
import AppKit

/// F05 — first launch.
///
/// Three steps, and the middle one is the reason this exists. Step 7 established
/// that **without Full Disk Access the App-managed tier is empty in practice** —
/// the storage other apps own lives almost entirely in TCC-protected locations.
/// So the permission ask is not boilerplate here; it is the difference between
/// the app working and the app being a partial view that never says why.
///
/// Two rules the design is explicit about, and both are load-bearing:
///
/// - **Explain before asking.** The reason comes first, then the button. A
///   permission prompt with no stated reason is how you earn a permanent no.
/// - **Skipping is easy and non-threatening.** Reduced mode is a real supported
///   state, not a punishment — the app says what it cannot see rather than
///   guessing, and the banner offers the walkthrough again later.
struct OnboardingSheet: View {

    @Bindable var model: AppModel
    let onScan: () -> Void

    @State private var step = 0
    @State private var hasAccess = FullDiskAccess.isGranted()
    /// Polls while the sheet is open so the grant is noticed the moment it
    /// happens — "I'll notice the moment you grant it" has to be true.
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Step \(step + 1) of 3")
                .font(Theme.ui(12, weight: .semibold))
                .tracking(1.6).textCase(.uppercase)
                .foregroundStyle(Theme.accent)

            switch step {
            case 0:  welcome
            case 1:  fullDiskAccess
            default: firstScan
            }

            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 38)
        .frame(width: 700, height: 520)
        .background(Theme.content)
        .onAppear(perform: startPolling)
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("I find the space, you decide")
                .font(Theme.display(28))
                .foregroundStyle(Theme.text)
            Text("DiskDrama looks through the places you point it at, works out what's actually "
                 + "safe to delete, and tells you why. It sorts everything into three tiers so you "
                 + "never have to guess whether a folder is build junk or the only copy of something.")
                .font(Theme.body(15)).lineSpacing(5)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)

            HStack(spacing: 14) {
                reassurance("What I do",
                            "Read file sizes. Locally. Nothing leaves this Mac, and there's no account to make.")
                reassurance("What I never do",
                            "Delete anything you didn't ask me to delete. Not on a schedule, not automatically, not ever.")
            }
            .padding(.top, 8)
        }
    }

    private var fullDiskAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Let me see the whole picture")
                .font(Theme.display(28))
                .foregroundStyle(Theme.text)
            Group {
                Text("Most of the space you can actually get back hides in ")
                + Text("~/Library").font(Theme.mono(13.5))
                + Text(". Without Full Disk Access I'll still work — I'll just tell you what I "
                       + "couldn't see instead of guessing.")
            }
            .font(Theme.body(15)).lineSpacing(5)
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)

            accessStatus.padding(.top, 10)
        }
    }

    private var firstScan: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasAccess ? "Ready when you are" : "Ready — with a few blind spots")
                .font(Theme.display(28))
                .foregroundStyle(Theme.text)
            Text(hasAccess
                 ? "I'll walk your home folder and sort what I find. It usually takes a few seconds, "
                   + "and nothing is deleted or changed by scanning."
                 : "I'll scan what I can reach and mark everything I couldn't as a blind spot, so you "
                   + "always know the totals are a floor rather than the whole picture. You can grant "
                   + "access later from Settings.")
                .font(Theme.body(15)).lineSpacing(5)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    // MARK: - Pieces

    private func reassurance(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text(body).font(Theme.body(13)).lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
    }

    private var accessStatus: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(hasAccess ? Theme.accent : Theme.glow)
                .frame(width: 8, height: 8)
                .shadow(color: hasAccess ? Theme.accent : Theme.glow, radius: 4)
            Text(hasAccess
                 ? "Access granted — I can see everything now."
                 : "Waiting for access — I'll notice the moment you grant it.")
                .font(Theme.body(13.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if !hasAccess {
                Button {
                    FullDiskAccess.openSystemSettings()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(AccentButtonStyle(height: 30, horizontalPadding: 14))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .background(Theme.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(Theme.accent.opacity(0.38), lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if step == 1 && !hasAccess {
                Text("You can skip this and grant it later from Settings.")
                    .font(Theme.body(13)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(QuietButtonStyle(height: 32))
            }
            Button(primaryLabel) {
                if step < 2 {
                    step += 1
                } else {
                    finish()
                }
            }
            .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
        }
    }

    private var primaryLabel: String {
        switch step {
        case 0:  "Get started"
        case 1:  hasAccess ? "Continue" : "Skip for now"
        default: "Run the first scan"
        }
    }

    private func finish() {
        Settings.shared.hasCompletedOnboarding = true
        model.isShowingOnboarding = false
        onScan()
    }

    /// Notices a grant made in System Settings while this sheet is open. TCC
    /// gives no notification, so polling is the only way — twice a second, one
    /// cheap read, and only while the sheet is up.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let granted = FullDiskAccess.isGranted()
                if granted != hasAccess {
                    withAnimation(Theme.transition) { hasAccess = granted }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
