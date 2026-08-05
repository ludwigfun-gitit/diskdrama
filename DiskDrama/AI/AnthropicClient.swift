import Foundation

/// Raw HTTP against the Anthropic Messages API.
///
/// There is no official Anthropic SDK for Swift, so this is `URLSession` against
/// `POST /v1/messages` — the documented path for languages without an SDK, and
/// what the preflight's architecture section specified.
///
/// Scope is deliberately one call: DiskDrama asks a single question about a
/// single folder and gets a structured answer back. No conversation, no tools,
/// no streaming — none of which this product needs, and each of which would be
/// a surface to maintain.
enum AnthropicClient {

    /// Both types now live on the seam (`ExplanationProvider.swift`) rather than
    /// here, because they describe the feature rather than this transport. The
    /// alias keeps `AnthropicClient.Subject` reading naturally at the call sites
    /// inside this file.
    typealias Subject = ExplanationSubject

    enum Failure: Error, LocalizedError {
        case noAPIKey
        case refused(String)
        case http(Int, String)
        case malformed(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:          "No Anthropic API key is configured."
            case .refused(let why):  "The model declined to answer: \(why)"
            case .http(let code, let body):
                code == 401 ? "That API key was rejected."
                    : code == 429 ? "Rate limited — try again in a moment."
                    : "The API returned \(code). \(body)"
            case .malformed(let why): "Unreadable response: \(why)"
            case .transport(let e):   e.localizedDescription
            }
        }
    }

    /// `claude-opus-5`. Recorded on every cache row, so an explanation written
    /// by an older model stays identifiable rather than blending in.
    static let model = "claude-opus-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// Server-side fallback: on the rare policy decline, the API re-runs the
    /// request on Anthropic's recommended fallback model within the same call
    /// rather than handing back a refusal. `"default"` routes by refusal
    /// category, so there is no fallback model list to maintain here.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    // MARK: - Request

    /// Asks for one explanation.
    ///
    /// ## The retry is not speculative error handling
    ///
    /// The full request carries an optional extra: server-side `fallbacks`,
    /// which needs a beta header. That is the right thing to send — a policy
    /// decline gets re-served instead of surfacing as a dead end — but it is
    /// the one part of this request that can go stale independently of the
    /// feature, since beta flags are dated and eventually retire.
    ///
    /// A 400 is exactly how that staleness would present, and it would take the
    /// whole feature down over a parameter the feature does not depend on. So a
    /// 400 retries once without the optional extra. Everything load-bearing —
    /// the model, the schema, the prompt — is identical on both attempts; only
    /// the safety net is dropped.
    static func explain(_ subject: Subject) async throws -> Explanation {
        do {
            return try await send(subject, includingFallbacks: true)
        } catch Failure.http(400, let body) {
            Log.app.error("""
            explanation request rejected with 400, retrying without the fallbacks \
            parameter — \(body.prefix(300), privacy: .public)
            """)
            return try await send(subject, includingFallbacks: false)
        }
    }

    private static func send(_ subject: Subject, includingFallbacks: Bool) async throws -> Explanation {
        guard let key = APIKeyStore.read() else { throw Failure.noAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if includingFallbacks {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body(for: subject, includingFallbacks: includingFallbacks))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        logUsage(data)
        return try parse(data)
    }

    private static func body(for subject: Subject, includingFallbacks: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // Room for adaptive thinking *and* the answer — `max_tokens` caps
            // both together, so sizing it around the JSON alone would truncate
            // the response mid-object.
            "max_tokens": 2048,

            // Thinking on at low effort, rather than off. Disabled thinking on
            // this model can leak `<thinking>` tags into the output, and low
            // effort already gets most of the cost saving.
            "thinking": ["type": "adaptive"],

            "output_config": [
                "effort": "low",
                // Structured output rather than prose: the four fields land
                // straight in `CachedExplanation`, and there is no free-text
                // parsing to go wrong months from now.
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ],
            ],

            "system": [[
                "type": "text",
                "text": systemPrompt,
                // Identical on every request, so it caches — but only if it
                // clears the model's 512-token minimum. Below that it silently
                // won't, which `cache_creation_input_tokens` in the response
                // makes visible (logged by `ExplanationService`).
                "cache_control": ["type": "ephemeral"],
            ]],

            "messages": [[
                "role": "user",
                "content": userPrompt(for: subject),
            ]],
        ]

        if includingFallbacks {
            body["fallbacks"] = "default"
        }
        return body
    }

    /// A literal, built fresh per call. `[String: Any]` cannot be `Sendable`,
    /// and a computed property is the honest way to say "this is a constant
    /// that happens to be untyped JSON" rather than reaching for
    /// `nonisolated(unsafe)` on shared mutable state.
    private static var schema: [String: Any] {[
        "type": "object",
        "additionalProperties": false,
        "required": ["whatThisIs", "consequenceOfDeleting", "confidence"],
        "properties": [
            "whatThisIs": [
                "type": "string",
                "description": "What this folder actually contains and which tool put it there. Two sentences at most.",
            ],
            "consequenceOfDeleting": [
                "type": "string",
                "description": "What the user loses or has to redo if it goes. Concrete, not categorical. Two sentences at most.",
            ],
            "rebuildCost": [
                "type": ["string", "null"],
                "description": "What regenerating it costs in time or bandwidth, if there is a cost. Null when nothing regenerates.",
            ],
            "confidence": [
                "type": "number",
                "description": "0 to 1. How sure you are this identification is right. Be honest — a low number here is useful, a wrong high one is dangerous.",
            ],
        ],
    ]}

    // MARK: - Prompts

    /// Stable across every request, which is what makes it cacheable — nothing
    /// item-specific belongs in here.
    private static let systemPrompt = """
    You help someone decide whether a folder on their Mac is safe to delete. You \
    are the second opinion: a local rule table has already identified the folder \
    and produced a short description, and you are being asked for the deeper \
    read that a rule table cannot give — what the folder is really for, what \
    breaks without it, and how much of a nuisance getting it back would be.

    Write for someone competent but not a specialist in whichever tool created \
    the folder. They know what a build is; they do not necessarily know what \
    Xcode keeps in DerivedData or why a package manager has two caches.

    How to write:

    - State consequences, not categories. "Build artifacts" tells the reader \
      nothing they can act on. "Xcode rebuilds this on your next build — one \
      slow clean build per project" tells them exactly what deleting it costs.
    - Be concrete about time and effort. If regenerating means a twenty-minute \
      rebuild or re-downloading eight gigabytes, say so. Vague reassurance that \
      something "will be recreated automatically" is how people lose an \
      afternoon.
    - Translate jargon the first time you use it, or avoid it.
    - Two sentences per field is the target. Never more than three. This text \
      sits in a fixed panel in a desktop app; length pushes the important part \
      out of view.
    - Do not repeat the local description back. Add to it or correct it.
    - Do not address the reader by name, open with pleasantries, or end by \
      offering further help. This is a panel, not a conversation.
    - Do not include internal or system XML tags in your response.

    On being unsure — this matters more than being helpful:

    - If you do not recognise the folder, say so plainly in whatThisIs and set \
      confidence low. "I can't identify this one" is a genuinely useful answer.
    - Never invent a plausible-sounding purpose for a folder you don't know. \
      Someone will delete it on your say-so.
    - If the folder might contain something the user created rather than \
      something a tool generated, say that explicitly, whatever the local \
      classification claims.
    - Set confidence honestly. Above 0.9 means you are certain what this is; \
      0.6 to 0.9 means you recognise the pattern but cannot see inside; below \
      0.6 means you are guessing, and the app will present it that way.
    """

    /// The only per-request text. Sits after the cache breakpoint, so varying
    /// it does not invalidate the cached system prefix.
    private static func userPrompt(for subject: Subject) -> String {
        var lines = [
            "Folder: \(PathDisplay.short(subject.path))",
            "Name: \(subject.name)",
            "Size on disk: \(ByteFormat.compact(subject.sizeBytes))",
        ]
        if subject.fileCount > 0 {
            lines.append("Files inside: \(ByteFormat.count(subject.fileCount))")
        }
        if let days = subject.daysSinceModified {
            lines.append("Last modified: \(days) days ago")
        }
        lines.append("Local classification: \(subject.localTitle) — \(subject.localTier.title)")
        lines.append("Local description: \(subject.localWhatThisIs)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Response

    private static func parse(_ data: Data) throws -> Explanation {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("response was not JSON")
        }

        // Check the stop reason before touching content. A declined request is
        // a successful HTTP 200 whose content is empty or partial, so indexing
        // straight into content[0] would fail confusingly on the one path that
        // most needs a clear message.
        if root["stop_reason"] as? String == "refusal" {
            let details = root["stop_details"] as? [String: Any]
            throw Failure.refused(details?["explanation"] as? String
                ?? "the request was declined by a safety classifier")
        }

        guard let content = root["content"] as? [[String: Any]] else {
            throw Failure.malformed("no content in response")
        }

        // Filter by type. With thinking on, the first block is a thinking
        // block, not the answer.
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw Failure.malformed("no text block in response")
        }

        guard let json = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Explanation.self, from: json) else {
            throw Failure.malformed("the model's JSON did not match the schema")
        }
        return parsed
    }

    /// Token accounting, to the unified log.
    ///
    /// `cacheRead` staying at zero across requests is the tell that the system
    /// prompt is below the model's minimum cacheable length — it silently
    /// doesn't cache and quietly costs full price every time. Without this line
    /// that is invisible.
    private static func logUsage(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return }
        Log.app.notice("""
        explanation — in=\(usage["input_tokens"] as? Int ?? 0, privacy: .public) \
        out=\(usage["output_tokens"] as? Int ?? 0, privacy: .public) \
        cacheWrite=\(usage["cache_creation_input_tokens"] as? Int ?? 0, privacy: .public) \
        cacheRead=\(usage["cache_read_input_tokens"] as? Int ?? 0, privacy: .public) \
        model=\(root["model"] as? String ?? "?", privacy: .public)
        """)
    }
}
