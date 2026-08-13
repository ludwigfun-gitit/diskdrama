import Foundation

/// Removes the local copy of cloud content. **Never deletes anything.**
///
/// The distinction this type exists to protect:
///
/// | | effect |
/// |---|---|
/// | evict | local copy freed, file stays in iCloud, returns on demand |
/// | delete | gone from iCloud and from every other device on the account |
///
/// Which is why nothing here touches `removeItem` or `trashItem`, and why cloud
/// content never routes through `DeletionService` — that path is built around
/// deletion and carries deletion's vocabulary all the way down.
enum CloudEvictor {

    struct Outcome: Sendable {
        var freedBytes: Int64 = 0
        var evicted: [String] = []
        /// Skipped because a provider transfer was already in flight. Evicting
        /// these would report success and then quietly undo itself.
        var skippedInTransfer: [String] = []
        /// Eviction was attempted and the bytes did not go away.
        var didNotHold: [String] = []
        var failed: [(path: String, message: String)] = []
    }

    /// How long to wait before believing an eviction.
    ///
    /// `evictUbiquitousItem` returns immediately; the blocks go a moment later.
    /// Crediting freed bytes without re-reading is how a tool ends up reporting
    /// space it never recovered.
    private static let settleSeconds: UInt32 = 2

    static func physicalBytes(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// Evicts every downloaded file under these folders.
    ///
    /// Runs off the main thread — `evictUbiquitousItem` talks to the provider and
    /// blocks (§2.2). The caller hops back to the main actor with the outcome.
    static func evict(foldersUnder paths: [String], in inventory: CloudInventory) -> Outcome {
        var outcome = Outcome()
        let wanted = Set(paths)
        let files = CloudInventoryReader.spotlightPaths(under: CloudInventoryReader.root)
            .filter { wanted.contains(($0 as NSString).deletingLastPathComponent) }
            .filter { physicalBytes($0) > 0 }

        for file in files {
            if ProviderFlags.hasTransferInFlight(file) {
                outcome.skippedInTransfer.append(file)
                continue
            }
            let before = physicalBytes(file)
            do {
                try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: file))
            } catch {
                outcome.failed.append((file, error.localizedDescription))
                continue
            }
            sleep(settleSeconds)
            if physicalBytes(file) == 0 {
                outcome.freedBytes += before
                outcome.evicted.append(file)
            } else {
                outcome.didNotHold.append(file)
            }
        }
        return outcome
    }
}
