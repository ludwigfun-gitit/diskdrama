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
            rebuildCost: "The next build of each affected project is a full one — minutes, not seconds.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "xcode.indexDataStore",
            matcher: .named("Index.noindex"),
            tier: .safe,
            title: "Xcode code index",
            whatThisIs: "The database behind jump-to-definition and autocomplete. It grows with every build and is never pruned — these routinely reach millions of tiny files.",
            consequence: "Xcode reindexes the project in the background the next time you open it. No source code is affected.",
            rebuildCost: "Indexing runs for a few minutes after you next open the project; autocomplete is incomplete until it finishes.",
            minimumSizeBytes: 50_000_000,
            isAtomicRegenerable: true
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
            consequence: "Regenerated on demand. Simulator devices and their installed apps are stored elsewhere and are not touched.",
            isAtomicRegenerable: true
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

        // Deliberately *after* the rule above, so an archive in Xcode's own
        // folder keeps that one — first match wins, and the location-anchored
        // rule is the more specific statement.
        //
        // This one catches the archives Xcode is not managing: a build script or
        // a manual `xcodebuild -archivePath` drops them beside the project, where
        // the Organizer never lists them and nothing ever prompts a clear-out. In
        // practice they are the ones that accumulate, precisely because the UI
        // that would show them doesn't know they exist.
        //
        // Same tier and same consequence as the managed ones: an archive carries
        // the debug symbols for one exact binary, so it is Review first, not
        // Safe. Rebuilding produces a *different* binary whose symbols no longer
        // match the build already in users' hands.
        ClassificationRule(
            key: "xcode.archives.stray",
            matcher: .suffix(".xcarchive"),
            tier: .reviewFirst,
            title: "Xcode archive outside Xcode's folder",
            whatThisIs: "An archived build with the debug symbols needed to read crash reports from that exact release. It sits outside ~/Library/Developer/Xcode/Archives, so Xcode's Organizer doesn't list it and won't offer to clean it up.",
            consequence: "Deleting it means crash reports from that shipped build can no longer be symbolicated. Rebuilding does not restore it — a new build produces different symbols.",
            rebuildCost: "Not rebuildable in any practical sense.",
            confidence: 0.9,
            minimumSizeBytes: 50_000_000
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
            minimumSizeBytes: 50_000_000,
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "npm.cache",
            matcher: .under("~/.npm/_cacache"),
            tier: .safe,
            title: "npm download cache",
            whatThisIs: "npm's copy of every package tarball it has downloaded, kept so reinstalls skip the network.",
            consequence: "Refills itself as you install packages. Nothing breaks; the next few installs are slower.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "yarn.cache",
            matcher: .under("~/Library/Caches/Yarn"),
            tier: .safe,
            title: "Yarn download cache",
            whatThisIs: "Yarn's cached package downloads.",
            consequence: "Refills as you install. Next installs go to the network.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "pnpm.store",
            matcher: .under("~/Library/pnpm/store"),
            tier: .safe,
            title: "pnpm content store",
            whatThisIs: "pnpm's shared package store, hard-linked into each project rather than copied.",
            consequence: "Refetched on the next install in any project that needs those packages.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "swiftpm.cache",
            matcher: .under("~/Library/Caches/org.swift.swiftpm"),
            tier: .safe,
            title: "Swift Package Manager cache",
            whatThisIs: "Checked-out clones of Swift packages your projects depend on.",
            consequence: "Re-cloned from their repositories on the next resolve.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "swift.buildDir",
            matcher: .named(".build"),
            tier: .safe,
            title: "Swift build output",
            whatThisIs: "Compiled objects and resolved dependencies for a Swift package.",
            consequence: "Recreated by the next swift build.",
            rebuildCost: "One full rebuild of that package.",
            minimumSizeBytes: 50_000_000,
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "rust.target",
            matcher: .namedUnder(name: "target", parent: "src"),
            tier: .safe,
            title: "Rust build output",
            whatThisIs: "Compiled artifacts for a Cargo project. Notoriously large — debug builds keep every intermediate.",
            consequence: "Recreated by the next cargo build.",
            rebuildCost: "A full rebuild, which for a large crate graph can be many minutes.",
            confidence: 0.85,
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "cargo.registryCache",
            matcher: .under("~/.cargo/registry/cache"),
            tier: .safe,
            title: "Cargo download cache",
            whatThisIs: "Downloaded crate archives kept for reuse across projects.",
            consequence: "Re-downloaded on the next build that needs them.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "gradle.caches",
            matcher: .under("~/.gradle/caches"),
            tier: .safe,
            title: "Gradle cache",
            whatThisIs: "Downloaded dependencies and build caches for Gradle projects.",
            consequence: "Rebuilt and re-downloaded on the next Gradle build.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "maven.repository",
            matcher: .under("~/.m2/repository"),
            tier: .safe,
            title: "Maven local repository",
            whatThisIs: "Every Java dependency Maven has downloaded, across all projects.",
            consequence: "Re-downloaded as builds need them. Locally-installed artifacts that were never published anywhere would be lost.",
            confidence: 0.8,
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "python.pipCache",
            matcher: .under("~/Library/Caches/pip"),
            tier: .safe,
            title: "pip download cache",
            whatThisIs: "Cached Python wheels and source archives.",
            consequence: "Re-downloaded on the next pip install.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "python.pycache",
            matcher: .named("__pycache__"),
            tier: .safe,
            title: "Python bytecode cache",
            whatThisIs: "Compiled bytecode Python writes next to your source.",
            consequence: "Regenerated automatically the next time the code runs.",
            minimumSizeBytes: 20_000_000,
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "homebrew.cache",
            matcher: .under("~/Library/Caches/Homebrew"),
            tier: .safe,
            title: "Homebrew download cache",
            whatThisIs: "Downloaded bottles and source archives from brew installs and upgrades.",
            consequence: "Re-downloaded if needed. `brew cleanup` does the same job.",
            isAtomicRegenerable: true
        ),

        ClassificationRule(
            key: "cocoapods.cache",
            matcher: .under("~/Library/Caches/CocoaPods"),
            tier: .safe,
            title: "CocoaPods cache",
            whatThisIs: "Cached pod specs and downloaded pod sources.",
            consequence: "Re-downloaded on the next pod install.",
            isAtomicRegenerable: true
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

        // Before generic.caches, which would otherwise call this an ordinary
        // application cache and offer a Delete button that cannot work.
        //
        // macOS refuses removal of this one even with Full Disk Access — cloudd
        // holds it open continuously (16 handles, observed) and the system
        // treats it as its own. Offering deletion produced exactly the failure
        // this app is supposed to prevent: a red button, a confirmation dialog,
        // and only then "you don't have permission to access it", after the user
        // had already decided to delete 64 GB.
        //
        // Tier 2 rather than Tier 3: this is not the user's data and there is
        // nothing to review. It is someone else's storage, which is precisely
        // what Tier 2 means — and Tier 2 carries no delete button. No owningApp,
        // because there is no app to open; the consequence text does the work.
        ClassificationRule(
            key: "apple.cloudkitCache",
            matcher: .under("~/Library/Caches/CloudKit"),
            tier: .appManaged,
            title: "iCloud sync cache",
            whatThisIs: "Working storage for iCloud's sync daemon. macOS owns it and keeps it open, so no application can remove it — DiskDrama included.",
            consequence: "Restart your Mac to clear it — that releases the daemon's hold, and the cache is rebuilt only as far as it is needed. Left alone it is still fine: macOS reclaims this on its own when the disk gets tight.",
            confidence: 0.95
        ),

        ClassificationRule(
            key: "generic.caches",
            // One row per app, not one per directory at every depth. `.under`
            // matched the container and every level beneath it, and with
            // `isTerminal: false` each of those levels became its own
            // recommendation from this same rule — 54 of 89 rows nested inside
            // another row, 15.7 GB counted more than once. Every specific cache
            // rule above is itself an immediate child of this directory, so
            // matching children only costs nothing in coverage.
            matcher: .childOf("~/Library/Caches"),
            tier: .safe,
            title: "Application cache",
            whatThisIs: "Cached data written by an installed application. Apps are expected to regenerate anything they keep here.",
            consequence: "The owning app rebuilds what it needs. Some apps briefly run slower afterwards.",
            // Deliberately lower: the folder is *conventionally* disposable, but
            // some apps misuse it for state they never rebuild. High enough to
            // land in Tier 1, low enough that the UI says so plainly.
            confidence: 0.75
        ),
    ]

    // MARK: - Classification

    /// Rules indexed by their stable key, for looking one up without re-matching
    /// a path. `SnapshotRestorer` needs this: a persisted item already knows
    /// which rule classified it, and re-running the matcher could silently pick
    /// a different rule if the table has changed since the scan.
    /// The smallest size any rule will fire at. The traversal needs this to know
    /// how small a folder it still has to look inside — deriving it from the
    /// rules means adding a rule with a lower floor can never silently become
    /// unreachable.
    static let smallestRuleMinimumBytes: Int64 =
        rules.map(\.minimumSizeBytes).min() ?? 20_000_000

    static let rulesByKey: [String: ClassificationRule] =
        Dictionary(rules.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

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
                return (rule, orphaned(result) ?? result)
            }
        }
        return nil
    }

    /// F12's failure case: Tier 2 means "the owning app clears this better than I
    /// could", which stops being true the moment that app is gone. The item is
    /// then re-tiered to Review first with an explanation that says exactly what
    /// happened, rather than keeping a tier whose entire premise has evaporated
    /// and offering an "Open <App>" button that opens nothing.
    ///
    /// Deliberately not a guess that the leftovers are safe. The data outlived
    /// its app; nobody can say what is in there now, and Review first is what the
    /// blueprint asks for.
    private static func orphaned(_ result: Classification) -> Classification? {
        guard result.tier == .appManaged,
              let app = result.owningApp,
              let bundleID = app.bundleID,
              !OwningAppLocator.isInstalled(bundleID: bundleID)
        else { return nil }

        return Classification(
            key: result.key,
            tier: .reviewFirst,
            title: result.title,
            whatThisIs: result.whatThisIs,
            consequence: "\(app.name) isn't installed any more, so nothing is looking after this folder. "
                + "It's probably leftovers and probably safe — but its app is gone and I can't verify that, so look before you delete.",
            rebuildCost: result.rebuildCost,
            owningApp: nil,   // no pointer to an app that isn't there
            confidence: min(result.confidence, 0.5))
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

    /// A directory holding a pathological number of entries is a finding, not
    /// just a slow patch of the scan.
    ///
    /// The `Index.noindex` case: millions of tiny files, unremarkable in Finder
    /// because Finder reports bytes and this is a problem of *entry count*.
    ///
    /// ## Not `.safe`, and not a short-circuit
    ///
    /// Both of those were wrong, and dangerously so. This was `tier: .safe` and
    /// was checked *before* classification and descent, so the first big
    /// slow-to-list folder at any level — on a normal Mac, `~/Library` itself —
    /// became a blanket one-click "safe to delete" covering 156 GB, in the tier
    /// whose own copy reads "nothing here is something you made". Nothing about
    /// a high entry count says the contents are disposable.
    ///
    /// It now takes the same posture as `unknown()` next door: `.reviewFirst`,
    /// confidence 0, look inside before deciding. That is the rule stated at the
    /// top of this file — a gap should produce an over-careful recommendation,
    /// never a dangerous one — and this finding is a gap, not knowledge.
    ///
    /// ## Driven by count, not by the clock
    ///
    /// The trigger used to be elapsed seconds, which is a measurement of the
    /// scan rather than a property of the disk. Step 18 demonstrated the
    /// consequence: parallelising the walk moved the count of "slow" directories
    /// from 34 to 17 on an unchanged disk, and two identical parallel runs gave
    /// 17 and 29 — recommendations that shifted because the Mac was busier, not
    /// because anything on disk had changed. The title already claimed "very
    /// large number of files"; the trigger now measures that.
    static func crowdedDirectoryFinding(path: String, name: String, fileCount: Int) -> Classification {
        Classification(
            key: "pathological.directory",
            tier: .reviewFirst,
            title: "\(name) — very large number of files",
            whatThisIs: "This folder holds \(ByteFormat.count(fileCount)) files. That is an enormous number of entries rather than a few large ones, which is why it looks unremarkable in Finder — Finder reports bytes.",
            consequence: "A folder this shape slows down backups, Spotlight and any tool that walks your disk. But a high file count says nothing about whether the contents matter: I could not identify what is in here, so treat it as yours until you have looked inside.",
            rebuildCost: nil,
            owningApp: nil,
            confidence: 0
        )
    }
}
