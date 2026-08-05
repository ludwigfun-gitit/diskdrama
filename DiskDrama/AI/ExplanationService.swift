import Foundation
import Observation
import SwiftData

/// The AI half of F09 (A02, A05).
///
/// ## Why this layer is small
///
/// A05 splits the work deliberately: **tiering is local and free**, computed
/// for the whole tree at scan time by `KnowledgeBase`; the API is asked only
/// for the deeper prose on an item the user actually opened. Asking a model to
/// re-derive "build artifacts regenerate" for ten thousand folders per scan
/// would be slower, more expensive, and less reliable than a table.
///
/// So this service handles exactly one thing — one folder, on first view, once.
///
/// ## Caching is not an optimisation here
///
/// It is what makes the feature affordable. An explanation is keyed to the
/// item's **scan fingerprint** (`path|size|mtime`), so it survives across scans
/// and relaunches and is only regenerated when the folder itself has changed.
/// Opening the same row a second time costs nothing.
@MainActor
@Observable
final class ExplanationService {

    enum State: Equatable {
        /// No key configured. The feature is not offered rather than offered
        /// and broken.
        case unavailable
        case idle
        case loading
        case ready(Explanation)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.unavailable, .unavailable), (.idle, .idle), (.loading, .loading): true
            case (.ready(let a), .ready(let b)):
                a.whatThisIs == b.whatThisIs && a.consequenceOfDeleting == b.consequenceOfDeleting
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    /// Keyed by fingerprint, not by path — two scans of a folder that changed
    /// in between are different subjects and must not share an answer.
    private var states: [String: State] = [:]

    /// Fingerprints already requested this session, so a view that re-renders
    /// while a request is in flight doesn't fire a second one. Separate from
    /// `states` because a failure should still be retryable.
    private var inFlight: Set<String> = []

    /// Whichever provider is in force, or nil when this Mac can offer neither
    /// the on-device model nor a configured key. Resolved through the seam so
    /// this service never knows which one it is talking to.
    private var provider: (any ExplanationProvider)? { ExplanationProviders.active() }

    var isConfigured: Bool { provider != nil }

    /// Where the current explanations are coming from, for the panel's
    /// provenance line. Nil when the feature isn't offered at all.
    var sourceName: String? { provider?.displayName }

    func state(for item: Recommendation) -> State {
        guard isConfigured else { return .unavailable }
        return states[item.fingerprint] ?? .idle
    }

    /// A05's "generated on first view". Idempotent and safe to call from a view
    /// body's `.task` — a cache hit resolves without touching the network, and
    /// a duplicate call while in flight is dropped.
    func requestIfNeeded(for item: Recommendation) {
        guard let provider else { return }
        let fingerprint = item.fingerprint

        if let existing = states[fingerprint], existing != .idle { return }
        guard !inFlight.contains(fingerprint) else { return }

        if let cached = readCache(fingerprint, provider: provider) {
            states[fingerprint] = .ready(cached)
            return
        }

        inFlight.insert(fingerprint)
        states[fingerprint] = .loading

        let subject = ExplanationSubject(
            path: item.path,
            name: item.name,
            sizeBytes: item.sizeBytes,
            fileCount: item.fileCount,
            daysSinceModified: item.daysSinceModified,
            localTitle: item.classification.title,
            localTier: item.tier,
            localWhatThisIs: item.classification.whatThisIs,
            localConsequence: item.classification.consequence,
            localRebuildCost: item.classification.rebuildCost,
            localConfidence: item.classification.confidence)

        Task { [weak self] in
            do {
                let started = Date()
                let explanation = try await provider.explain(subject)
                guard let self else { return }
                Log.app.notice("""
                explanation ok — provider=\(provider.identifier, privacy: .public) \
                seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) \
                confidence=\(String(format: "%.2f", explanation.confidence), privacy: .public)
                """)
                writeCache(fingerprint, explanation, provider: provider)
                states[fingerprint] = .ready(explanation)
                inFlight.remove(fingerprint)
            } catch {
                guard let self else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Log.app.error("explanation failed via \(provider.identifier, privacy: .public): \(message, privacy: .public)")
                states[fingerprint] = .failed(message)
                inFlight.remove(fingerprint)
            }
        }
    }

    /// Clears a failure so the panel's retry actually retries.
    func retry(for item: Recommendation) {
        states[item.fingerprint] = nil
        inFlight.remove(item.fingerprint)
        requestIfNeeded(for: item)
    }

    // MARK: - Cache

    private func readCache(_ fingerprint: String, provider: any ExplanationProvider) -> Explanation? {
        guard let container = DataStore.shared.state.container else { return nil }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<CachedExplanation>(
            predicate: #Predicate { $0.fingerprint == fingerprint })
        descriptor.fetchLimit = 1

        guard let row = try? context.fetch(descriptor).first else { return nil }

        // An explanation written by a different model is left in place but not
        // used: the prose came from somewhere else and the row records which
        // model, so silently presenting it as this model's answer would make
        // `modelIdentifier` a lie. With two providers this stopped being
        // theoretical — an on-device answer and a cloud answer for the same
        // folder are genuinely different text with different reliability.
        guard row.modelIdentifier == provider.identifier else { return nil }

        return Explanation(
            whatThisIs: row.whatThisIs,
            consequenceOfDeleting: row.consequenceOfDeleting,
            rebuildCost: row.rebuildCost,
            confidence: row.confidence)
    }

    /// A cache write that fails costs one repeated API call later. It is not
    /// worth failing the explanation the user is currently reading over.
    private func writeCache(_ fingerprint: String, _ explanation: Explanation,
                            provider: any ExplanationProvider) {
        guard let container = DataStore.shared.state.container else { return }
        let context = ModelContext(container)

        // `fingerprint` is `@Attribute(.unique)`, so a re-request for the same
        // subject must replace rather than insert a second row.
        var descriptor = FetchDescriptor<CachedExplanation>(
            predicate: #Predicate { $0.fingerprint == fingerprint })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }

        context.insert(CachedExplanation(
            fingerprint: fingerprint,
            whatThisIs: explanation.whatThisIs,
            consequenceOfDeleting: explanation.consequenceOfDeleting,
            rebuildCost: explanation.rebuildCost,
            confidence: explanation.confidence,
            modelIdentifier: provider.identifier))

        do {
            try context.save()
        } catch {
            Log.app.error("explanation cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Recommendation {
    /// Identity for the explanation cache (A05), matching
    /// `SnapshotItem.fingerprint` exactly so the two agree about what "the same
    /// item, unchanged" means.
    ///
    /// Size and mtime together are sufficient: content changing means one or
    /// the other moved.
    var fingerprint: String {
        let stamp = newestModifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "\(path)|\(sizeBytes)|\(stamp)"
    }
}
