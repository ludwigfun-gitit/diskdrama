import SwiftUI

/// Buying DiskDrama.
///
/// **Path B** — one-time purchase, desktop utility. Most published paywall
/// advice assumes a consumer subscription app: plan ladders, weekly framing,
/// renewal anxiety, day-zero urgency. None of that exists here. What transfers
/// is layout discipline, price framing, the trust block, and timing — so this
/// screen is built from those four and nothing else.
///
/// ## Built trust-first
///
/// The skill is blunt that the reason people abandon is fear rather than price,
/// and that the transparency block is usually both the biggest win and the part
/// nobody builds. So it is not a footer here — the three questions a
/// one-time-purchase buyer actually has (how many Macs, what if I reinstall,
/// what if I want a refund) are answered on the screen, next to the button,
/// where the doubt is felt.
///
/// ## Two surfaces, one screen
///
/// `reason` decides the first sentence and whether there is a way out. A user
/// who went looking during the trial and a user whose trial just ended need
/// different opening lines, and only one of them can be dismissed.
struct PaywallSheet: View {

    enum Reason: Equatable {
        /// The user opened it — from the trial banner, Settings, or curiosity.
        case userInitiated
        /// The trial is over. Not dismissable to nothing: the app behind it is
        /// still readable, so closing returns to a working, read-only DiskDrama.
        case trialEnded
        /// A specific action was blocked. Names the thing they were denied.
        case blockedAction(String)
    }

    @Bindable var model: AppModel
    let reason: Reason
    let onActivate: () -> Void
    /// Supplied when the sheet is presented from another sheet, which cannot
    /// dismiss itself through `model.activeSheet`.
    var onClose: (() -> Void)? = nil

    @State private var pricing = PricingService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    whatYouKeep
                    trustBlock
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
            }
            Divider()
            footer
        }
        .frame(width: 620)
        .background(Theme.panel)
        .task { pricing.refresh() }
    }

    // MARK: - Header

    /// Loss framing, from the user's own numbers.
    ///
    /// The skill's table is explicit that "unlock unlimited X" is the weak form
    /// and naming what is at risk is the strong one — and a local-first app can
    /// build that out of real data instead of a claim. So the headline is
    /// whatever DiskDrama actually found on this Mac, and the reason line says
    /// what it can no longer do about it.
    ///
    /// The honesty line matters here: this is emphasis, not invention. Nothing
    /// is at risk that isn't, no deadline exists that wasn't already real, and
    /// the figure is the one the app has been showing all along.
    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(headline)
                .font(Theme.display(24))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(subhead)
                .font(Theme.body(14))
                .lineSpacing(4)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var reclaimable: String { ByteFormat.compact(model.totalReclaimableBytes) }

    private var headline: String {
        switch reason {
        case .trialEnded:
            model.totalReclaimableBytes > 0
                ? "\(reclaimable) is still sitting there"
                : "Your trial has ended"
        case .blockedAction:
            "That one needs a licence"
        case .userInitiated:
            "Buying DiskDrama"
        }
    }

    private var subhead: String {
        switch reason {
        case .trialEnded:
            "Your ten days are up. DiskDrama keeps showing you what's reclaimable and why — it just can't clean it up for you any more."
        case .blockedAction(let what):
            "\(what) needs a licence. Everything DiskDrama has already found stays visible either way."
        case .userInitiated:
            "One payment. No subscription, no account, no renewal."
        }
    }

    // MARK: - What you keep / what unlocks

    /// Deliberately framed as keep-versus-locked rather than a feature list.
    ///
    /// A feature list argues that the product is good, which the user has spent
    /// ten days establishing for themselves. The live question at expiry is
    /// narrower — *what have I actually lost?* — and answering it precisely is
    /// worth more than any bullet about tiers or classification.
    private var whatYouKeep: some View {
        HStack(alignment: .top, spacing: 18) {
            column(title: "Works forever, free",
                   tint: Theme.text3,
                   items: ["Scanning, and every result",
                           "Why each thing is safe or isn't",
                           "History, watches and blind spots",
                           "What your cloud storage really costs"])
            column(title: "Needs a licence",
                   tint: Theme.accent,
                   items: ["Delete what you've approved",
                           "Clean a whole tier in one go",
                           "\"Get me to 50 GB free\" planning",
                           "Remove cloud downloads"])
        }
    }

    private func column(title: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(item)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trust

    /// The three questions a one-time-purchase buyer actually has.
    ///
    /// Not a cancellation FAQ — there is nothing to cancel — but the same idea
    /// moved to the objections this model raises. On the screen, not behind a
    /// link, because the doubt is felt at the button and nobody opens a link to
    /// resolve it.
    private var trustBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Before you decide")
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
            faq("Is this a subscription?",
                "No. One payment, and the licence doesn't expire. There's nothing to renew and nothing to cancel.")
            faq("What if I reinstall, or get a new Mac?",
                "Your licence key arrives by email and activates again. Nothing is tied to this machine.")
            faq("Do I need an account?",
                "No. Activation is an email address and the key — DiskDrama never asks you to make an account, and it still sends nothing about your files anywhere.")
        }
        .padding(16)
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Theme.hairline, lineWidth: 1))
    }

    private func faq(_ question: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question)
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text(answer)
                .font(Theme.body(12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let exit = exitLabel {
                    Button(exit) { close() }
                        .buttonStyle(QuietButtonStyle(height: 32))
                }
                Button("I already have a key") { onActivate() }
                    .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 14, fontSize: 13.5))
                Spacer(minLength: 8)
                Button(buyLabel) { PurchaseLink.openCheckout() }
                    .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
            }
            // Beside the button, not in a footer — it has to be readable at the
            // instant of the decision.
            Text(trustLine)
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    /// Anchored, never naked.
    ///
    /// With a live figure the price sits against the thing it manages — a
    /// one-off payment measured against a 494 GB disk, which is the contrast
    /// effect doing the work rather than decoration. Without one the button
    /// still has to function, so it says what happens next instead of what it
    /// costs; the real figure is on the checkout page a click later, and an
    /// absent number is far cheaper than a wrong one.
    private var buyLabel: String {
        pricing.displayPrice.map { "Buy DiskDrama — \($0) once" } ?? "See the price and buy"
    }

    private var trustLine: String {
        pricing.displayPrice == nil
            ? "Opens in your browser. Nothing is charged until you choose to pay."
            : "One payment, forever. Opens in your browser."
    }

    /// The escape hatch is part of the persuasion surface, and stating the cost
    /// of declining is the skill's own correction to a frictionless "Maybe
    /// later". It still genuinely dismisses — never-trap-the-user holds.
    private func close() {
        if let onClose { onClose() } else { model.activeSheet = nil }
    }

    private var exitLabel: String? {
        switch reason {
        case .userInitiated:  "Not now"
        case .blockedAction:  "Leave it for now"
        case .trialEnded:     "Keep looking without cleaning"
        }
    }
}
