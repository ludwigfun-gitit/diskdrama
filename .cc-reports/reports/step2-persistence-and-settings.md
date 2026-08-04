# Step 2 — Persistence layer and settings store

**Date:** 2026-08-04
**Commit:** `d1b4bb8`
**Flows:** foundation for F06/F16–F24, A03, A04
**Status:** built, installed, launched; store verified open with all eight models.

---

## The split: configuration vs. history

Rather than putting everything in SwiftData, persistence divides on what the data
*is*:

- **SwiftData — records.** `Snapshot`, `SnapshotItem`, `BlindSpot`,
  `CleanupEntry`, `WatchedPath`, `IgnoredPath`, `SnoozedPath`,
  `CachedExplanation`.
- **UserDefaults — configuration.** Thresholds, poll interval, scan roots,
  exclusions, deletion default, alert quiet period, free-space target, onboarding
  state.

Two concrete reasons settings are not in the store, both of which would have bitten
later:

1. **Read before the store exists.** Menubar thresholds are needed at launch, and
   the monitor must survive a store that fails to open. Settings living inside the
   store would take F01–F04 down with F06–F24.
2. **Exclusions are inner-loop data.** The traversal tests every directory it
   considers descending into against the exclusion set — millions of times per
   scan, on a background thread. Reaching into a `ModelContext` from there is the
   wrong shape entirely; a snapshotted `Set<String>` handed into the scan is right.

This produces a deliberate asymmetry between two flows that sound similar. F18
("never suggest this") is SwiftData — user history, read once per scan. F19
("don't even look") is configuration — read constantly. The blueprint already
distinguishes them behaviourally; they turn out to differ structurally too.

## Snapshots persist pruned, not whole

Called out in Step 0 and now built in. The full tree stays in memory for the
session; what gets written is every recommendation item regardless of size, plus
every node above a 50 MB floor. That is exactly what F20's delta needs — the delta
is about meaningful consumers regrowing, not about small files appearing.

The floor is **stored on the snapshot**, not read from current settings at compare
time. Comparing two snapshots written under different floors without knowing it
would manufacture deltas that never happened.

Roll-up totals (`totalScannedBytes`, `visitedEntryCount`) are computed over the
*full* tree, not the pruned set — otherwise every headline figure would silently
under-report everything below the floor.

## A finding: the preflight named one File Provider root, there are two

The preflight locked `~/Library/Mobile Documents` out of the default scan roots
because that is where §5.1's XPC hang risk concentrates. Correct, but incomplete
on a modern Mac: since macOS 12.3 every third-party provider — Google Drive,
OneDrive, Dropbox — mounts through File Provider under
**`~/Library/CloudStorage`**. Same daemon, same hang, different path.

Verified on this machine rather than assumed:

```
~/Google Drive          → symlink → ~/Library/CloudStorage/GoogleDrive-…
~/OneDrive - Ludwig.Fun → symlink → ~/Library/CloudStorage/OneDrive-…
~/SynologyDrive         → real directory (local sync client, real local files)
~/iCloud Drive (Archive)→ real directory (local leftover, real files)
```

So the default exclusion set names **the two provider roots** and the scan does
**not follow symlinks**. Between them that covers every vendor without hardcoding
a single vendor name — and `SynologyDrive` and `iCloud Drive (Archive)`, which are
genuinely local files worth scanning, stay in scope.

Not following symlinks is independently correct for a disk-usage scanner: it
prevents double-counting and cycles.

I am reading this as setting a default that A03 explicitly left to us, not as
reopening A03. Flagging it because it extends what the preflight wrote.

## Store health is not fatal

`DataStore` exposes `.ready` / `.failed` rather than force-trying — Visuals'
§10.5 lesson. The monitor starts before the store is touched and does not depend
on it, so a broken store degrades the app to monitor-only instead of preventing
launch. Launch diagnostics report `store=ready` or `store=FAILED`.

`BackgroundStore` is a `@ModelActor` for off-main writes; a snapshot write is
thousands of inserts and `ModelContext` is not `Sendable`, so it cannot simply be
handed to a task. History is capped at 5 snapshots — the delta always compares to
the immediately previous scan (A07, pinned baselines are Future), so unbounded
history buys nothing and costs disk on a machine already short of it.

## Verified

```
store opened
launch — total=494.38 GB available=31.86 GB strict=28.05 GB purgeable=3.81 GB
         fullDiskAccess=false fonts(SpaceGrotesk=true, Epilogue=true)
         store=ready roots=1 exclusions=2
```

All eight models materialize as tables (`ZSNAPSHOT`, `ZSNAPSHOTITEM`,
`ZBLINDSPOT`, `ZCLEANUPENTRY`, `ZWATCHEDPATH`, `ZIGNOREDPATH`, `ZSNOOZEDPATH`,
`ZCACHEDEXPLANATION`). Zero build warnings under Swift 6.

## Next

Step 3 — the scan engine. `fts(3)` traversal, exclusions, blind spots,
pause/cancel, throttled progress.
