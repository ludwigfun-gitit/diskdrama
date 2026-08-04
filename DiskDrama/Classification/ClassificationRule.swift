import Foundation

/// What the local knowledge base concluded about a directory.
///
/// Everything here is deterministic and free — no API call, no tokens. Per the
/// preflight's two-layer split, tier classification happens for the whole tree at
/// scan time, and the Anthropic API is only ever asked for the deeper per-item
/// prose of F09, on first view, for items the user actually opens.
struct Classification: Sendable {
    /// Stable identifier for the rule that matched. Doubles as the cache key that
    /// lets a generated explanation survive across scans.
    let key: String
    let tier: Tier
    /// Human title, preferred over the raw folder name — "Xcode derived data"
    /// says more than "DerivedData".
    let title: String
    /// F09: what this is, in plain language, no filesystem jargon.
    let whatThisIs: String
    /// F09: what happens after deletion. Regenerates? Re-downloads? Gone forever?
    let consequence: String
    /// F09: rebuild cost, where there is one.
    let rebuildCost: String?
    /// Tier 2 only — which app owns this, for F12's "Open <App>" pointer.
    let owningApp: OwningApp?
    /// 0…1. Below `KnowledgeBase.lowConfidenceFloor` the item is forced to Tier 3
    /// and the UI says outright that it cannot tell what the folder contains.
    let confidence: Double
}

/// The app that owns a Tier 2 item, and where in it the user should go.
///
/// DiskDrama never reaches into another app's managed storage — Tier 2 carries
/// pointers, never delete buttons (blueprint's "Not this app").
struct OwningApp: Sendable {
    let name: String
    /// Bundle id, used to locate and activate it. Nil when the app is not
    /// identifiable, which re-tiers the item to 3 per F12's failure case.
    let bundleID: String?
    /// One line telling the user where to go once the app is open.
    let pointer: String
}

/// How a rule decides whether it applies to a path.
///
/// Matching is on **raw path strings**, never `URL` — §5.1 again. Classification
/// runs over a tree of hundreds of thousands of nodes, so this is also the hot
/// path where constructing URLs would be most expensive as well as most dangerous.
enum PathMatcher: Sendable {
    /// Exact absolute path, `~` expanded.
    case exact(String)
    /// The final path component equals this, at any depth. `node_modules`.
    case named(String)
    /// Path begins with this, `~` expanded. Catches a whole subtree.
    case under(String)
    /// Final component equals `name` AND some ancestor's final component equals
    /// `parent`. Distinguishes a Rust `target/` (next to `src/`) from a folder
    /// someone happened to call target.
    case namedUnder(name: String, parent: String)

    func matches(path: String, name: String) -> Bool {
        switch self {
        case .exact(let value):
            return path == Self.expand(value)
        case .named(let value):
            return name == value
        case .under(let value):
            let root = Self.expand(value)
            return path == root || path.hasPrefix(root + "/")
        case .namedUnder(let value, let parent):
            guard name == value else { return false }
            return path.contains("/" + parent + "/")
        }
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~")
            ? NSHomeDirectory() + String(path.dropFirst())
            : path
    }
}

/// One entry in the knowledge base.
struct ClassificationRule: Sendable {
    let key: String
    let matcher: PathMatcher
    let tier: Tier
    let title: String
    let whatThisIs: String
    let consequence: String
    let rebuildCost: String?
    let owningApp: OwningApp?
    let confidence: Double

    /// Items below this are not worth a recommendation row of their own, however
    /// confident the match. Overridable per rule because some things matter at a
    /// smaller size than others.
    let minimumSizeBytes: Int64

    /// When true, matching stops here and children are not examined.
    ///
    /// Without this the app would recommend `DerivedData` *and* each of the forty
    /// project folders inside it, triple-counting the same gigabytes across the
    /// same list — the single most obvious way a cleanup tool loses trust.
    let isTerminal: Bool

    init(key: String, matcher: PathMatcher, tier: Tier, title: String,
         whatThisIs: String, consequence: String, rebuildCost: String? = nil,
         owningApp: OwningApp? = nil, confidence: Double = 0.95,
         minimumSizeBytes: Int64 = 100_000_000, isTerminal: Bool = true) {
        self.key = key
        self.matcher = matcher
        self.tier = tier
        self.title = title
        self.whatThisIs = whatThisIs
        self.consequence = consequence
        self.rebuildCost = rebuildCost
        self.owningApp = owningApp
        self.confidence = confidence
        self.minimumSizeBytes = minimumSizeBytes
        self.isTerminal = isTerminal
    }

    func classification(for path: String, name: String) -> Classification? {
        guard matcher.matches(path: path, name: name) else { return nil }
        return Classification(key: key, tier: tier, title: title,
                              whatThisIs: whatThisIs, consequence: consequence,
                              rebuildCost: rebuildCost, owningApp: owningApp,
                              confidence: confidence)
    }
}
