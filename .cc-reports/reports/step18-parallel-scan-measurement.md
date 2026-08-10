# Step 18 — the parallel scan engine, measured

**Status:** built, committed (`a6a62ee`). **3.5× faster.** One acceptance
criterion in the brief is not met, and it is not met for a reason that is worth
a decision from you rather than a fix from me.

---

## The headline number

Same machine, same scope, same exclusions, real home directory:

| | entries | total | slowDirs | **time** |
|---|---|---|---|---|
| serial (before) | 1,553,123 | 241.31 GB | 34 | **150.5s** |
| parallel (after) | 1,554,687 | 241.50 GB | 17 | **42.8s** |

**3.5× on six workers.** Not the 6× a core count suggests, which is expected —
the walk is syscall-bound, not CPU-bound, and the disk is the shared resource.

Worth pairing with the number that motivated the brief: before the change, a
home scan sat at **0.7% CPU** while blocked on one folder. That is the whole
problem in a single measurement — the machine wasn't working, it was waiting.
One worker blocking no longer stops the other five.

## Correctness: bytes are right, recommendations are not

The brief's bar is "the total size and every recommendation matches a known-good
prior scan exactly". Bytes effectively pass; recommendations do not.

### Bytes

A live home directory cannot be measured twice — I was building the app between
runs, so Xcode was writing to it. Totals drift **in both directions** around the
baseline (241.31 → 241.50 → 241.13 GB), which is churn, not a bias.

So byte-exactness was verified where the disk can't move: a static tree of 157
directories and 146 files, including **hard links spanning three different
top-level directories** — the case that only exists once there are several
workers.

```
du -sk ground truth : 18,874,368 bytes
scan run 1          : 18.9 MB   (460 entries)
scan run 2          : 18.9 MB   (460 entries)
scan run 3          : 18.9 MB   (460 entries)
```

Exact, and identical across runs. Had the hard links been double-counted the
total would have come out ~384 KB high. It didn't.

### Recommendations — the deviation

| | safe | review | reclaimable |
|---|---|---|---|
| serial | 7 items / 203.3 GB | 7 / 17.7 GB | 221.08 GB |
| parallel | 5 items / 158.0 GB | 8 / 45.6 GB | 203.55 GB |

That is a big difference, and it is **not** the tree being wrong. Traced to one
mechanism:

- `RecommendationBuilder` checks `slowByPath` **before** classification and
  `return`s, so a slow folder becomes one finding that swallows everything
  beneath it instead of letting the rules classify its contents.
- `slowDirectoryFinding` is `tier: .safe`, and inherits the whole subtree's
  bytes.
- Which directories are "slow" is a **wall-clock measurement of the scan**, not
  a property of the disk. Making the scan faster changes it: 34 slow
  directories became 17.

So two fewer swallowing findings in `safe` (−45 GB), and their contents
reclassified individually, some landing in `reviewFirst` (+28 GB).

**This is pre-existing, not introduced.** The trigger was always elapsed time.
Parallelism widens the variance rather than creating it — two *identical*
parallel runs produced 17 and 29 slow directories. The same rescan on the serial
engine would also have varied; I have only one serial data point, so I can't say
by how much.

### Why I did not fix it

The honest fix is to trigger that finding on **file count**, which is a property
of the disk and deterministic — and which is what the finding already *says*
("very large number of files"). The title describes a count; the trigger measures
seconds.

That is a change to what gets classified, which both briefs put explicitly out of
scope. So it's yours to call:

1. **Leave it.** Recommendations shift between rescans. They already did.
2. **Trigger on file count instead of elapsed time.** Deterministic, matches the
   copy, one-line threshold change plus removing the timing dependency.
3. **Keep the timing signal but stop it swallowing subtrees** — report "this
   folder is slow" as a note rather than as a recommendation that replaces
   everything inside it.

My recommendation is (2), and it is small. It is also the difference between a
tool whose advice is reproducible and one whose advice depends on how busy the
Mac was.

## Concurrency specifics worth recording

**Termination.** An empty queue is not an empty workload. A claim increments the
active count before releasing the lock, so work is accounted for from the instant
it leaves the queue; the walk ends only when nothing is pending *and* nothing is
active. Getting this wrong gives either an early exit with half the disk missing
or a permanent hang with every worker asleep.

**A bug I introduced and caught before shipping.** The first version let every
node roll up at its post-order visit, as the serial walk always had. That is
wrong the moment a descendant is on another thread: the ancestor folds an
incomplete total into its parent, the join adds the missing bytes afterwards, and
the grandparent keeps the stale number — bytes lost, silently. Any node with an
outstanding handed-off descendant is now deferred to a single-threaded join pass,
deepest first.

**What is deliberately not locked.** `visited` and `bytesSeen` move millions of
times; a shared lock there would serialise exactly what this change parallelises.
They are worker-local and merge on the throttled tick. Hard links are the one
piece that genuinely cannot be local, and that lock is only taken for entries
with `st_nlink > 1`.

**Pause and cancel.** Cancel verified mid-scan with the pool running: 12 threads,
clean stop, 540,615 entries discarded, app responsive afterwards. Pause shares
the same polled control in every worker but has no UI to reach it, so it is
verified by construction rather than by use.

**Stalls are per-worker now.** One shared activity slot let a busy worker keep
resetting a wedged worker's timestamp, hiding the stall entirely. `ScanControl`
tracks one activity per worker and surfaces the worst. In practice a single slow
folder no longer reads as a stall at all — the other workers keep reporting
progress, which is the honest outcome, because the scan genuinely is progressing.

## Not built

Part B of the atomic brief, per its own superseded note. Part A is in from
earlier this session and now runs inside the workers; Part C is unrelated and
already shipped.

The pathological folder (`~/Projects/Turfs/build/Index.noindex`) was excluded
from both timed runs so the baseline could complete at all. It is still a folder
`du` and `find` cannot enumerate in 45 seconds. Parallelism means it no longer
stops the scan — five workers keep going — but it does not make that folder fast.
