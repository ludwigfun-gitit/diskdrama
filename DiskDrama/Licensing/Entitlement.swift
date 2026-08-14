import Foundation
import Observation

/// The trial clock, and the one question the rest of the app is allowed to ask.
///
/// ## The model
///
/// Ten days, full-featured, no signup, no email, no card — then a one-time
/// purchase. Full-featured is not generosity, it is the mechanic: a crippled
/// trial teaches the user what the app *can't* do and creates no debt to repay.
///
/// **Expiry is read-only, not inert.** Everything DiskDrama knows stays
/// visible — scans, tiers, explanations, history, watches, blind spots, cloud
/// inventory. What stops is *acting*: deleting, batch cleaning, the target
/// planner, evicting downloads. So the user keeps what they built and buys the
/// ability to keep acting on it, rather than buying back a product that was
/// taken away. It also leaves DiskDrama honest and useful at expiry: it can
/// still tell you that 104 GB is reclaimable, it just can't reclaim it for you.
///
/// ## One gate
///
/// `isActive` is the whole entitlement surface. Not `isPro` scattered through
/// forty features — that is how a pricing change becomes a three-week refactor.
/// Everything that can destroy or move data checks this one property, and
/// nothing else does.
@MainActor
@Observable
final class Entitlement {

    enum Status: Equatable {
        case trial(daysLeft: Int)
        case trialExpired
        case licensed
    }

    /// House default, matching Visuals on both channels. Long enough to see a
    /// second scan and watch something regrow, which is DiskDrama's real "oh" —
    /// the app is about things that come back, and a trial that ends before
    /// anything has come back never shows that.
    static let trialDays = 10

    private let licence: LicenseStore
    private let defaults: UserDefaults

    private static let startedAtKey = "trial.startedAt"

    init(licence: LicenseStore, defaults: UserDefaults = .standard) {
        self.licence = licence
        self.defaults = defaults
    }

    /// Set on first launch and never moved.
    ///
    /// Stored as a date rather than a countdown so that closing the app does not
    /// pause it and a clock change cannot silently extend it. Written lazily on
    /// first read: a user who never opens the app has not started a trial.
    var trialStartedAt: Date {
        if let stored = defaults.object(forKey: Self.startedAtKey) as? Date { return stored }
        let now = Date()
        defaults.set(now, forKey: Self.startedAtKey)
        return now
    }

    var trialEndsAt: Date {
        Calendar.current.date(byAdding: .day, value: Self.trialDays, to: trialStartedAt) ?? trialStartedAt
    }

    /// Whole days remaining, floored at zero. Counts the day in progress, so a
    /// trial started today reads "10 days left" rather than "9".
    var trialDaysLeft: Int {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: trialEndsAt).day ?? 0
        return max(0, days + 1)
    }

    var status: Status {
        if case .licensed = licence.state { return .licensed }
        return trialDaysLeft > 0 ? .trial(daysLeft: trialDaysLeft) : .trialExpired
    }

    /// **The gate.** True when DiskDrama may act on the disk.
    ///
    /// Deliberately reads as a permission to *do something*, not as a tier name.
    /// A call site written against `isActive` says what it means — "may I delete
    /// this" — where one written against `isPro` invites someone to add a second
    /// meaning to it later.
    var isActive: Bool {
        switch status {
        case .licensed, .trial: true
        case .trialExpired:     false
        }
    }

    /// Why an action is unavailable, or nil when it is available.
    ///
    /// Same shape as `destructiveBlockReason` for a running scan, and for the
    /// same reason: a disabled control that will not say why is the thing users
    /// report as broken.
    var blockReason: String? {
        isActive ? nil : "Your trial has ended. DiskDrama can still show you what's reclaimable — buying it lets it act on that again."
    }

    /// True for the last stretch of the trial, when a reminder is fair rather
    /// than nagging. Three days is late enough that the user has had the product
    /// and early enough that expiry is not a surprise.
    var isTrialEndingSoon: Bool {
        if case .trial(let days) = status { return days <= 3 }
        return false
    }

    // MARK: - Debug (Part 7 of the onboarding skill)

    #if DEBUG
    /// Verification is impossible on a machine that has already run the funnel,
    /// and the unlicensed path is impossible to see on a licensed one. Without
    /// these the funnel ships unverified, which is how it usually ships.
    func debugResetTrial() { defaults.removeObject(forKey: Self.startedAtKey) }

    func debugExpireTrial() {
        let past = Calendar.current.date(byAdding: .day, value: -(Self.trialDays + 1), to: Date())!
        defaults.set(past, forKey: Self.startedAtKey)
    }
    #endif
}
