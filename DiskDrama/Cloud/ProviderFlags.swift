import Foundation

/// The File Provider's own view of an item.
///
/// `fileproviderctl evaluate <path>` is the only thing on macOS that exposes
/// `isKeepDownloaded` — the flag behind Finder's "Keep Downloaded". No public
/// API surfaces it, and Storage Settings reports only its *total*, never which
/// folders carry it.
///
/// It is an undocumented CLI, so every use here degrades rather than fails:
/// unavailable means "pin state unknown", which the UI states plainly. It must
/// never mean "nothing is pinned" — that is a claim, and the wrong one.
enum ProviderFlags {

    struct Item {
        var isKeepDownloaded = false
        var isDownloadRequested = false
        var isDownloading = false
        var isDownloaded = false
    }

    /// 0.04s per item measured, so a few hundred folders is a couple of seconds.
    /// Only ever called with folders that hold downloaded content — never the
    /// whole tree.
    static func evaluate(_ path: String) -> Item? {
        let out = CloudInventoryReader.run("/usr/bin/fileproviderctl", ["evaluate", path], timeout: 15)
        guard out.contains("fileproviderItems") else { return nil }
        func flag(_ name: String) -> Bool { out.contains("\(name) = 1;") }
        return Item(isKeepDownloaded:    flag("isKeepDownloaded"),
                    isDownloadRequested: flag("isDownloadRequested"),
                    isDownloading:       flag("isDownloading"),
                    isDownloaded:        flag("isDownloaded"))
    }

    /// Which of these folders the user pinned. `nil` when the tool is missing or
    /// unreadable — distinct from an empty set, and the difference is the whole
    /// point.
    static func keepDownloadedFolders(among folders: Set<String>) -> Set<String>? {
        guard !folders.isEmpty else { return [] }
        var pinned = Set<String>()
        var sawAnything = false
        for folder in folders {
            guard let item = evaluate(folder) else { continue }
            sawAnything = true
            if item.isKeepDownloaded { pinned.insert(folder) }
        }
        return sawAnything ? pinned : nil
    }

    /// Whether evicting this path could actually accomplish anything.
    ///
    /// This is the hazard that nearly shipped invisible. `evictUbiquitousItem`
    /// frees the local copy but does **not** cancel a queued provider transfer,
    /// and nothing in `brctl` or `fileproviderctl` exposes a cancel — so an item
    /// with a download in flight is freed and then silently fetched again, with
    /// no error anywhere. Measured: 17.46 GB evicted, and fifty minutes later the
    /// provider was re-downloading the same four files.
    ///
    /// Unknown counts as evictable. The tool being absent is not evidence of a
    /// transfer, and refusing every eviction because an undocumented CLI is
    /// missing would break the feature for a case that is mostly hypothetical.
    static func hasTransferInFlight(_ path: String) -> Bool {
        guard let item = evaluate(path) else { return false }
        return item.isDownloadRequested || item.isDownloading
    }
}
