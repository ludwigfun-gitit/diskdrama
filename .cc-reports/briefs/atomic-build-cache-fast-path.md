# DiskDrama — Fast-path known build/package caches (scan + delete)

## Context
Real-world trigger: Xcode's `DerivedData` and especially `Index.noindex`
routinely contain millions of tiny files (already called out in
`KnowledgeBase.swift`'s own comments). Today's walker builds a full
per-directory `ScanNode` tree for these before classification ever runs —
classification happens *after* the whole walk completes
(`RecommendationBuilder.build(from: result)` in `ScanEngine.finish`), even
though `KnowledgeBase` already knows by path pattern, before ever touching
the disk, that these are Tier 1 "safe, regenerates automatically, no
per-file value" folders. That's real, avoidable overhead for exactly the
folders most likely to be huge.

Deletion is already atomic per item (`isTerminal` on the matched rule stops
descent, so `DerivedData` is one recommendation, not millions) — that part
is fine. The actual slowness there is Trash mode specifically:
`FileManager.trashItem` does per-item "Put Back" bookkeeping that gets
brutal at high file counts. `removeItem` (permanent) skips that.

Two physical facts worth being upfront about, so the fix targets the right
thing: there is no OS-level shortcut for "recursive size of this directory"
on APFS — some walk is unavoidable for a byte-accurate total, same as `du`.
And truly deleting millions of inodes is not instantaneous either, however
it's done. The goal here is removing the *avoidable* overhead layered on
top of that unavoidable floor, not claiming to beat physics.

## Part A — Atomic-root fast path for scanning (required)

1. Add a flag to `ClassificationRule` (name your call — something like
   `isAtomicRegenerable: Bool = false`) marking rules where the matched
   subtree needs no per-file detail and nothing inside it is worth
   preserving. Set it `true` on the Tier-1 `.safe` rules that are whole-
   directory/package-cache patterns: the "Tier 1 — Xcode" section
   (`xcode.derivedData`, `xcode.indexDataStore`, `xcode.simulatorCaches`;
   leave `xcode.deviceSupport` and `xcode.archives` as they are —
   `deviceSupport` isn't the runaway-file-count case and `archives` is
   `.reviewFirst`, not safe) and the "Tier 1 — package managers and build
   output" section (`node.modules`, npm/yarn/pnpm caches, SwiftPM cache,
   `.build`, cargo/gradle/m2/pip caches, `__pycache__`, Homebrew cache,
   CocoaPods cache, Docker data — use your judgment on the exact list, the
   pattern is "deterministic path match, Tier 1 safe, whole thing is one
   regenerable unit"). Leave the generic `~/Library/Caches` catch-all
   alone — it's `isTerminal: false` on purpose, it keeps descending to
   classify what's inside case by case, and that behavior must not change.

2. In `FileTreeWalker`'s `FTS_D` case: before the normal per-directory
   `ScanNode` descent, check the path against the atomic-eligible rules
   (compute the filtered list once before the walk loop, same style as
   `hasFullDiskAccess`/`skipSet` are precomputed today). On a match:
   `fts_set(fts, entry, FTS_SKIP)` to stop the main loop's normal descent
   (same mechanism already used for excluded/protected paths), then run a
   lightweight size-only sum for that subtree — no `ScanNode` per
   subdirectory, no children arrays, just accumulate `st_blocks`/file count
   and produce one `ScanNode` for the root with `sizeBytes` set and no
   children (matching what the existing `inMemoryDetailFloorBytes` pruning
   already produces for small subtrees today, just arrived at without ever
   building the detail). This still visits every file — that part is
   unavoidable — but it stops paying Swift-side allocation/bookkeeping for
   structure nobody will ever look at, which is the real, provable win.

3. Keep this serial (single-threaded, same as the rest of the walk) for
   this first pass. Still report a slow-directory finding if one of these
   atomic sub-walks itself crosses `slowDirectoryThreshold` — one entry for
   the whole root, not per-subdirectory.

4. Verify `RecommendationBuilder` still classifies these nodes correctly
   unchanged — it should, since it matches by path/name the same way
   regardless of how the node's size was computed. Confirm with an actual
   large `DerivedData` or `Index.noindex` on this machine: compare scan
   time and memory before/after, and confirm the recommendation, size, and
   delete action for that item are unchanged from what a full scan produced
   previously.

## Part B — Parallel summation (only if Part A isn't enough)

Do NOT build this speculatively. Measure Part A first against a real large
`DerivedData`/`Index.noindex` on this machine. If wall-clock is still bad
enough to matter, come back and report that with the numbers — parallel
`fts` sub-walks across independent atomic roots (GCD, not `Task.detached`,
per §3.1) is the next lever, but it touches shared mutable walk state
(`bytesSeen`, `blindSpots`, `slowDirectories`, `visited`) that is currently
safely single-threaded, and introducing concurrency there needs real care
against races — not a first-pass change to a file whose own header calls it
"the single most important architectural decision in the app." Document the
measurement either way (good enough vs. not) rather than silently skipping
this section.

## Part C — Trash-bypass default for atomic-regenerable items (confirmed)

Ludwig's call: for items classified with the new `isAtomicRegenerable` flag
specifically, the deletion confirmation sheet should default to permanent
delete, not Trash — Xcode/npm/etc. rebuild these with nothing of the user's
lost, and Trash-moving a multi-million-file cache is needlessly slow for no
real safety benefit. This is a **per-item default**, not a change to the
global `Settings.shared.defaultDeletionMode` or its Settings UI — every
other kind of item keeps Trash as the default exactly as today, and the
`TrashToggle` in `DeleteConfirmSheet` stays fully interactive so the user
can still flip an atomic-regenerable item back to Trash for that one
instance if they want.

Concretely: wherever `model.moveToTrash` gets seeded when a deletion sheet
opens for a given `Recommendation` (`AppModel`, currently seeded from
`Settings.shared.defaultDeletionMode`), seed it `false` instead when the
item's classification has `isAtomicRegenerable == true`. Everything else
about the confirmation flow — guards, drift verification, the
`verificationCeiling` skip for huge counts, logging — stays as it is.

## Constraints
- `FileTreeWalker.swift` and `DeletionService.swift` are the two most
  hardened files in this codebase by their own header comments — treat
  changes here with the same care already documented there, not less.
- No change to blind-spot handling, exclusions, or the `<10MB` pruning path
  for anything that isn't atomic-eligible.
- No change to the guards, drift-verification, or "one legal call site"
  structure in `DeletionService` — only the seeded default changes, for the
  specific case described.
- Live-verify with a real project: build/install/launch, run a scan
  against an actual Xcode project with real `DerivedData`, confirm size and
  recommendation match a full scan, confirm the confirmation sheet
  defaults to permanent delete for it and Trash for everything else, time
  the before/after if practical.
- Same reporting cadence: only stop and report for a genuine risk,
  deviation, or blocker — but Part A's before/after measurement and the
  Part B go/no-go call are worth a report regardless, since they're the
  point of this brief.

## Not in scope
Parallel summation unless Part A proves insufficient (see Part B). Any
change to the global default-deletion-mode setting or its Settings UI.
Any change to which folders are classified Tier 1 vs. reviewFirst — this
only changes how already-Tier-1-safe folders are sized and defaulted on
delete, not what gets classified as safe.
