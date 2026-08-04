import Foundation

/// A point-in-time reading of the boot volume's capacity.
///
/// ## Why there are two "free" numbers (DD.B001)
///
/// APFS reports free space two different ways and they disagree by however much
/// *purgeable* space exists — local Time Machine snapshots, cached downloads,
/// the sleep image, large files sitting in the Trash. macOS reclaims purgeable
/// space automatically when a write needs it, so the user-facing surfaces
/// (Finder, System Settings → Storage) count it as available. `df`, the APFS
/// container's own free counter, and `URLResourceValues.volumeAvailableCapacity`
/// do not.
///
/// Measured on Caballero, 2026-08-04 — same instant, same volume:
///
/// | source                                       | value    |
/// |----------------------------------------------|----------|
/// | `volumeAvailableCapacity`                    | 29.42 GB |
/// | `df` / APFS container free / system_profiler | 29.42 GB |
/// | Finder "free space"                          | 33.19 GB |
/// | `volumeAvailableCapacityForImportantUsage`   | 34.24 GB |
///
/// v0 used `volumeAvailableCapacity`, which is why its readout sat ~22 GB below
/// macOS Storage on Hombre (a machine with a much larger purgeable pool than
/// this one's ~4.8 GB). So `available` is what the user sees everywhere else and
/// is what DiskDrama displays.
///
/// But the strict number is not thrown away, because F24 needs it. After a
/// deletion, "did the space actually come back?" cannot be answered against a
/// figure that silently includes a pool macOS is shuffling on its own — the
/// displayed number can move without anything being reclaimed, and can fail to
/// move even when it was. Verification compares strict-to-strict; the UI shows
/// `available`. Reporting one number for both jobs is the bug underneath DD.B001,
/// not just the choice of key.
struct DiskInfo: Sendable, Equatable {

    /// Total capacity of the volume.
    let totalBytes: Int64

    /// Free space **including** purgeable. Matches Finder and System Settings →
    /// Storage. This is the number to display.
    let availableBytes: Int64

    /// Free space **excluding** purgeable. Matches `df`. This is the number to
    /// do arithmetic against when verifying that a deletion actually freed space.
    let strictAvailableBytes: Int64

    /// When this reading was taken.
    let readAt: Date

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    /// Space macOS considers reclaimable on its own. Shown to explain why
    /// DiskDrama's figure and `df` disagree, rather than leaving it a mystery.
    var purgeableBytes: Int64 { max(0, availableBytes - strictAvailableBytes) }

    // MARK: - Reading

    /// The data volume of the boot disk. `/` and `/System/Volumes/Data` report
    /// identical capacity figures on APFS (the firmlinked system volume shares
    /// the container), but the data volume is the one whose contents a user can
    /// actually act on, so it stays the canonical target.
    static let bootVolumePath = "/System/Volumes/Data"

    /// Reads current volume capacity.
    ///
    /// Cheap and local — this touches the volume root, never an iCloud-backed
    /// path, so `architectural-rules.md` §5.1's File-Provider XPC concern does
    /// not apply here. It is safe to call from the main thread, which the
    /// menubar poll does.
    static func read(path: String = bootVolumePath) -> DiskInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]

        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let strict = values.volumeAvailableCapacity
        else { return nil }

        // If the important-usage key is ever unavailable, fall back to the strict
        // figure rather than reporting nothing — an understated free-space number
        // is a far smaller failure than a blank menubar.
        let available = values.volumeAvailableCapacityForImportantUsage
            .map { Int64($0) } ?? Int64(strict)

        return DiskInfo(
            totalBytes: Int64(total),
            availableBytes: max(available, Int64(strict)),
            strictAvailableBytes: Int64(strict),
            readAt: Date()
        )
    }
}
