import Foundation
import Observation

/// The price the paywall shows, fetched at runtime instead of compiled in.
///
/// The backend resolves a Stripe `lookup_key` to a live Price at checkout time,
/// so changing a price is a Dashboard action. That fixes the point of sale but
/// not what the app *displays* beforehand — a hardcoded price string goes stale
/// in exactly the same way the old checkout code did, and would need a release
/// to correct. `/pricing?key=…` closes that gap.
///
/// ## Two tiers, not three
///
/// Turfs keeps a compiled `fallbackPrice = "$29"` as a last resort. DiskDrama
/// deliberately does not. A constant in the binary is a second source of truth
/// for a number that is only correct until the next Dashboard edit, and it is
/// wrong in every non-USD storefront from the moment it ships. The integration
/// brief forbids it outright.
///
/// So: the live figure, or the last one seen on this Mac, or **nothing** — and
/// the paywall is built to sell without a number when it has none. A missing
/// price costs a little persuasion. A wrong price costs trust, and this app's
/// whole pitch is that its numbers are honest.
@MainActor
@Observable
final class PricingService {

    static let shared = PricingService()

    /// What a buy button renders, or nil when no figure has ever been seen.
    private(set) var displayPrice: String?

    /// True once a live fetch has succeeded this launch. Lets a caller tell a
    /// confirmed figure from a remembered one — worth knowing before quoting a
    /// price anywhere binding.
    private(set) var isLive = false

    private let defaults: UserDefaults
    private var lastFetch: Date?
    private var fetching = false

    /// The paywall can appear more than once in a session — trial banner,
    /// Settings, a blocked action — and none of those should mean another round
    /// trip. The endpoint caches for 60s at its end; this keeps the app from
    /// leaning on that.
    private static let minRefetchInterval: TimeInterval = 300

    private static let cacheKey = "pricing.lastKnownDisplay"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayPrice = defaults.string(forKey: Self.cacheKey)
    }

    /// Safe to call whenever a purchase surface appears.
    func refresh() {
        guard !fetching else { return }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < Self.minRefetchInterval { return }
        fetching = true

        var request = URLRequest(url: PurchaseLink.pricingURL)
        request.timeoutInterval = 8

        Task { [weak self] in
            defer { Task { @MainActor in self?.fetching = false } }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let code = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(code),
                  let quote = try? JSONDecoder().decode(Quote.self, from: data),
                  !quote.display.isEmpty
            else {
                // Includes the 400 the endpoint returns until `diskdrama_lifetime`
                // is added to its allowlist. Nothing to do about it here, and
                // nothing to work around — the cached or absent price stands.
                return
            }
            await MainActor.run {
                self?.apply(quote)
            }
        }
    }

    private func apply(_ quote: Quote) {
        displayPrice = quote.display
        isLive = true
        lastFetch = Date()
        defaults.set(quote.display, forKey: Self.cacheKey)
    }

    /// The endpoint's shape. `amount` and `currency` are carried even though only
    /// `display` is rendered — a localized figure the client formats itself is a
    /// likely next step, and dropping the fields here would hide that they exist.
    private struct Quote: Decodable {
        let key: String
        let amount: Int
        let currency: String
        let display: String
        let type: String
        let interval: String?
    }
}
