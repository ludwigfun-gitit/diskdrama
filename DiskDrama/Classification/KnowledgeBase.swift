import Foundation

/// The local, deterministic tiering layer (F08).
///
/// This is the half of the AI story that costs nothing. Most of what fills a
/// developer's disk is pattern-matchable by path — `DerivedData`, `node_modules`,
/// package-manager caches — and asking a language model to re-derive "build
/// artifacts regenerate" on every scan would be both slower and worse than a
/// table. The API is reserved for F09's per-item prose about things a user
/// actually opens.
///
/// ## Editorial rules for entries here
///
/// - **Consequence must be honest about what "safe" means.** Tier 1 does not mean
///   "free"; it means "regenerates without losing anything you made". A rebuild
///   that costs twenty minutes is worth saying out loud.
/// - **Confidence below `lowConfidenceFloor` forces Tier 3**, whatever the rule
///   claims, and the UI says outright that it cannot tell what the folder holds
///   (F09's failure case).
/// - **Tier 2 never gets a delete action.** It routes to the owning app. If that
///   app is gone, F12 re-tiers the item to 3 rather than quietly offering to
///   delete something it does not understand.
/// - **Everything unmatched is Tier 3.** The default is caution, so a gap in this
///   table produces an over-careful recommendation rather than a dangerous one.
enum KnowledgeBase {

    /// Below this, a rule's own tier is overridden to `.reviewFirst`.
    static let lowConfidenceFloor: Double = 0.6

    /// Enumerating a directory this slowly is itself a finding — see
    /// `slowDirectoryFinding`.
    static let pathologicalDirectorySeconds: TimeInterval = 5

    // MARK: - Rules
    //
    // Order matters only for readability; matching takes the first hit walking
    // down the tree, and `isTerminal` stops descent so a parent and its children
    // are never both recommended.

    static let rules: [ClassificationRule] = [

        // ── Tier 1 — Xcode ──────────────────────────────────────────────────

        ClassificationRule(
            key: "xcode.derivedData",
            matcher: .under("~/Library/Developer/Xcode/DerivedData"),
            tier: .safe,
            title: "Xcode derived data",
            whatThisIs: "Intermediate build output, indexes and caches Xcode writes while you work. One folder per project, and Xcode never cleans them up on its own.",
            consequence: "Xcode rebuilds it automatically the next time you open or build each project. Nothing you wrote lives here.",
            rebuildCost: "The next build of each affected project is a full one — minutes, not seconds."
        ),

        ClassificationRule(
            key: "xcode.indexDataStore",
            matcher: .named("Index.noindex"),
            tier: .safe,
            title: "Xcode code index",
            whatThisIs: "The database behind jump-to-definition and autocomplete. It grows with every build and is never pruned — these routinely reach millions of tiny files.",
            consequence: "Xcode reindexes the project in the background the next time you open it. No source code is affected.",
            rebuildCost: "Indexing runs for a few minutes after you next open the project; autocomplete is incomplete until it finishes.",
            minimumSizeBytes: 50_000_000
        ),

        ClassificationRule(
            key: "xcode.deviceSupport",
            matcher: .under("~/Library/Developer/Xcode/iOS DeviceSupport"),
            tier: .safe,
            title: "iOS device support files",
            whatThisIs: "Debug symbols Xcode copies off every iPhone or iPad you have ever connected, kept per OS version forever.",
            consequence: "Re-copied from the device the next time you connect one running that version. Versions you no longer own are simply gone.",
            rebuildCost: "First connection of a device afterwards takes a minute or two longer."
        ),

        ClassificationRule(
            key: "xcode.simulatorCaches",
            matcher: .under("~/Library/Developer/CoreSimulator/Caches"),
            tier: .safe,
            title: "Simulator caches",
            whatThisIs: "Cached runtime data for the iOS/watchOS simulators.",
            consequence: "Regenerated on demand. Simulator devices and their installed apps are stored elsewhere and are not touched."
        ),

        ClassificationRule(
            key: "xcode.archives",
            matcher: .under("~/Library/Developer/Xcode/Archives"),
            tier: .reviewFirst,
            title: "Xcode archives",
            whatThisIs: "Builds you archived for distribution, each with the debug symbols needed to read crash reports from that exact release.",
            consequence: "Deleting an archive means crash reports from that shipped build can no longer be symbolicated. It cannot be regenerated — the binary would have to be rebuilt identically.",
            rebuildCost: "Not rebuildable in any practical sense.",
            confidence: 0.9
        ),

        // ── Tier 1 — package managers and build output ──────────────────────

        ClassificationRule(
            key: "node.modules",
            matcher: .named("node_modules"),
            tier: .safe,
            title: "Installed npm packages",
            whatThisIs: "Third-party JavaScript packages installed for one project. Reconstructable in full from that project's package.json and lockfile.",
            consequence: "Restored by running npm install (or yarn/pnpm) in the project again.",
            rebuildCost: "A reinstall takes seconds to a few minutes, and needs a network connection.",
            minimumSizeBytes: 50_000_000
        ),

        ClassificationRule(
            key: "npm.cache",
            matcher: .under("~/.npm/_cacache"),
            tier: .safe,
            title: "npm download cache",
            whatThisIs: "npm's copy of every package tarball it has downloaded, kept so reinstalls skip the network.",
            consequence: "Refills itself as you install packages. Nothing breaks; the next few installs are slower."
        ),

        ClassificationRule(
            key: "yarn.cache",
            matcher: .under("~/Library/Caches/Yarn"),
            tier: .safe,
            title: "Yarn download cache",
            whatThisIs: "Yarn's cached package downloads.",
            consequence: "Refills as you install. Next installs go to the network."
        ),

        ClassificationRule(
            key: "pnpm.store",
            matcher: .under("~/Library/pnpm/store"),
            tier: .safe,
            title: "pnpm content store",
            whatThisIs: "pnpm's shared package store, hard-linked into each project rather than copied.",
            consequence: "Refetched on the next install in any project that needs those packages."
        ),

        ClassificationRule(
            key: "swiftpm.cache",
            matcher: .under("~/Library/Caches/org.swift.swiftpm"),
            tier: .safe,
            title: "Swift Package Manager cache",
            whatThisIs: "Checked-out clones of Swift packages your projects depend on.",
            consequence: "Re-cloned from their repositories on the next resolve."
        ),

        ClassificationRule(
            key: "swift.buildDir",
            matcher: .named(".build"),
            tier: .safe,
            title: "Swift build output",
            whatThisIs: "Compiled objects and resolved dependencies for a Swift package.",
            consequence: "Recreated by the next swift build.",
            rebuildCost: "One full rebuild of that package.",
            minimumSizeBytes: 50_000_000
        ),

        ClassificationRule(
            key: "rust.target",
            matcher: .namedUnder(name: "target", parent: "src"),
            tier: .safe,
            title: "Rust build output",
            whatThisIs: "Compiled artifacts for a Cargo project. Notoriously large — debug builds keep every intermediate.",
            consequence: "Recreated by the next cargo build.",
            rebuildCost: "A full rebuild, which for a large crate graph can be many minutes.",
            confidence: 0.85
        ),

        ClassificationRule(
            key: "cargo.registryCache",
            matcher: .under("~/.cargo/registry/cache"),
            tier: .safe,
            title: "Cargo download cache",
            whatThisIs: "Downloaded crate archives kept for reuse across projects.",
            consequence: "Re-downloaded on the next build that needs them."
        ),

        ClassificationRule(
            key: "gradle.caches",
            matcher: .under("~/.gradle/caches"),
            tier: .safe,
            title: "Gradle cache",
            whatThisIs: "Downloaded dependencies and build caches for Gradle projects.",
            consequence: "Rebuilt and re-downloaded on the next Gradle build."
        ),

        ClassificationRule(
            key: "maven.repository",
            matcher: .under("~/.m2/repository"),
            tier: .safe,
            title: "Maven local repository",
            whatThisIs: "Every Java dependency Maven has downloaded, across all projects.",
            consequence: "Re-downloaded as builds need them. Locally-installed artifacts that were never published anywhere would be lost.",
            confidence: 0.8
        ),

        ClassificationRule(
            key: "python.pipCache",
            matcher: .under("~/Library/Caches/pip"),
            tier: .safe,
            title: "pip download cache",
            whatThisIs: "Cached Python wheels and source archives.",
            consequence: "Re-downloaded on the next pip install."
        ),

        ClassificationRule(
            key: "python.pycache",
            matcher: .named("__pycache__"),
            tier: .safe,
            title: "Python bytecode cache",
            whatThisIs: "Compiled bytecode Python writes next to your source.",
            consequence: "Regenerated automatically the next time the code runs.",
            minimumSizeBytes: 20_000_000
        ),

        ClassificationRule(
            key: "homebrew.cache",
            matcher: .under("~/Library/Caches/Homebrew"),
            tier: .safe,
            title: "Homebrew download cache",
            whatThisIs: "Downloaded bottles and source archives from brew installs and upgrades.",
            consequence: "Re-downloaded if needed. `brew cleanup` does the same job."
        ),

        ClassificationRule(
            key: "cocoapods.cache",
            matcher: .under("~/Library/Caches/CocoaPods"),
            tier: .safe,
            title: "CocoaPods cache",
            whatThisIs: "Cached pod specs and downloaded pod sources.",
            consequence: "Re-downloaded on the next pod install."
        ),

        // ── Tier 2 — app-managed ────────────────────────────────────────────

        ClassificationRule(
            key: "docker.vmData",
            matcher: .under("~/Library/Containers/com.docker.docker/Data"),
            tier: .appManaged,
            title: "Docker disk image",
            whatThisIs: "The single large disk image holding all your Docker images, containers and volumes. It grows as you build and does not shrink when you delete images.",
            consequence: "Deleting this file by hand destroys every container and named volume, including database data you may not have backed up. Docker Desktop can reclaim the space properly instead.",
            owningApp: OwningApp(name: "Docker Desktop", bundleID: "com.docker.docker",
                                 pointer: "Settings → Resources → Advanced → Disk image size, or run `docker system prune`.")
        ),

        ClassificationRule(
            key: "podcasts.downloads",
            matcher: .under("~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts"),
            tier: .appManaged,
            title: "Podcast downloads",
            whatThisIs: "Episodes downloaded for offline listening.",
            consequence: "Podcasts re-downloads episodes on demand, but removing them through the app keeps its library in step.",
            owningApp: OwningApp(name: "Podcasts", bundleID: "com.apple.podcasts",
                                 pointer: "Podcasts → Settings → Downloads.")
        ),

        ClassificationRule(
            key: "creativecloud.cache",
            matcher: .under("~/Library/Caches/Adobe"),
            tier: .appManaged,
            title: "Adobe caches",
            whatThisIs: "Media caches and previews written by Creative Cloud applications.",
            consequence: "Regenerated on demand, but Premiere and After Effects track their own media cache and should be allowed to clear it themselves.",
            owningApp: OwningApp(name: "Adobe Creative Cloud", bundleID: nil,
                                 pointer: "In Premiere or After Effects: Preferences → Media Cache → Delete Unused.")
        ),

        ClassificationRule(
            key: "resolve.cache",
            matcher: .named("CacheClip"),
            tier: .appManaged,
            title: "DaVinci Resolve render cache",
            whatThisIs: "Rendered preview clips Resolve writes to keep timeline playback smooth.",
            consequence: "Re-rendered when you next open the project. Deleting it outside Resolve leaves the project referencing cache that is gone.",
            owningApp: OwningApp(name: "DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolve",
                                 pointer: "Playback → Delete Render Cache → All.")
        ),

        // ── Tier 3 — your data ──────────────────────────────────────────────

        ClassificationRule(
            key: "photos.library",
            matcher: .named("Photos Library.photoslibrary"),
            tier: .reviewFirst,
            title: "Photos library",
            whatThisIs: "Your entire Photos library — originals, edits and albums.",
            consequence: "Irreplaceable unless you have a backup or everything is in iCloud. This is never something to delete wholesale.",
            confidence: 0.99
        ),

        ClassificationRule(
            key: "generic.caches",
            matcher: .under("~/Library/Caches"),
            tier: .safe,
            title: "Application cache",
            whatThisIs: "Cached data written by an installed application. Apps are expected to regenerate anything they keep here.",
            consequence: "The owning app rebuilds what it needs. Some apps briefly run slower afterwards.",
            // Deliberately lower: the folder is *conventionally* disposable, but
            // some apps misuse it for state they never rebuild. High enough to
            // land in Tier 1, low enough that the UI says so plainly.
            confidence: 0.75,
            isTerminal: false
        ),
    ]

    // MARK: - Classification

    /// Classifies one node. Returns nil when nothing matched — the caller decides
    /// what to do with an unknown, and the answer is always Tier 3.
    static func classify(path: String, name: String) -> (rule: ClassificationRule, result: Classification)? {
        for rule in rules {
            if let result = rule.classification(for: path, name: name) {
                // A rule that is not confident enough does not get to claim a
                // reassuring tier. Demotion happens here, once, rather than at
                // every call site that reads `.tier`.
                guard result.confidence >= lowConfidenceFloor else {
                    return (rule, Classification(
                        key: result.key, tier: .reviewFirst, title: result.title,
                        whatThisIs: result.whatThisIs,
                        consequence: result.consequence,
                        rebuildCost: result.rebuildCost, owningApp: result.owningApp,
                        confidence: result.confidence))
                }
                return (rule, result)
            }
        }
        return nil
    }

    /// The fallback for anything unmatched and large enough to matter.
    ///
    /// F09's failure case, verbatim: say outright that it cannot be identified and
    /// tell the user to look before deciding. An advisor that invents a
    /// confident-sounding explanation for a folder it does not recognise is worse
    /// than one that admits the gap.
    static func unknown(name: String) -> Classification {
        Classification(
            key: "unknown",
            tier: .reviewFirst,
            title: name,
            whatThisIs: "I can't tell what this contains — it doesn't match anything I recognise.",
            consequence: "Unknown. Look inside before deciding, and assume it's yours until you've confirmed otherwise.",
            rebuildCost: nil,
            owningApp: nil,
            confidence: 0
        )
    }

    /// A directory the filesystem itself struggles with is a finding, not just a
    /// slow patch of the scan.
    ///
    /// Discovered the hard way in Step 3: an Xcode index datastore on this machine
    /// holds 3.7 million entries in a single directory with a 113 MB directory
    /// inode. Finder, System Settings → Storage and treemap tools all show it as
    /// unremarkable, because they report bytes and this is a problem of *entry
    /// count*. It slows every backup, every Spotlight pass and every scan that
    /// touches it. Surfacing it is squarely what this app is for.
    static func slowDirectoryFinding(path: String, name: String, seconds: TimeInterval) -> Classification {
        Classification(
            key: "pathological.directory",
            tier: .safe,
            title: "\(name) — very large number of files",
            whatThisIs: "This folder took \(Int(seconds)) seconds just to list. That means an enormous number of entries rather than large files, which is why it looks unremarkable in Finder.",
            consequence: "A folder this shape slows down backups, Spotlight and any tool that walks your disk. If it's a build or index folder it regenerates; check what it belongs to before removing it.",
            rebuildCost: nil,
            owningApp: nil,
            confidence: 0.7
        )
    }
}
