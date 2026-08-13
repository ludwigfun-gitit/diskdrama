import Foundation
import FoundationModels

/// Apple's on-device `SystemLanguageModel` as a second source for F09.
///
/// ## Why this is written as a rewriter, not an identifier
///
/// The cloud path asks Claude a genuinely open question: *what is this folder,
/// really?* That works because the model has broad world knowledge about the
/// tools that create these directories.
///
/// The on-device model does not, and Apple says so plainly — it is built for
/// short text generation, summarisation and classification, not broad reasoning
/// or world knowledge. Handing it "identify this unknown folder" would be
/// asking for exactly the failure mode this app cannot afford: fluent,
/// confident, wrong, attached to a delete button.
///
/// So it is given a different job. The rule table has *already* identified the
/// folder and written generic text about it; this model is asked to sharpen
/// that text against the specific numbers for this one folder — the size, the
/// file count, how long since it was touched. That is text shaping, which is
/// what it is actually good at, and it cannot invent an identification because
/// it was never asked for one.
///
/// ## Consequently, confidence is not generated
///
/// `confidence` reports how sure the answer is that the *identification* is
/// right — and here the identification came from the rule table, not the model.
/// Asking a small model to introspect its own calibration would produce a
/// number with nothing behind it, so the rule's own confidence is passed
/// through unchanged and the UI attributes the source honestly. A made-up
/// confidence is worse than no confidence.
///
/// ## Availability
///
/// The framework needs macOS 26 on Apple Silicon with Apple Intelligence on and
/// the model downloaded. The app's deployment target stays macOS 14, so every
/// symbol here sits behind `@available` and the entry point is a factory that
/// returns nil rather than a type the caller has to know about.
enum OnDeviceExplanationProvider {

    /// The only entry point callable from code built for macOS 14. Returns nil
    /// on any machine that cannot run the model, which is the overwhelming
    /// majority of them for a good while yet.
    static func makeIfAvailable() -> (any ExplanationProvider)? {
        guard #available(macOS 26, *) else { return nil }
        return OnDeviceProvider.makeIfAvailable()
    }
}

@available(macOS 26, *)
struct OnDeviceProvider: ExplanationProvider {

    /// Not a *model* version — Apple does not expose one, and inventing a
    /// stable-looking one for something that updates with the OS underneath us
    /// would make the cache's provenance field quietly dishonest.
    ///
    /// The `r2` is a **prompt** revision, and it earns its place: explanations
    /// are cached by fingerprint and only reused when the identifier matches, so
    /// without it the text written by an earlier, worse prompt survives
    /// indefinitely. That is not hypothetical — the prompt fixes in this step
    /// left folders still showing "1 npm package" and an invented "1 minute"
    /// from the first version. Bump this whenever the prompt or the field
    /// split changes in a way that makes older cached prose wrong.
    var identifier: String { "apple.systemLanguageModel+r2" }
    var displayName: String { "Apple Intelligence" }
    var isLocal: Bool { true }

    static func makeIfAvailable() -> (any ExplanationProvider)? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return OnDeviceProvider()
        case .unavailable(let reason):
            // Logged once at the point of use, not surfaced. An unavailable
            // on-device model is not an error the user needs to see — it is
            // simply a machine that does not have the feature.
            Log.app.notice("on-device model unavailable: \(describe(reason), privacy: .public)")
            return nil
        @unknown default:
            return nil
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:           "device not eligible"
        case .appleIntelligenceNotEnabled: "Apple Intelligence not enabled"
        case .modelNotReady:               "model not downloaded yet"
        @unknown default:                  "unknown reason"
        }
    }

    // MARK: - Generation

    /// **One** field, guided. Not three.
    ///
    /// The first version had this model rewrite all four fields, and the
    /// consequence field is where that broke. Given the rule text "reconstructable
    /// in full from that project's package.json and lockfile", it produced
    /// "deleting this folder will cause the package.json and lockfile to be
    /// lost" — an inversion of the source, and a false statement sitting directly
    /// above a delete button. Adding a rule forbidding it fixed the inversion and
    /// introduced a worse problem: the model began quoting the rule itself back
    /// into the user-facing prose.
    ///
    /// So the dangerous fields are no longer generated at all. The rule table's
    /// consequence and rebuild-cost text is accurate, human-written, and already
    /// good; passing it through untouched removes an entire class of failure
    /// rather than trying to instruct a small model out of it. What is left is
    /// the descriptive field — the one where being wrong is a disappointment
    /// rather than a hazard, and the one this model is genuinely good at.
    @Generable
    struct Draft {
        @Guide(description: "What this folder holds and which tool created it, made specific to this project rather than generic. Two sentences, maximum three.")
        var whatThisIs: String
    }

    func explain(_ subject: ExplanationSubject) async throws -> Explanation {
        let session = LanguageModelSession(instructions: Self.instructions)

        let response: LanguageModelSession.Response<Draft>
        do {
            response = try await session.respond(
                to: Self.prompt(for: subject),
                generating: Draft.self,
                // Low temperature: this is a rewriting task with a right answer
                // shape, not a creative one. Variety here is only a chance to
                // drift away from the facts it was given.
                options: GenerationOptions(temperature: 0.3))
        } catch {
            throw Failure.generation(error)
        }

        return Explanation(
            whatThisIs: response.content.whatThisIs.trimmingCharacters(in: .whitespacesAndNewlines),
            // Verbatim from the rule table — see `Draft`. These are the two
            // fields a wrong answer can actually hurt someone with.
            consequenceOfDeleting: subject.localConsequence,
            rebuildCost: subject.localRebuildCost,
            // Passed through too: this model rephrased a description, it did not
            // make an identification, so it is in no position to raise or lower
            // the certainty attached to one.
            confidence: subject.localConfidence)
    }

    private func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Failure: Error, LocalizedError {
        case generation(Error)

        var errorDescription: String? {
            switch self {
            case .generation(let underlying):
                if let generationError = underlying as? LanguageModelSession.GenerationError {
                    return "The on-device model couldn't answer: \(generationError.localizedDescription)"
                }
                return underlying.localizedDescription
            }
        }
    }

    // MARK: - Prompts

    /// Short and instructional. A long system prompt is a poor trade on a small
    /// model: it crowds the context that the actual facts need, and every extra
    /// rule is another thing to be partially followed.
    private static let instructions = """
    You write one short description of a folder on a Mac.

    You are given a folder's measurements and a generic description that a rule \
    table already produced. Rewrite that description so it describes this \
    particular folder rather than folders of its kind in general.

    Rules:

    - Use only the facts you are given. Do not add facts about the tool, the \
    file format, or the folder that were not provided to you.
    - Describe only what the folder holds. Nothing about deleting it, nothing \
    about what it costs to get back — those are written elsewhere.
    - Do not list the measurements back mechanically, and do not restate the \
    "Identified as" label as a sentence.
    - Name the owning project, app or folder ONLY if its name appears literally \
    in the location you were given, and copy it exactly as it appears there. \
    Never invent a name, never infer one from the kind of folder it is, and \
    never reuse any name that appears in these instructions. If the location \
    does not name an owner, say nothing about ownership at all — an unowned \
    description is correct, and a guessed owner is a false statement about \
    someone's disk.
    - Two sentences. Three at the very most. This sits in a fixed panel and \
    length pushes the important part out of view.
    - Plain language, no jargon, no bullet points, no headings.
    - Do not greet the reader or offer further help. This is a panel, not a \
    conversation.
    """

    private static func prompt(for subject: ExplanationSubject) -> String {
        var lines = [
            "Folder name: \(subject.name)",
            "Location: \(PathDisplay.short(subject.path))",
            "Size on disk: \(ByteFormat.compact(subject.sizeBytes))",
        ]
        // The file count is deliberately **not** sent. Given it, this model
        // reliably restated it as a count of something it isn't — "41 files"
        // came back as "41 third-party JavaScript packages" — and labelling the
        // unit inline did not stop it. It is the least decision-relevant of the
        // measurements and the only one that was reliably producing a false
        // statement, so it is withheld rather than fought. The cloud provider
        // still receives it; this is a per-provider judgement about what one
        // model can be trusted to hold, not a change to the feature.
        if let days = subject.daysSinceModified {
            lines.append("Last changed: \(days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago")")
        }
        lines.append("Identified as: \(subject.localTitle)")
        lines.append("Generic description: \(subject.localWhatThisIs)")
        return lines.joined(separator: "\n")
    }
}
