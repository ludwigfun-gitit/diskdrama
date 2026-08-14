import AppKit
import Foundation

/// Where the Buy button goes.
///
/// One constant and one `NSWorkspace.open` — the entire app-side purchase
/// integration. Checkout, licence issuance, email delivery, activation and
/// re-validation all live in the shared Bloosoftware fulfillment backend, which
/// Visuals and Turfs already sell through. Nothing about payments is
/// implemented per-app.
///
/// **DiskDrama is Stripe, not StoreKit.** Full Disk Access is incompatible with
/// the App Sandbox, so the app is not App Store eligible as specified, and it
/// ships by direct download. Keepers' paywall is StoreKit and is precedent for
/// nothing here.
enum PurchaseLink {

    /// A Stripe `lookup_key`, never a price ID.
    ///
    /// Stripe Prices are immutable: changing a price creates a *new* Price
    /// object with a new ID. A lookup_key is a stable nickname that gets moved
    /// onto the replacement, so a price change is a Dashboard action and every
    /// shipped build keeps working with no rebuild. Hardcoding a price ID would
    /// reintroduce precisely the problem the 2026-08 rework removed.
    static let lookupKey = "diskdrama_lifetime"

    /// DiskDrama Pro is a one-time purchase, so there is no monthly/yearly key.
    ///
    /// The purchase email's download link resolves to
    /// `diskdrama-releases/releases/latest/download/DiskDrama.dmg`. Ludwig's
    /// call, 2026-08-13: treat that path as correct and settled. `/latest/`
    /// follows each new release on its own, so it is right the moment the first
    /// release is cut and needs no per-release step here, ever. Nothing in the
    /// app should gate on it or check it.
    static let checkoutURL = URL(string:
        "https://bloosoftware-fulfillment.netlify.app/.netlify/functions/checkout?price=\(lookupKey)")!

    /// Read-only price lookup, for display before checkout.
    ///
    /// Note `?key=`, not the `?price=` that checkout takes — the endpoint is
    /// deliberately generic because every app has the same stale-price problem.
    /// It shares checkout's allowlist and its resolution, so what the paywall
    /// shows can never disagree with what the customer is charged.
    static let pricingURL = URL(string:
        "https://bloosoftware-fulfillment.netlify.app/.netlify/functions/pricing?key=\(lookupKey)")!

    /// Deliberately absent: a price *constant*.
    ///
    /// No literal amount, no compiled fallback string. A number in the binary is
    /// a second source of truth that goes stale the moment the Dashboard changes
    /// and is wrong in every non-USD storefront from the day it ships.
    /// `PricingService` asks the endpoint above instead, and the paywall is built
    /// to sell without a figure when it has none.
    static func openCheckout() {
        NSWorkspace.shared.open(checkoutURL)
    }
}
