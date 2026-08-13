# DiskDrama — cloud downloads: spec

**Status:** spec agreed, nothing built. Decisions settled (see Decisions).
Step 1 of the verification plan is **done** — Hazard 2 was tested and ruled
out; see below. Implementation is unblocked.

## Why

DiskDrama excludes `~/Library/Mobile Documents` and `~/Library/CloudStorage` by
default, for a real and now *measured* reason (see Hazards). The consequence is
that cloud content is invisible to the app while still occupying real disk.

macOS gives no listing of it either. Storage Settings shows one number per
category and, for iCloud Drive, a line reading "Files and folders kept offline
are using Zero KB" — which counts only **pinned** content. Cached content, which
is what actually accumulates, appears nowhere. There is no Apple UI that answers
"which cloud files are on this disk, and what do they cost me?"

And removing the download is the *only* way to reclaim that space. Deleting the
file deletes it from iCloud and every other device.

## The one rule this feature must not break

**Evict is not delete, and DiskDrama must never blur them.**

| | effect |
|---|---|
| Remove Download (evict) | local copy freed; file stays in the cloud; re-downloads on demand |
| Delete | gone from the cloud and from every other device signed into that account |

Everything else here is negotiable. This is not. Concretely:

- No Delete button on any cloud row. The word must not appear on this surface.
- The batch action is "Remove Downloads", never "Clean" or "Delete".
- Confirmation copy states plainly: the file stays in iCloud, comes back on
  demand, and costs bandwidth and time to fetch again.
- This category never routes into the existing delete sheets (F14–F16), which
  are built around `trashItem`/`removeItem` and have the wrong vocabulary
  throughout.

## What was measured

All figures from this Mac, 2026-08-12. Reproduced end to end before writing.

| step | method | result |
|---|---|---|
| enumerate iCloud Drive | `mdfind -onlyin <root> 'kMDItemLogicalSize > 0'` | 12,759 paths, **1.1s** |
| enumerate CloudStorage | same | 11,770 paths, **1.2s** |
| true disk cost | `lstat`, `st_blocks * 512` | 12,759 files in **0.2s** |
| pin + download state | `fileproviderctl evaluate <path>` | **0.04s** per item; 725 folders in **21s** |
| eviction | `FileManager.evictUbiquitousItem(at:)` | 7 files, **17.46 GB**, all succeeded |

Whole-root refresh is therefore ~1.5s without pin state, ~25s with it.

`fileproviderctl evaluate` returns, per item: `isKeepDownloaded`,
`isRecursivelyDownloaded`, `isDownloaded`, `isDownloadRequested`,
`isDownloading`, `isUploaded`, `isShared`, `isExcludedFromSync`, `documentSize`,
`childItemCount`. `isKeepDownloaded` is the flag behind Finder's "Keep
Downloaded", and nothing else exposes it.

Baseline on this machine: 190 GB of logical cloud content, **0.22 GB actually on
disk**, and **zero** folders with Keep Downloaded set across 725.

## Hazards — the parts that will cause damage if ignored

### 1. Never enumerate a cloud directory

`os.walk` of `~/Library/Mobile Documents` did not finish in **3m47s**; killed
with the stack inside `_readdir_unlocked`. This is deeper than
architectural-rules §5.1, which blames `URL` property accessors: raw `readdir(3)`
hangs too, so DiskDrama's `fts` walker would hang identically. The roots stay
excluded from the walker permanently. This feature is a **separate path**, not a
change to the scan engine.

`lstat` on a known path is safe and fast — 0.0–0.1 ms, never once slow across
~24,000 calls. Path list comes from Spotlight; sizes come from `lstat`. At no
point does anything enumerate a directory.

### 2. ~~Spotlight metadata reads materialize content~~ — tested, false

I suspected this and wrote it up as the blocking gate, because 17.5 GB
materialized during investigation and `mdls` was the temporal correlate. It was
the wrong culprit.

Tested three ways against evicted files with `st_blocks == 0`, each with an
untouched control file alongside:

| form | subject | observed | result |
|---|---|---|---|
| `mdls -name kMDItemPhysicalSize -raw <path>` | 1 file, 6.4 MB | 5 min | no change |
| `mdls <path>` (all 35 attributes) | 1 file, 6.4 MB | 2 min | no change |
| `mdls -name … -raw <12 paths>` — the exact original invocation | 12 files, 88 MB | 2.5 min | no change |

`st_blocks` stayed 0 and `ctime` never moved, on subjects and controls alike.
**Spotlight metadata reads are safe on cloud paths**, and no ban is needed.

The likely real culprit is the `os.walk` in Hazard 1. It enumerated for nearly
four minutes before being killed, which is ample time for the provider to queue
materialization; 17.5 GB then takes a while to arrive, and `ctime` stamps on
completion, not on request — which is exactly the ~30-minute offset observed.
That is **one** hazard, not two, and it is the one already prohibited.

Not proven retrospectively, and not worth proving: confirming it means running
another enumeration and paying for another download, to re-establish a rule the
spec already enforces for an independent reason (the hang).

The lesson worth keeping is about the evidence, not the API: a temporal
correlation across a 30-minute delay identified the wrong call, and the only
thing that separated them was a controlled test with a control file.

### 4. Eviction is not durable while a download is queued — **found in step 2**

The most important hazard, and the one that nearly shipped unnoticed.

Evicting the 17.46 GB earlier appeared to work: every file returned
`st_blocks == 0`, both roots dropped to the 0.22 GB baseline, free space rose.
Fifty minutes later `brctl status` showed four *active downloaders* for exactly
those files, sharing one operation ID queued at the time of the original
enumeration:

```
695.9 MB  downloading 97.6%   active
  5.81 GB downloading  5.1%   active
  4.69 GB downloading 48.8%   active
  3.29 GB downloading 97.7%   active
```

`evictUbiquitousItem` frees the local copy. It does **not** cancel a pending
provider operation, and nothing in `brctl` or `fileproviderctl` exposes a cancel.
So the provider simply fetches it all again, and the reclaimed space evaporates
with no error and no notification.

Consequences for the build, all mandatory:

- Read `isDownloadRequested` and `isDownloading` (already in the `evaluate`
  output) **before** offering eviction. An item with a queued download must not
  be offered — the button cannot deliver what it says.
- After evicting, **verify the eviction held** rather than reporting bytes
  optimistically. Re-check `st_blocks` after a delay before crediting anything.
- This settles Decision 3 far more strongly than the purgeable-accounting
  argument did. Evictions must never count toward all-time freed: the bytes can
  come back on their own, and a figure that counts them would be wrong in the
  one direction users notice.

It also explains step 2's other result. `startDownloadingUbiquitousItem`
returned success but left `isDownloadRequested = 0` — the legacy ubiquity API
looks unwired under File Provider — and a plain `open`/`read` of an evicted 8 MB
file **blocked for 6m40s without completing**, because the provider was
saturated by these transfers. Which is a second reason DiskDrama must never read
cloud file contents: on a busy provider a read is an unbounded wait, exactly the
§5.1 hazard in a different costume.

### 3. `kMDItemPhysicalSize` is fiction for cloud files

It echoes the logical size. It claimed 140 files over 100 MB totalling 98.4 GB;
`lstat` reported `st_blocks == 0` for every one — all evicted, zero bytes. A
build trusting that attribute would offer 98 GB of reclaimable space that does
not exist. Physical size comes from `lstat` only.

## What the user sees

A fifth sidebar card, sibling to "Not scanned" — not a fourth deletion tier. It
carries the **real** disk figure, never the logical one.

```
Cloud downloads          0.2 GB
6 folders · 190 GB in the cloud
```

The pane has two sections, because they answer different questions:

**Downloaded now** — folder rollup sorted by real disk cost, with per-row and
batch "Remove Download". This is the reclaimable space. Each row shows real
bytes and file count; the logical size is available but never leads.

**Set to Keep Downloaded** — folders with `isKeepDownloaded = 1`. These are the
standing commitment: evicting their contents is temporary, because the pin pulls
them back. Answering "which folders did I pin?" is something no Apple UI does,
and on a machine where the answer is a surprise it is the more valuable half.
Action here is "Stop keeping downloaded", which is a different operation from
eviction and may need `fileproviderctl` or Finder rather than a public API —
**open question, see below**.

Empty state matters: "0.2 GB downloaded of 190 GB in the cloud" must read as
*reassurance*, not as a problem to fix. Most of the time this pane's honest
message is "nothing to do here".

## Explicitly out of scope

- Any change to `FileTreeWalker`, `ScanEngine` or the tier classifier.
- Removing the two roots from `Settings.defaultExclusions`. They stay.
- Watch / snooze / ignore on cloud rows.
- Photos library, Mail, Messages attachments — different mechanisms, not File
  Provider.

## Decisions — settled

Ludwig's call, 2026-08-12: follow the recommendations below.

1. **Pin state via `fileproviderctl`, with a hard fallback.** (b) below.
2. **iCloud Drive only in v1.** `~/Library/CloudStorage` deferred until
   eviction is verified per provider.
3. **Evictions recorded in History, but not counted toward all-time freed** —
   they would overstate it, for the reason given below.
4. **Refresh on demand**, not on every scan.

Original framing kept for the reasoning behind each:

1. **Ship v1 without pin state?** `fileproviderctl` is an undocumented CLI and
   shelling out to it from a notarized app is a real dependency risk — it can
   change or vanish in any macOS release. Options: (a) v1 shows downloaded
   content only, using public API throughout; (b) v1 includes pin state via the
   CLI, degrading gracefully when it fails. I lean (b) with a hard fallback,
   since the pin list is the half nothing else provides — but it is your call on
   how much undocumented surface to carry.

2. **Include `~/Library/CloudStorage` in v1?** `evictUbiquitousItem` is verified
   only against iCloud Drive. Third-party providers (Google Drive, OneDrive,
   Dropbox, CloudMounter) may not honour it. Needs testing on a disposable file
   per provider before being offered. Your CloudStorage holds 0.17 GB across 332
   files, so the value there is currently small.

3. **Do evictions belong in History and the all-time freed figure?** They do
   free space, but F24's contract is careful about claiming reclaimed bytes, and
   macOS already treats cached cloud content as purgeable — during testing the
   system reported ~22 GB free while 17.5 GB sat materialized, and evicting all
   17.46 GB moved free space by only ~5 GB. Counting evictions at face value
   would overstate what the user gained.

4. **When does it refresh?** On demand (a button in the pane) or as part of
   every scan? On demand keeps a fragile path off the critical scan path; every
   scan keeps the card's number honest. I lean on demand for v1.

## Verification plan

- ~~Hazard 2 confirmed or ruled out before any implementation.~~ **Done** —
  ruled out, three forms tested with controls. See Hazard 2.
- ~~Eviction round-trip: evict, confirm `st_blocks == 0`, re-download, confirm
  bytes return.~~ **Step 2 run, partially blocked.** Eviction verified (7 files,
  17.46 GB, `st_blocks` → 0, files intact, logical size unchanged). Reversal
  **not** verified: the legacy download API is a no-op and a read blocks
  indefinitely on a busy provider. Re-run on a machine that is not mid-transfer
  before shipping — the claim "it comes back on demand" is the feature's whole
  safety story and is currently unproven.
- Card total reconciles with `du` on a folder small enough to `du` safely.
- The pane renders and refreshes with both roots empty, with one root empty, and
  with Spotlight disabled — the index is a floor, and the copy must say so
  rather than presenting a floor as a measurement.
- No cloud path is ever passed to `fts`, `readdir`, or a `URL` property
  accessor. Worth a test that asserts this, given how expensive getting it wrong
  proved to be. `mdls` is off the list — it was tested and is safe.
