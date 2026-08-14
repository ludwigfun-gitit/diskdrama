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

    @State private var step = Settings.shared.onboardingStep
    @State private var hasAccess = FullDiskAccess.isGranted()
    /// Set once the user has been sent to System Settings, so the sheet can tell
    /// "hasn't started yet" apart from "granted it and nothing happened".
    @State private var didOpenSettings = false
    @State private var startAtLogin = LoginItem.isEnabled
    /// Job 2's answers. Defaulted, never blank — a prefilled value reads as a
    /// recommendation, and it turns "fill this in" into "check this over".
    @State private var primaryUse = Settings.shared.primaryUse
    @State private var lowThresholdGB = Int(Settings.shared.lowThresholdBytes / 1_000_000_000)
    /// Set when the scan is kicked off, so the reveal step starts it exactly once.
    @State private var startedScan = false
    /// Polls while the sheet is open so the grant is noticed the moment it
    /// happens — "I'll notice the moment you grant it" has to be true.
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Step \(step + 1) of 4")
                .font(Theme.ui(12, weight: .semibold))
                .tracking(1.6).textCase(.uppercase)
                .foregroundStyle(Theme.accent)

            switch step {
            case 0:  welcome
            case 1:  guidingQuestions
            case 2:  fullDiskAccess
            default: reveal
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

    /// **Job 2 — personalize.** Before the ask, because after it the user has
    /// already spent the expensive decision and a questionnaire reads as a toll.
    ///
    /// Two questions, both defaulted, both consequential. Q1 picks the tier the
    /// app opens on and the emphasis of the reveal; Q2 sets the free-space
    /// threshold the menu-bar item actually warns at. Neither is a placebo —
    /// a question whose answer changes nothing retroactively devalues the ones
    /// that mattered.
    private var guidingQuestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two questions, then I'll get out of the way")
                .font(Theme.display(28))
                .foregroundStyle(Theme.text)
            Text("Both are already answered with the common case — change them if they're wrong.")
                .font(Theme.body(15)).lineSpacing(5)
                .foregroundStyle(Theme.text2)

            VStack(alignment: .leading, spacing: 8) {
                Text("What mostly fills this Mac?")
                    .font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    choice("Development", "dev", "Build folders, caches, simulators")
                    choice("Photos and video", "media", "Libraries, exports, footage")
                    choice("A bit of everything", "everything", "The usual mix")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tell me when free space drops below")
                    .font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    ForEach([10, 20, 50], id: \.self) { gb in
                        // One style with a selected state rather than two styles
                        // swapped: `buttonStyle` takes a concrete type, and
                        // branching between two of them needs an existential the
                        // codebase doesn't have. A tinted background says the
                        // same thing with less machinery.
                        Button("\(gb) GB") { lowThresholdGB = gb }
                            .buttonStyle(GhostButtonStyle(height: 30, horizontalPadding: 14, fontSize: 13))
                            .overlay {
                                if lowThresholdGB == gb {
                                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                        .fill(Theme.accent.opacity(0.16))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                            .stroke(Theme.accent.opacity(0.55), lineWidth: 1))
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    Text("The menu bar turns orange there, red at a quarter of it.")
                        .font(Theme.body(12)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private func choice(_ label: String, _ value: String, _ detail: String) -> some View {
        Button {
            primaryUse = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(Theme.ui(13, weight: .semibold))
                Text(detail).font(Theme.body(11.5)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(primaryUse == value ? Theme.accent.opacity(0.12) : Theme.hover,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(primaryUse == value ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
            .foregroundStyle(primaryUse == value ? Theme.accent : Theme.text)
        }
        .buttonStyle(.plain)
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
            stubbornAccessHelp
        }
    }

    /// **Jobs 3 and 4 — FOMO and the gotcha**, after the ask because before it
    /// there is nothing true to say.
    ///
    /// This is the structural advantage a local-first app has and a competitor
    /// cannot copy with better copywriting: the payoff is manufactured from data
    /// the user already owns, within a minute of install. Everyone else sells a
    /// projected future and asks you to imagine it.
    ///
    /// Two traps the skill records, both avoided here deliberately:
    ///
    /// - **Advance on completion, never on a count.** The reveal reads aggregate
    ///   totals, so a threshold fires it against a half-populated result and
    ///   undersells the app at the exact moment it is meant to astonish.
    /// - **Never display a literal zero.** The walk enumerates for seconds before
    ///   it can report per-file progress, and "0" there reads as broken while you
    ///   are building momentum. The phase gets named instead.
    @ViewBuilder
    private var reveal: some View {
        if model.scanEngine.isRunning || model.recommendations == nil {
            scanning
        } else {
            found
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Having a look…")
                .font(Theme.display(28)).foregroundStyle(Theme.text)
            Text(model.scanProgressFraction == nil
                 ? "Reading through your folders. Nothing is being changed or deleted."
                 : "Sorting what I found. Nothing is being changed or deleted.")
                .font(Theme.body(15)).lineSpacing(5).foregroundStyle(Theme.text2)
            ScanProgressLine(fraction: model.scanProgressFraction,
                             isStalled: model.scanEngine.stall != nil)
                .padding(.top, 6)
        }
    }

    /// Loss framing from real numbers, then the Pro moment — never before it.
    ///
    /// Degrades by omission rather than by zeros: a thin result skips the
    /// spectacle entirely and says something plainer, because "0 items found" at
    /// the moment you are trying to impress is worse than not trying.
    private var found: some View {
        let bytes = model.totalReclaimableBytes
        let biggest = model.topConsumers.first
        return VStack(alignment: .leading, spacing: 12) {
            if bytes > 0 {
                Text("\(ByteFormat.compact(bytes)) you can get back")
                    .font(Theme.display(28)).foregroundStyle(Theme.text)
                Text(revealBody(biggest: biggest))
                    .font(Theme.body(15)).lineSpacing(5).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
            } else {
                Text("Nothing worth deleting")
                    .font(Theme.display(28)).foregroundStyle(Theme.text)
                Text("I went through your home folder and found nothing I'd advise removing. "
                     + "That's a good result — I'll keep watching, and say so when that changes.")
                    .font(Theme.body(15)).lineSpacing(5).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            loginItemOffer.padding(.top, 6)
        }
    }

    /// The user's own numbers, so the copy does not have to strain.
    ///
    /// Loss framing is emphasis, not invention: every figure here is one the app
    /// has measured and will keep showing. The trial end date is stated because
    /// it is real — a countdown to a genuine deadline is loss framing, a
    /// countdown to a manufactured one is a dark pattern.
    private func revealBody(biggest: (name: String, sizeBytes: Int64)?) -> String {
        var sentence = ""
        if let biggest {
            sentence += "The biggest single thing is \(biggest.name), at \(ByteFormat.compact(biggest.sizeBytes)). "
        }
        sentence += "You couldn't see any of this an hour ago. Everything DiskDrama found stays visible for good — "
        sentence += "the ten-day trial is about being able to act on it."
        return sentence
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

            loginItemOffer.padding(.top, 12)
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
            GlowDot(size: 8, color: hasAccess ? Theme.accent : Theme.glow)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasAccess
                     ? "Access granted — I can see everything now."
                     : "Waiting for access — I'll notice the moment you grant it.")
                    .font(Theme.body(13.5)).foregroundStyle(Theme.text)
                // Said before macOS says otherwise, because its dialog is
                // misleading here twice over: the restart is unnecessary — this
                // checks by trying to read a protected folder, so a grant
                // registers within half a second — and on a menu-bar app the
                // "Quit & Reopen" button frequently does not quit anything.
                // Watching nothing happen after choosing it reads as a failure,
                // at the exact moment the thing has in fact worked.
                if !hasAccess {
                    Text("macOS may offer to quit and reopen DiskDrama. You don't have to — I check by reading, "
                         + "not by restarting, so I'll see the grant either way.")
                        .font(Theme.body(12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !hasAccess {
                Button {
                    didOpenSettings = true
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

    /// macOS offers "Quit & Reopen" when Full Disk Access is granted to a running
    /// app, and that dialog does not always succeed — a modal sheet can swallow
    /// the termination. When it doesn't, the user is left with a permission they
    /// granted, an app that cannot use it, and nothing on screen admitting
    /// either. So the app offers its own relaunch, which it can guarantee.
    @ViewBuilder
    private var stubbornAccessHelp: some View {
        if didOpenSettings && !hasAccess {
            HStack(spacing: 11) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                Text("Granted it and still nothing? macOS often needs the app restarted before a new permission applies. "
                     + "If you told macOS to \"Quit & Reopen\" and it didn't, this will — and you'll come back to this step.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Relaunch DiskDrama") {
                    // Belt and braces: the step is already persisted on every
                    // move, but this is the one path that deliberately kills the
                    // process, so it writes before it goes.
                    Settings.shared.onboardingStep = step
                    Relauncher.relaunch()
                }
                    .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 12, fontSize: 12.5))
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1))
        }
    }

    /// Asked, not assumed. A monitor that only runs when you remember to open it
    /// is not a monitor — the low-space alert matters precisely when nobody is
    /// thinking about launching a cleanup tool — but registering a login item
    /// without saying so changes what someone's Mac does at startup behind their
    /// back.
    private var loginItemOffer: some View {
        HStack(spacing: 11) {
            SelectionTick(isOn: startAtLogin)
            VStack(alignment: .leading, spacing: 3) {
                Text("Start DiskDrama when I log in")
                    .font(Theme.ui(13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(LoginItem.needsApproval
                     ? "macOS wants you to confirm this in Login Items before it takes effect."
                     : "It sits in the menu bar and watches free space. It can't warn you about a full disk if it isn't running.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if LoginItem.needsApproval {
                Button("Open Login Items") { LoginItem.openSystemSettings() }
                    .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 12, fontSize: 12.5))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            startAtLogin.toggle()
            if !LoginItem.setEnabled(startAtLogin) { startAtLogin = LoginItem.isEnabled }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if step == 1 && !hasAccess {
                Text("You can skip this and grant it later from Settings.")
                    .font(Theme.body(13)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if step > 0 {
                Button("Back") {
                    step -= 1
                    Settings.shared.onboardingStep = step
                }
                    .buttonStyle(QuietButtonStyle(height: 32))
            }
            Button(primaryLabel) {
                if step == 1 {
                    // Persist before moving on, so the answers are already in
                    // force by the time the scan and the reveal read them.
                    Settings.shared.primaryUse = primaryUse
                    Settings.shared.lowThresholdBytes = Int64(lowThresholdGB) * 1_000_000_000
                    model.onThresholdsChanged?()
                }
                if step < 3 {
                    step += 1
                    Settings.shared.onboardingStep = step
                    if step == 3 && !startedScan {
                        startedScan = true
                        onScan()
                    }
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
        case 1:  "Continue"
        case 2:  hasAccess ? "Continue" : "Skip for now"
        default: model.scanEngine.isRunning ? "Skip ahead" : "Start using DiskDrama"
        }
    }

    /// The scan already ran during the reveal, so finishing must not start a
    /// second one — it lands the user on the tier their answer chose.
    private func finish() {
        Settings.shared.hasCompletedOnboarding = true
        Settings.shared.onboardingStep = 0
        model.pane = .tier(Self.landingTier(for: primaryUse))
        model.isShowingOnboarding = false
    }

    /// Q1 with teeth. "Development" opens on Safe to delete, where build caches
    /// and package stores land; "photos and video" opens on Review first, where
    /// libraries and footage do. Neither is a guess about the person — it is a
    /// guess about which tier holds their answer, which is a much smaller claim.
    private static func landingTier(for use: String) -> Tier {
        switch use {
        case "dev":   .safe
        case "media": .reviewFirst
        default:      .safe
        }
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
