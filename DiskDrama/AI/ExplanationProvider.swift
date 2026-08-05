import Foundation

/// The seam between F09's explanation feature and whoever actually generates
/// the prose.
///
/// Step 8 wired the Anthropic API in directly, which was correct when it was
/// the only source. A second source is now real rather than hypothetical, so
/// the two sit behind one small interface instead of the on-device call being
/// bolted alongside Anthropic-specific request building.
///
/// Deliberately minimal: a subject in, four fields out, plus the provenance
/// string that says who produced them. No configuration surface, no
/// registration, no user-facing picker — choosing between providers by policy
/// is a decision that hasn't been made yet, and building the machinery for it
/// before the decision would be guessing at the answer.
protocol ExplanationProvider: Sendable {

    /// Written verbatim to `CachedExplanation.modelIdentifier`. An on-device
    /// result and a cloud result must never be indistinguishable in the cache —
    /// they have different accuracy characteristics and different privacy
    /// properties, and a row that doesn't say which it was is a row you cannot
    /// reason about later.
    var identifier: String { get }

    /// Shown to the reader next to the explanation. The user is entitled to
    /// know whether the text they're about to act on came off their own machine
    /// or out of a datacentre.
    var displayName: String { get }

    /// Whether generation happens on this machine.
    ///
    /// Drives the privacy copy, which is otherwise a lie by omission: "only the
    /// folder's name, size and date are ever sent" describes the cloud path and
    /// nothing at all about the on-device one, where the honest statement is
    /// that nothing is sent.
    var isLocal: Bool { get }

    func explain(_ subject: ExplanationSubject) async throws -> Explanation
}

/// The item being explained, reduced to what a provider needs. Deliberately
/// **not** the whole `Recommendation`: no user paths beyond the one folder, no
/// scan totals, nothing about the rest of the disk. That restraint matters more
/// now than it did in Step 8, because one of the two providers sends this over
/// the network.
struct ExplanationSubject: Sendable {
    let path: String
    let name: String
    let sizeBytes: Int64
    let fileCount: Int
    let daysSinceModified: Int?
    /// What the local knowledge base already concluded, so the model refines
    /// rather than contradicts it.
    let localTitle: String
    let localTier: Tier
    let localWhatThisIs: String
    /// The local rule's own consequence and rebuild-cost text. The cloud model
    /// doesn't need these — it reasons its way to them. The on-device provider
    /// passes them straight through to the reader untouched, because letting a
    /// small model rewrite the two fields with delete-safety stakes went badly
    /// (see `OnDeviceProvider.Draft`).
    let localConsequence: String
    let localRebuildCost: String?
    /// How sure the rule table is. Carried so a provider that isn't in a
    /// position to assess its own certainty can be honest about whose
    /// certainty it is reporting.
    let localConfidence: Double
}

/// The four fields `CachedExplanation` stores — the same shape as a local
/// `Classification`, so an AI explanation is a richer version of the same thing
/// rather than a parallel format the UI has to special-case.
struct Explanation: Sendable, Codable {
    let whatThisIs: String
    let consequenceOfDeleting: String
    let rebuildCost: String?
    /// How sure the answer is that its identification is right. The UI shows
    /// this alongside the local one. A confident-sounding paragraph with no
    /// confidence attached is exactly F09's failure case.
    let confidence: Double
}

/// Picks the provider to use.
///
/// The policy is deliberately hardcoded and deliberately small: **prefer the
/// on-device model when the machine can run it, fall back to Anthropic when a
/// key is configured, and offer nothing when neither applies.**
///
/// On-device goes first because it is free, offline and private, and the local
/// rule-based explanation — which is what the user sees either way — is already
/// good enough that paying per request for a marginal improvement should be the
/// exception rather than the default.
///
/// "Offer nothing" is a supported state, not a failure. It is the same
/// graceful degradation Step 8 built for a missing API key: the panel simply
/// doesn't show a deeper explanation, and the local classification stands
/// alone. Nothing errors, and nothing tells the user to go and configure
/// something.
enum ExplanationProviders {

    /// Resolved once. Whether this Mac can run the on-device model does not
    /// change while the app is open, and `active()` is called from view bodies
    /// — re-asking the framework on every render would be a needless cost on a
    /// question with a fixed answer. The API key *can* change mid-session, so
    /// that half is re-read every time.
    private static let onDevice = OnDeviceExplanationProvider.makeIfAvailable()

    static func active() -> (any ExplanationProvider)? {
        if let onDevice { return onDevice }
        if APIKeyStore.hasKey { return AnthropicExplanationProvider() }
        return nil
    }
}

/// The Step 8 path, wrapped. `AnthropicClient` keeps owning the HTTP; this only
/// gives it the shape the seam expects.
struct AnthropicExplanationProvider: ExplanationProvider {
    var identifier: String { AnthropicClient.model }
    var displayName: String { "Claude" }
    var isLocal: Bool { false }

    func explain(_ subject: ExplanationSubject) async throws -> Explanation {
        try await AnthropicClient.explain(subject)
    }
}
