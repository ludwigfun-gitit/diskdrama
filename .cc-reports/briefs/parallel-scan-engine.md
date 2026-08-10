# DiskDrama — Parallel scan engine (dynamic work distribution)

## Context
Confirmed this session: DaisyDisk genuinely scans in parallel — it detects
SSDs specifically and allows full concurrent access on them (only throttling
to sequential on spinning disks, to avoid thrashing the head). DiskDrama, as
built, does the opposite: `ScanEngine.start()` dispatches the *entire* walk
onto one single serial `DispatchQueue` — one thread, start to finish,
regardless of how many cores the Mac has. Ludwig has called multi-hour scans
unacceptable outright, so this is being fixed directly rather than staged.

One thing worth being explicit about, since it shapes the design: the
default `scanRoots` config is just `[home directory]` — a single root. A
naive "one worker per configured root" split would parallelize nothing at
all for the common case, since there's only one root to split. Real
load-balancing has to distribute work *below* the root level, and
*dynamically* — a static split (e.g. one worker per top-level folder) also
doesn't handle `~/Library` being an order of magnitude bigger than
`~/Movies`; a worker would finish early and sit idle while another grinds on
alone. That's why this is a genuine work-distribution problem, not just "run
a few things in parallel."

Bundled with this: fold in Part A of the already-written
`.cc-reports/briefs/atomic-build-cache-fast-path.md` (skip building a
detailed node tree for known-safe regenerable folders like Xcode
DerivedData) — do it as part of this same effort, since a worker claiming
one of those subtrees benefits from both fixes together. That brief's Part B
(parallel summation scoped just to atomic roots) is now superseded by this
brief's general-purpose parallelism and should be dropped — don't build two
separate concurrency mechanisms. Part C of that brief (Trash-bypass default
for atomic-regenerable items) is unrelated to scanning and still stands as
written.

## What to build

### Work distribution: let `fts` keep doing what it's good at; add a handoff, don't reinvent recursion
Two ways to get real dynamic load-balancing. Use the first.

**Recommended — subtree claiming with handoff.** A pool of worker threads
(size from `ProcessInfo.processInfo.activeProcessorCount`, tuned down some
to leave the app and system responsive — your call on the exact number),
each running today's existing `fts_open`/`fts_read` loop, unchanged, on a
subtree it claims from a shared, thread-safe queue of pending paths. Seed
that queue with more than just `scanRoots` — include each root's immediate
children too, so there's real work to distribute even in the common
single-root case. Add one new thing inside the existing `FTS_D` case: at
shallow depth within a worker's claimed subtree, if the shared queue is
empty and other workers are idle, hand off some of the not-yet-visited
sibling directories at the current level back to the shared queue
(`fts_set(fts, entry, FTS_SKIP)` on this worker's own traversal, push the
path for an idle worker to open independently) instead of walking them
itself. This keeps essentially all of today's tested per-entry logic — the
`FTS_D`/`FTS_F`/`FTS_DP` switch, blind-spot handling — exactly as it is, and
keeps relying on `fts`'s own robust recursion, cycle avoidance, and device-
boundary handling rather than reimplementing any of that by hand.

**Not recommended, hold in reserve** — a fully manual work queue where the
unit of work is "one directory's immediate children" instead of a claimed
subtree. Finer-grained balancing, at the cost of manually rebuilding what
`fts` already gives you for free (cycle detection, hardlink coordination,
device-boundary enforcement) — a much bigger rewrite of already-hardened
logic. Only reach for this if the handoff approach above doesn't balance
well enough once measured.

### Shared state that needs a concurrency story
Everything in `FileTreeWalker.walk` that's currently a plain local variable
touched by one thread now needs to be safe for N threads:

- `bytesSeen` / `visited` counters — atomic or lock-protected.
- `blindSpots` / `slowDirectories` arrays — append under a lock.
- `seenHardLinks` — shared and lock-protected; two workers can now hit the
  same hard-linked inode from different directories concurrently, which
  never happened on one thread.
- The `ScanNode` tree — a node's size needs to accumulate correctly as
  children complete from different worker threads, possibly while the
  node's own directory entry is still being enqueued elsewhere. Needs either
  a lock per node or an atomic add, plus correct "how many children are
  still outstanding" bookkeeping so a node isn't finalized or pruned before
  everything under it has actually reported in.

### Progress, stalls, pause, and cancel are now plural
Today's stall watchdog and `ScanControl.currentActivity` assume exactly one
thread and one "current path." With N workers there are N current
activities — decide something sensible to surface (the worst-stalled one,
or a short list) rather than picking one arbitrarily. Progress reporting
needs to aggregate across workers instead of one throttled callback per
thread independently poking the same UI state. Pause and cancel need to stop
every worker cleanly, not just one loop.

## Constraints
- `FileTreeWalker.swift` and `ScanEngine.swift` are the most carefully
  documented, most heavily reasoned-about files in this codebase by their
  own header comments. Read those headers and hold every constraint already
  written there — GCD not `Task.detached` per §3.1, the
  `FTS_PHYSICAL`/`FTS_XDEV`/`FTS_NOCHDIR` semantics, the raw-C-string
  discipline that avoids `URL`'s File-Provider XPC hazard. None of that is
  lifted by adding concurrency — it now has to hold on N threads instead of
  one, which is genuinely harder, not automatically inherited for free.
- This is the first real concurrency in a part of the app that has none
  today. Take the time to get termination detection (when is the queue
  actually, truly empty — not just empty right now, but with no worker
  about to add more to it), handoff correctness, and locking right. Prefer
  clear and correct over clever, and comment the non-obvious parts the way
  the rest of this file already does.
- No change to what gets scanned, excluded, or classified — only to how many
  threads do the walking and how work gets distributed among them.
- Live-verify thoroughly, not just "it builds": run a real scan of your
  actual home directory, confirm the total size and every recommendation
  matches a known-good prior scan exactly — parallelism must change the
  time, never the answer. Confirm pause, cancel, and stall reporting all
  still behave correctly with multiple workers active at once. Time the
  before and after on the real machine.
- Report the measurement regardless of outcome — the whole point of this
  brief is finding out whether this gets scan time into acceptable
  territory, so that number matters even if nothing else about the change
  is remarkable.

## Not in scope
Cross-volume or cross-device scanning changes. Any change to what gets
classified, tiered, or excluded. UI work beyond what's needed to surface
multi-worker progress and stalls sensibly.
