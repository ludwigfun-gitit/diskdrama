import Foundation

/// One cloud file that is actually taking up disk space.
struct CloudFile: Sendable, Hashable {
    let path: String
    /// What the file would be if fully present. What Finder shows.
    let logicalBytes: Int64
    /// What it costs this Mac right now: `st_blocks * 512`. Zero for an evicted
    /// placeholder, which is most of them.
    let physicalBytes: Int64
    /// A queued or running provider transfer. Eviction cannot win against one.
    var isTransferPending = false
}

/// A folder rollup — the unit the pane lists, because per-file is unreadable at
/// twelve thousand rows.
struct CloudFolder: Sendable, Hashable {
    let path: String
    let physicalBytes: Int64
    let fileCount: Int
    /// `isKeepDownloaded`: the user pinned this in Finder, so evicting inside it
    /// is temporary — the pin pulls the content back.
    var isKeepDownloaded = false
}

struct CloudInventory: Sendable {
    var folders: [CloudFolder] = []
    var downloadedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount = 0
    var downloadedFileCount = 0
    /// True when pin state could not be read. The pane must say so rather than
    /// present "nothing is pinned" — which is what an empty list would imply.
    var pinStateUnavailable = false
}

/// Reads what the cloud roots actually cost this Mac.
///
/// Three rules, each bought with a measurement (see the spec):
///
/// 1. **Never enumerate a cloud directory.** `readdir(3)` on a File Provider root
///    blocked for 3m47s before being killed. `fts`, `FileManager` enumeration and
///    `readdir` are all the same hazard, so the path list comes from Spotlight,
///    which asks an index and never touches the provider.
/// 2. **Never read a cloud file's contents.** A plain `read` of an evicted 8 MB
///    file blocked for 6m40s on a busy provider. `lstat` alone — 0.0–0.1 ms
///    across ~24,000 calls, never once slow.
/// 3. **Never trust `kMDItemPhysicalSize`.** It echoes the logical size for cloud
///    files. It claimed 98.4 GB of content that `lstat` proved was zero bytes.
///
/// All of this runs off the main thread. Nothing here touches `URL` for anything
/// but eviction, per architectural-rules §5.1.
enum CloudInventoryReader {

    /// iCloud Drive only in v1. `~/Library/CloudStorage` is deferred until
    /// eviction is verified against each third-party provider — Google Drive,
    /// OneDrive and Dropbox all sit behind their own File Provider extensions and
    /// none of them is known to honour `evictUbiquitousItem`.
    static var root: String { NSHomeDirectory() + "/Library/Mobile Documents" }

    static func read() -> CloudInventory {
        var inventory = CloudInventory()

        let paths = spotlightPaths(under: root)
        inventory.fileCount = paths.count

        var byFolder: [String: (bytes: Int64, count: Int)] = [:]
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let physical = Int64(info.st_blocks) * 512
            inventory.logicalBytes += Int64(info.st_size)
            guard physical > 0 else { continue }
            inventory.downloadedBytes += physical
            inventory.downloadedFileCount += 1
            let folder = (path as NSString).deletingLastPathComponent
            byFolder[folder, default: (0, 0)].bytes += physical
            byFolder[folder, default: (0, 0)].count += 1
        }

        let pins = ProviderFlags.keepDownloadedFolders(among: Set(byFolder.keys))
        inventory.pinStateUnavailable = pins == nil

        inventory.folders = byFolder
            .map { CloudFolder(path: $0.key,
                               physicalBytes: $0.value.bytes,
                               fileCount: $0.value.count,
                               isKeepDownloaded: pins?.contains($0.key) ?? false) }
            .sorted { $0.physicalBytes > $1.physicalBytes }

        return inventory
    }

    /// Every indexed file under a root, by asking the Spotlight index rather than
    /// the filesystem. 12,759 paths in 1.1s, and no provider involvement at all.
    ///
    /// The result is a **floor**: anything Spotlight has not indexed is missing
    /// from it, and the UI has to say so rather than present it as a measurement.
    static func spotlightPaths(under root: String) -> [String] {
        let out = run("/usr/bin/mdfind", ["-onlyin", root, "kMDItemLogicalSize > 0"])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 60) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.app.error("cloud helper failed to launch: \(launchPath, privacy: .public)")
            return ""
        }
        // Read before waiting: a full pipe buffer deadlocks a process that is
        // still writing, and mdfind's output here runs to hundreds of kilobytes.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            Log.app.error("cloud helper timed out: \(launchPath, privacy: .public)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
