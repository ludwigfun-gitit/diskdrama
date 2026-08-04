import Foundation

/// F23 — "get me to N free".
///
/// Assembles the smallest-risk plan that reaches a target, in tier order: Safe
/// first, then App-managed (which DiskDrama cannot execute — those are pointers
/// to another app), then Review-first candidates the user must look at.
///
/// **It never silently overpromises.** If the target cannot be reached even by
/// taking everything the app would suggest, the plan says so, shows the gap, and
/// names the biggest things it is deliberately not offering. A planner that
/// quietly returns "here's a plan" for an unreachable target is worse than one
/// that refuses — the user finds out it didn't work only after doing the work.
struct TargetPlan {

    struct Step: Identifiable {
        var id: String { item.path }
        let item: Recommendation
        /// Safe items are actionable here. App-managed and Review-first are in
        /// the plan for arithmetic and honesty, but the user does those
        /// elsewhere — the checklist says which is which rather than implying
        /// one button does all of it.
        let isActionable: Bool
        let note: String
    }

    let targetBytes: Int64
    let currentFreeBytes: Int64
    let steps: [Step]
    /// Largest consumers deliberately left out, for the unreachable case.
    let notOffered: [(name: String, sizeBytes: Int64)]

    var plannedBytes: Int64 { steps.reduce(0) { $0 + $1.item.sizeBytes } }
    var actionableBytes: Int64 { steps.filter(\.isActionable).reduce(0) { $0 + $1.item.sizeBytes } }
    var projectedFreeBytes: Int64 { currentFreeBytes + plannedBytes }
    var isReachable: Bool { projectedFreeBytes >= targetBytes }
    var shortfallBytes: Int64 { max(0, targetBytes - projectedFreeBytes) }

    /// Builds the plan. Stops adding steps once the target is met — the point
    /// is the *smallest* plan that gets there, not a list of everything.
    static func build(target: Int64,
                      currentFree: Int64,
                      from set: RecommendationSet,
                      excluding ignored: Set<String>) -> TargetPlan {

        var steps: [Step] = []
        var running = currentFree

        // Tier order is risk order. Within a tier, biggest first, so the target
        // is reached in the fewest actions.
        for tier in [Tier.safe, .appManaged, .reviewFirst] {
            for item in set.inTier(tier).sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
                guard running < target else { break }
                // F18's ripple: a dismissed item never appears in a plan, even
                // when the target is otherwise out of reach. The user said no
                // once; a planner is not the place to re-ask.
                guard !ignored.contains(item.path) else { continue }

                steps.append(Step(item: item,
                                  isActionable: tier == .safe,
                                  note: note(for: tier, item: item)))
                running += item.sizeBytes
            }
        }

        return TargetPlan(
            targetBytes: target,
            currentFreeBytes: currentFree,
            steps: steps,
            notOffered: Array(set.largestNonRecommendable.prefix(2).map { ($0.name, $0.sizeBytes) }))
    }

    private static func note(for tier: Tier, item: Recommendation) -> String {
        switch tier {
        case .safe:
            return "Regenerates on its own"
        case .appManaged:
            return item.classification.owningApp.map { "You clear this one in \($0.name)" }
                ?? "Another app owns this"
        case .reviewFirst:
            return "Needs your eyes first"
        }
    }
}
