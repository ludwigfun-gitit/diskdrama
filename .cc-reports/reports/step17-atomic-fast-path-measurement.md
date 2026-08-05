# Step 17 — the atomic fast path, measured

**Short version:** Part A works and is correct, but it buys **1–3.5%** on the
subtree it targets, which is nothing. Part B is a **no-go**, and not because the
numbers were merely unconvincing — the thing it proposes to parallelise doesn't
exist on this machine. Part C is done and verified. Along the way the walker
turned out to have a **real pre-existing bug** that is worth more than the whole
optimisation.

---

## The pre-existing bug (the most important thing here)

`fts_set(fts, entry, FTS_SKIP)` on a pre-order directory **still returns that
directory in post-order**. I verified this against `fts(3)` on this machine
rather than trusting memory:

```
FTS_D   level=2  /private/tmp/ftsprobe/a/skipme
        -> fts_set(FTS_SKIP)
FTS_DP  level=2  /private/tmp/ftsprobe/a/skipme     ← arrives anyway
```

The walker skips excluded and TCC-protected directories without pushing them on
the stack. So their `FTS_DP` popped **the parent instead**.

With the default exclusions this fired on every scan of a home folder:
`~/Library/Mobile Documents` sits at level 2, so its post-order visit popped
`~/Library`, finalised it early, and misattributed everything after it in
`~/Library` to the home folder directly. Totals stayed correct — bytes were
still counted exactly once — but the **breakdown was wrong**, which is what the
storage map and "biggest folders" are built from. `~/Library` has been reporting
short.

It only bit at level ≥ 2, which is why it survived: an exclusion at level 1 hits
the `stack.count > 1` guard and is skipped harmlessly.

Fixed by popping only when the top of the stack really is that directory:

```swift
guard stack.last?.path == donePath else { continue }
```

A structural check rather than bookkeeping — it cannot drift, and it covers both
the exclusion case and the new atomic case.

---

## Part A — measurement

Built as specified: `isAtomicRegenerable` on 17 Tier-1 `.safe` terminal rules,
and an `FTS_SKIP` + size-only sub-walk in `FTS_D`.

**Correctness is fine.** Byte totals are identical before and after (23.75 GB
across 74k entries), the recommendation and its size are unchanged, and
`RecommendationBuilder` classifies the node exactly as before.

### The numbers

App-level timing turned out to be useless for this, and it's worth saying why:
`dev-build-install.sh` writes into `~/Library/Developer/Xcode/DerivedData`, which
**is the subtree being measured**. Whichever binary I had just built always
walked colder pages, so each build looked slower than the one before it. Early
readings of "0.6s baseline vs 3.0s after" were entirely that artefact.

Isolated instead — same subtree, same process, alternating, 5 rounds:

| subtree | building nodes | summing only | delta |
|---|---|---|---|
| real DerivedData (4.16 GB, 4,201 dirs, 26.7k files) | 0.152s | 0.146s | **−3.5%** |
| synthetic `node_modules` (250,000 files, 25,502 dirs) | 3.505s | 3.465s | **−1.1%** |

Both produced byte-identical totals, which is a second independent correctness
check.

The second row is the one that settles it. That's the shape the brief describes
— hundreds of thousands of tiny files — and the saving is inside run-to-run
noise; summing-only was *slower* in 3 of the 5 rounds. At ~11.6 µs per entry the
walk is entirely `lstat`/`readdir` cost. Avoiding 25,502 Swift allocations is
about 1% of that.

**Memory did not improve either.** Peak RSS during a scan, Release build:
**83–84 MB baseline vs 96–97 MB with Part A.** I can't fully account for the
increase; the plausible cause is two live `fts` streams (the outer one suspended
mid-tree while the inner one walks) each holding their own directory buffers. I'd
rather report it unexplained than guess. Note the existing
`inMemoryDetailFloorBytes` pruning already drops sub-10 MB children at post-order,
so the nodes Part A avoids were mostly transient anyway — the retained-memory win
the brief hoped for was already being had.

### Recommendation

**Consider reverting the walker half of Part A.** It is correct and it is not
harmful, but it adds a second traversal path to the file whose own header calls
it "the single most important architectural decision in the app", in exchange for
~1% and 13 MB in the wrong direction. That is a bad trade for that particular
file.

What I would keep regardless:

- the `FTS_DP` fix — a genuine correctness bug, unrelated to the optimisation
- the `isAtomicRegenerable` flag — Part C depends on it and it earns its place there
- Part C itself

I have left Part A in place rather than reverting it unilaterally, since the
brief called it required. It is one commit and reverts cleanly.

---

## Part B — no-go, and not a close call

The brief conditions Part B on Part A being insufficient. It is insufficient —
but Part B would not fix it, for a reason the brief couldn't have known:

**Part B proposes parallel `fts` sub-walks *across independent atomic roots*.
This machine has exactly one.** Instrumented, a full scan of
`~/Library/Developer/Xcode` produced a single fast-path hit — `DerivedData`,
26,716 files, 4.16 GB, 0.159s warm. Parallelising across one root is a no-op.

Parallelising *within* a root would attack the real bottleneck (syscalls), but
that is a different design from the one specified, and the price is stated
plainly in the brief: races against `bytesSeen`, `blindSpots`, `slowDirectories`
and `visited`, all currently safe by virtue of being single-threaded. Trading
that for a fraction of 0.159s is not a trade worth making.

Recommendation: **don't build Part B.** If scan wall-clock becomes a real
complaint, the profitable target is the syscall floor across the *whole* walk,
not the atomic roots.

---

## Part C — done, verified

Per-item seeding only. `Settings.shared.defaultDeletionMode` and its UI are
untouched, and `TrashToggle` stays live.

Verified by driving the real `presentDeleteSheet` path over actual scan results:

```
tier=1 atomic=false moveToTrash=true   iOS device support files
tier=1 atomic=true  moveToTrash=false  Xcode derived data
tier=3 atomic=false moveToTrash=true   Xcode archives
```

That is the A/B the brief asked for, and a good one: two Tier-1 `.safe` items
where only `DerivedData` is atomic, so the split is the flag rather than the tier.

One judgement call beyond the letter of the brief: the **batch** sheet defaults
to permanent only when *every* item in the job qualifies. A batch containing one
ordinary folder gets the ordinary default, because the costs aren't symmetric — a
needless trip through the Trash wastes time, a needless permanent delete can't be
undone.

---

## Two things I could not verify

**Accessibility went down mid-task** — `Claude` and `Finder` both reporting zero
windows while visibly having them — and did not recover within two minutes, so
the UI-driven half of verification was blocked. Part C was verified through the
real seeding code path instead of by opening the sheet. This is the third such
outage; it is intermittent and has self-healed before.

**F10's "Look inside" for an atomic folder** is verified by construction rather
than by running it. An atomic node has no children, so `DirectoryPreview` falls
through to its live re-walk — and that walk is rooted *at* the folder, where
`fts_level == 0`, which the fast path deliberately sits below. Confirmed by
reading the ordering (`FileTreeWalker.swift:214` precedes `:233`), not by
clicking it.
