import Foundation
import Security

/// What was learned the last time the backend was reached.
///
/// The email is stored alongside the key because re-validation needs both, and
/// prompting for them again on every silent check would defeat the point of it
/// being silent.
struct ActivationRecord: Codable, Equatable {
    let email: String
    let key: String
    let activatedAt: Date
    var lastValidated: Date
    /// "monthly" | "yearly" | "perpetual". Optional so a record written by an
    /// earlier build still decodes; a nil interval is treated conservatively.
    var interval: String?
}

/// The activation record, in the login Keychain.
///
/// Keychain rather than `UserDefaults` because a licence key is a credential:
/// a plist is world-readable to anything running as the user and gets swept up
/// by backups and sync. Same reasoning, same Security-framework shape, as
/// `APIKeyStore` already uses for the explanation API key.
enum LicenseKeychain {

    private static let service = "com.bloo.diskdrama.license"
    private static let account = "activation"

    static func read() -> ActivationRecord? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let record = try? JSONDecoder().decode(ActivationRecord.self, from: data)
        else { return nil }
        return record
    }

    @discardableResult
    static func write(_ record: ActivationRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Update first: SecItemAdd fails with errSecDuplicateItem rather than
        // replacing, so a plain add would silently keep a stale record.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Log.app.error("licence keychain update failed: \(updated, privacy: .public)")
            return false
        }
        let status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status != errSecSuccess {
            Log.app.error("licence keychain add failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}


/// Activation, re-validation, and the offline grace window.
///
/// ## Why the app never waits for the network to decide
///
/// A licence check that gates launch is a licence check that takes the product
/// away when the wifi drops, on a plane, or when Netlify has a bad afternoon.
/// So the stored record is authoritative until it demonstrably expires: the app
/// starts from the Keychain, re-validates in the background, and only downgrades
/// on an explicit `valid: false` from a 200 reply, or once the grace window
/// implied by `interval` has genuinely elapsed.
///
/// A transport failure is not evidence of anything and never downgrades.
@MainActor
final class LicenseStore {

    enum State: Equatable {
        case unlicensed
        case licensed(email: String, lastValidated: Date)
        /// Was licensed; the grace window ran out without a successful check.
        case lapsed(reason: String)
    }

    private(set) var state: State
    private let client: ActivationClient

    /// Re-check no more than once a day. The backend is the source of truth but
    /// it is not consulted for permission to run.
    private static let revalidateInterval: TimeInterval = 24 * 3600

    init(client: ActivationClient = ActivationClient()) {
        self.client = client
        // Hydrate before anything asks, so a cold start renders licensed without
        // a network round trip.
        if let record = LicenseKeychain.read() {
            state = .licensed(email: record.email, lastValidated: record.lastValidated)
        } else {
            state = .unlicensed
        }
    }

    /// How long a licence stays good offline, by interval.
    ///
    /// `perpetual` returns nil — indefinite. DiskDrama Pro is a one-time
    /// purchase, so that is the normal case here; the subscription windows exist
    /// because the same backend serves apps that have them. An unknown or
    /// missing interval gets the conservative 30 days rather than the generous
    /// answer.
    static func graceWindow(for interval: String?) -> TimeInterval? {
        switch interval {
        case "perpetual", "lifetime": nil
        case "yearly":                365 * 24 * 3600
        case "monthly":               30 * 24 * 3600
        default:                      30 * 24 * 3600
        }
    }

    // MARK: - Activation (two-step, OTP)

    /// The outcome of an activation step: done, or a sentence to show.
    ///
    /// Not `Result<Void, Error>` — every failure here is already a finished
    /// sentence aimed at a person, and wrapping it in an error type would only
    /// invite a call site to print `localizedDescription` of a string.
    enum Outcome: Equatable {
        case ok
        case failed(String)
    }

    /// Step 1. Returns whether the code was sent; the reason otherwise.
    func requestCode(email: String, key: String) async -> Outcome {
        do {
            let reply = try await client.requestCode(email: email, key: key)
            if reply.status == "code_sent" { return .ok }
            return .failed(Self.message(for: reply.failureReason))
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Step 2. On success the record is written and the app is licensed.
    func confirm(email: String, key: String, code: String) async -> Outcome {
        do {
            let reply = try await client.confirm(email: email, key: key, code: code)
            guard reply.valid == true else {
                return .failed(Self.message(for: reply.failureReason))
            }
            let now = Date()
            let record = ActivationRecord(email: email, key: key, activatedAt: now,
                                          lastValidated: now, interval: reply.interval)
            LicenseKeychain.write(record)
            state = .licensed(email: email, lastValidated: now)
            return .ok
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func deactivate() {
        LicenseKeychain.clear()
        state = .unlicensed
    }

    // MARK: - Silent re-validation

    /// Call on launch and once a day. Safe to call more often — it returns
    /// immediately if the last check is recent enough.
    func revalidateIfDue() async {
        guard var record = LicenseKeychain.read() else { return }
        guard Date().timeIntervalSince(record.lastValidated) >= Self.revalidateInterval else { return }

        do {
            let reply = try await client.validate(email: record.email, key: record.key)
            if reply.valid == true {
                record.lastValidated = Date()
                record.interval = reply.interval ?? record.interval
                LicenseKeychain.write(record)
                state = .licensed(email: record.email, lastValidated: record.lastValidated)
            } else {
                // An explicit verdict from a 200. This is the one thing that
                // revokes a licence.
                LicenseKeychain.clear()
                state = .lapsed(reason: Self.message(for: reply.failureReason))
            }
        } catch {
            // Could not ask. That is not an answer, so nothing is revoked until
            // the grace window has actually run out.
            guard let grace = Self.graceWindow(for: record.interval) else { return }
            if Date().timeIntervalSince(record.lastValidated) > grace {
                state = .lapsed(reason: "DiskDrama hasn't been able to check your licence for a while. "
                                      + "Connect to the internet and reopen it.")
            }
        }
    }

    /// Server reasons are identifiers, not sentences. Anything unrecognised is
    /// passed through rather than swallowed — a reason nobody has seen before is
    /// still more use than "something went wrong".
    private static func message(for reason: String?) -> String {
        switch reason {
        case "invalid_key":           "That licence key isn't recognised."
        case "email_mismatch":        "That key belongs to a different email address."
        case "subscription_inactive": "That licence is no longer active."
        case "expired":               "That code has expired. Request a new one."
        case "invalid_code":          "That code isn't right. Check the email and try again."
        case "invalid_request":       "Something was missing from the request. Check the email and key."
        case "server_error":          "The licence server had a problem. Try again in a moment."
        case .some(let other):        "The licence server said: \(other)."
        case nil:                     "The licence server didn't say why."
        }
    }
}
