# DiskDrama — cloud downloads: spec

**Status:** spec only, nothing built. Four decisions at the end need Ludwig.

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

### 2. Spotlight *metadata* reads appear to materialize content

Strongly suspected, and it cost 17.5 GB during investigation. I ran `mdls` on
the 25 largest cloud files to check whether `kMDItemPhysicalSize` was
trustworthy. About 30 minutes later those files were fully downloaded — `ctime`
half an hour old against `mtime` 110 days old, which is materialization, not
modification. Free space fell from 40.6 GB to 17.4 GB.

`mdfind` (a query against the index) never did this. `lstat` never did this.
Only `mdls` (per-item attribute fetch) correlates.

**This must be deliberately verified before any code ships**, because a
disk-space tool that silently downloads gigabytes is worse than no tool. Test:
pick one evicted file, record `ctime`, run `mdls` on it alone, wait, re-check.
If confirmed, `mdls` is banned on cloud paths and the ban goes in
architectural-rules alongside §5.1.

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

## Decisions needed

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

- Hazard 2 confirmed or ruled out **before** any implementation.
- Eviction round-trip on a disposable file per provider: evict, confirm
  `st_blocks == 0`, re-download, confirm bytes return.
- Card total reconciles with `du` on a folder small enough to `du` safely.
- The pane renders and refreshes with both roots empty, with one root empty, and
  with Spotlight disabled — the index is a floor, and the copy must say so
  rather than presenting a floor as a measurement.
- No cloud path is ever passed to `mdls`, `fts`, `readdir`, or a `URL` property
  accessor. Worth a test that asserts this, given how expensive getting it wrong
  proved to be.
