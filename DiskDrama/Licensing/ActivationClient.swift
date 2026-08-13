import Foundation

/// HTTP client for the two licence endpoints in the shared Bloosoftware
/// fulfillment backend. Stateless — each call is an independent POST.
///
/// Both endpoints take JSON and both require an `app` field selecting the
/// per-app storage. Every request from here sends `"diskdrama"`.
///
/// ## The distinction the whole design turns on
///
/// **An application failure is an HTTP 200 carrying a reason.** `invalid_key`,
/// `email_mismatch`, `subscription_inactive`, `expired`, `invalid_code`,
/// `invalid_request`, `server_error` — all 200. A 4xx or 5xx means transport or
/// configuration trouble and says *nothing* about the licence.
///
/// So a non-2xx throws here rather than decoding into a verdict. Turfs' client
/// tries to parse a 4xx body into a reply; that is one short step from treating
/// a gateway hiccup as `valid: false`, which locks out a paying customer
/// whenever the network wobbles. A verdict comes only from a 200.
struct ActivationClient {

    static let base = URL(string: "https://bloosoftware-fulfillment.netlify.app/.netlify/functions/")!

    /// Long enough for a cold Netlify function, short enough that an activation
    /// sheet does not appear to hang.
    static let timeout: TimeInterval = 12

    /// Selects per-app storage on the backend. Wrong value here silently reads
    /// another product's licences.
    private static let app = "diskdrama"

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = ActivationClient.base, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Endpoints

    /// Step 1 of activation: ask the backend to email a 6-digit code.
    /// 200 `{ status: "code_sent" }` on success; the code has a 15-minute TTL.
    func requestCode(email: String, key: String) async throws -> Reply {
        try await post("activate-license", ["email": email, "key": key])
    }

    /// Step 2: exchange the code for an activation.
    /// 200 `{ valid: true, tier: "pro", interval: "perpetual" }` on success.
    func confirm(email: String, key: String, code: String) async throws -> Reply {
        try await post("activate-license", ["email": email, "key": key, "code": code])
    }

    /// Silent re-check, on launch and once daily. Never blocks the UI, and its
    /// failure must never lock the app — see `LicenseStore` for the grace window.
    func validate(email: String, key: String) async throws -> Reply {
        try await post("validate-license", ["email": email, "key": key])
    }

    // MARK: - Reply

    /// One shape for both endpoints; the caller branches on what is present.
    struct Reply: Decodable {
        /// Activation uses this: "code_sent", or a failure reason.
        let status: String?
        /// Set by a successful confirm and by every validate reply.
        let valid: Bool?
        /// "pro" or "free".
        let tier: String?
        /// Why `valid` is false.
        let reason: String?
        /// "monthly" | "yearly" | "perpetual". Drives the offline grace window,
        /// which the client is responsible for honouring.
        let interval: String?

        /// The failure the server reported, if it reported one. Reads `reason`
        /// first because validate uses it, then `status`, which activation uses
        /// for the same purpose.
        var failureReason: String? {
            if valid == true { return nil }
            if let reason { return reason }
            if let status, status != "code_sent" { return status }
            return nil
        }
    }

    enum ClientError: Error, LocalizedError {
        case transport(URLError)
        /// Not a licence verdict. Config or infrastructure.
        case badStatus(Int)
        case undecodable(Error)

        var errorDescription: String? {
            switch self {
            case .transport(let error):
                "Couldn't reach the licence server (\(error.localizedDescription))."
            case .badStatus(let code):
                "The licence server returned HTTP \(code). That's a problem with the server, not with your licence."
            case .undecodable:
                "The licence server's reply wasn't readable."
            }
        }
    }

    // MARK: - Transport

    private func post(_ function: String, _ fields: [String: String]) async throws -> Reply {
        var request = URLRequest(url: baseURL.appending(path: function))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: fields.merging(["app": Self.app]) { current, _ in current })

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ClientError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Deliberately not parsed. A body on a 4xx is not a verdict about
            // anyone's licence, and treating it as one is how a paying customer
            // gets locked out by a bad gateway.
            throw ClientError.badStatus(code)
        }

        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw ClientError.undecodable(error)
        }
    }
}
