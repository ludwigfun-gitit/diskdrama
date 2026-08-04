# Step 3 — Scan engine

**Date:** 2026-08-04
**Commit:** `0e988f3`
**Flows:** F06, F07 (+ the mechanism behind F05's reduced mode)
**Status:** built, installed, exercised against a controlled tree, `~/Library/Developer`, and the real home directory.

This step took the longest and found the most. Three of the findings are things
the spec could not have predicted, and one of them would have made the app
unusable on Ludwig's own machine.

---

## Correctness first

Verified against `du` on a purpose-built tree with known answers, rather than
eyeballing plausible numbers:

| Property | Expected | Got |
|---|---|---|
| Total (with one folder excluded) | 40,894,464 B | **40.9 MB — exact** |
| Hard link to a 20 MB file | counted once | counted once |
| Symlink to a 20 MB folder | not followed | not followed |
| Excluded folder (50 MB) | absent, recorded | blind spot |
| `chmod 000` folder | recorded, no crash | blind spot |

On `~/Library/Developer`: **74,207 entries, 23.92 GB, 2.1 s** (`du` reports
23.75 GB). Against bare `fts` doing the same walk in 1.20 s, so the tree-building
and accounting layer costs ~7% — it is not the bottleneck.

## Finding 1 — TCC-protected folders hang; they do not fail

**This is the one that mattered most.** The reasonable assumption is that
touching a protected folder without permission returns `EPERM`, which any
scanner handles as an ordinary unreadable directory. It does not.

Same traversal code, same path, same machine:

| Context | `~/Music` |
|---|---|
| A process holding Full Disk Access | 769 entries, 2.24 GB, **0.04 s** |
| DiskDrama, no grant | **blocked in `open()` 10+ minutes, 0% CPU** |

Not slow — blocked, in the kernel, indefinitely. And `~/Desktop`, `~/Documents`
and `~/Downloads` are *also* protected and sit directly in the default scan root,
so an ungranted scan hung within seconds of starting, every single time. The
first three full-home attempts all died this way.

Without a grant, those locations are now skipped up front and recorded as blind
spots naming the missing permission. That is not a workaround bolted on the side —
it is F05's specified reduced mode verbatim: *"scan works but marks unreadable
locations as blind spots and says what it's missing."* The hang is simply what
forced the honest behaviour to be built in Step 3 instead of Step 14.

I could not pin the exact tccd mechanism (no consent prompt appears in the TCC
log, and no dialog is on screen), so I am **not** asserting one. The behaviour is
reproducible and the discriminator is unambiguous: identical code, FDA present vs
absent. `ScanEngine`'s stall watchdog stays as the backstop for any protected path
not on the list.

## Finding 2 — a stall cannot be reported by the thread that is stalled

The progress callback fires from inside the walk loop, so it goes quiet at exactly
the moment there is something worth saying. The first version had no other
channel, so a wedged walk was indistinguishable from a dead app.

The walk now publishes what it is about to do into a lock the **main actor polls
independently**, twice a second. When the walking thread is stuck in the kernel,
the dropdown still says `Still reading "v5" — 47s. It may be very large.`

I got this wrong once on the way: the first cut timed from *directory entry*,
which reported a large flat folder as a six-minute stall while it was making
perfectly steady progress. It now times from any forward movement, which is what
"stalled" actually means — and it stays correct for a real stall by construction,
because the heartbeat lives inside the loop that stops.

## Finding 3 — cancel cannot work while blocked in `open()`

F07 says cancel discards partial results. But a cancel flag can only be *set*, not
*read*, when the loop that would read it is not running. There is no way to
interrupt an in-flight uninterruptible syscall.

So past the abandon threshold the engine **disowns** the walk rather than asking
it to stop: a generation counter is bumped, the app returns to idle immediately,
and the orphaned walk's eventual result is discarded on arrival. It costs one
background thread parked in the kernel until the filesystem lets go — the correct
trade against a permanently frozen app, and precisely §2.3's *"abandon and
continue option after 10s."*

Tested live against a genuinely wedged walk: Stop Scan returned the app to idle
instantly and the dropdown read *"Scan abandoned — that folder wasn't
responding."*

## A bug of mine that made all of this look worse than it was

`withObservationTracking` fires once per registration and must re-arm. I re-armed
at the *end of the success path*, so the first tick that failed the guard ended
observation permanently — and the dropdown sat on "Scanning…" for fifteen minutes.

The stall underneath was real, but this bug is what made it look like a dead app
rather than a slow folder. Re-arm is now unconditional and first. Worth recording
because the shape is easy to reproduce anywhere `withObservationTracking` is used
with a guard.

## An accidental discovery that validates the product

While diagnosing, I measured this:

```
~/Projects/Turfs/build/Index.noindex/DataStore/v5
    3,707,263 entries   directory inode 113 MB   nlink 65535 (the APFS cap)
```

**3.7 million entries in one directory.** `ls` cannot list it. `find` takes ~20
minutes. It is an Xcode index datastore that has grown without bound — regenerable,
worthless, and invisible to Finder, System Settings → Storage, and DaisyDisk's
treemap alike.

This is exactly the thing DiskDrama exists to find, discovered by DiskDrama, on
day one. The engine now records any directory taking over 5 s to enumerate into
`ScanResult.slowDirectories`, so classification (Step 4) can surface it as a
finding in its own right rather than merely surviving it.

## Performance note worth carrying forward

One measurement contradicted a theory and I dropped the theory (§7.3): I suspected
`FTS_NOCHDIR` was forcing full-path resolution per entry. Benchmarked both ways —
1.21 s vs 1.54 s, no meaningful difference. Not the cause.

The real explanation for one alarming 60-second run was **I/O contention from a
concurrent Xcode build writing into the very tree being scanned**. Re-run clean:
2.1 s. Also note Debug builds Swift at `-Onone`; scan timings are only meaningful
from Release.

## Out of scope, flagged not fixed

Progress currently reports `0 bytes` for a long time, because the root's total only
accrues as subtrees complete at post-order. Accurate but useless as feedback. The
running total wants to be a separate accumulator. Cosmetic, and it belongs with the
real progress UI in Step 6 rather than in the dropdown stopgap.

## Next

Step 4 — the classification knowledge base. `slowDirectories` from this step feeds
straight into it.
