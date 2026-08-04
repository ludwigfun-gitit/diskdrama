# Step 1 — Xcode project foundation

**Date:** 2026-08-04
**Commit:** `f7a0f5c`
**Flows:** F01–F04 (monitor, carried over from v0)
**Status:** built, installed, launched, verified running.

---

## What this step did

Replaced v0's raw-`swiftc` build system with a real `.xcodeproj` and migrated the
menubar logic into it. Nothing about the app's visible behaviour changed except
the free-space number, which is now correct.

**Project configuration**

| Setting | Value | Why |
|---|---|---|
| Deployment target | macOS 14.0 | Preflight's call — matches `architectural-rules.md`'s own baseline and SwiftData's floor |
| Bundle ID | `com.bloo.diskdrama` | Was `com.unruly.diskdrama` in v0's `package.sh` |
| Sandbox | off, stated explicitly | FDA and the sandbox cannot coexist; written as `false` rather than omitted so the decision is visible in the file |
| Hardened runtime | on | What notarized release will need; no reason to differ in Debug |
| Swift language mode | **6.0** | See below |
| Release architectures | `arm64 x86_64` | Retains v0's universal build |
| Source group | file-system-synchronized | New files need no `pbxproj` edit — across 14 more steps that removes a lot of churn and a whole class of merge conflict |

**Swift 6 mode from the start** is a deliberate choice worth flagging since it
could have gone the other way. This project's architectural rules (§2.2, §3.1,
§3.3) exist because concurrency mistakes on this stack are expensive to diagnose,
and Swift 6 makes the compiler enforce what those rules currently ask a reader to
remember — which is §1's whole point ("if the enforcement mechanism is a comment,
it is not enforcement"). On a fresh codebase the cost is near zero; retrofitting
it later is not. It compiled clean with zero warnings, so the bet is already paid
off. If it becomes a tar pit in the scan or deletion layers I will report rather
than quietly downgrade it.

## DD.B001 — verified, then fixed

The ticket proposed a two-line key swap. I did not apply it on faith — I dumped
ground truth first. Same volume, same instant, on this machine:

| Source | Value |
|---|---|
| `volumeAvailableCapacity` (what v0 used) | 28.11 GB |
| `df`, APFS container free, `system_profiler` | 28.11 GB |
| **Finder / System Settings → Storage** | **~31.9 GB** |
| `volumeAvailableCapacityForImportantUsage` | 31.92 GB |

The ticket's hypothesis holds: the difference is purgeable space (local snapshots,
cached downloads, sleep image, Trash), which macOS counts as available and `df`
does not. Hombre's ~22 GB gap versus this machine's ~3.8 GB is just a bigger
purgeable pool, exactly as the ticket predicted.

**But swapping the key outright would have planted a subtler bug in F24.**
"Did that deletion actually free the space it claimed?" cannot be answered against
a number that includes a pool macOS is shuffling on its own — it can move without
anything being reclaimed, and fail to move when something was. So `DiskInfo` now
carries **both**: `availableBytes` (with purgeable) for display, matching every
other surface in macOS, and `strictAvailableBytes` (without) for verification
arithmetic. Their difference is exposed as `purgeableBytes`, which is what F24
needs to explain a divergence in plain language instead of leaving it a mystery.

Reporting one number for two different jobs is the actual defect underneath
DD.B001, not the choice of key.

**I have not closed `DD.B001`** — that call is Ludwig's, not mine. It is fixed and
verified; the entry is untouched and still open.

## Two structural fixes carried in from v0

Neither was a live bug; both were live traps.

- **Menu items are held by reference, not addressed by index.** v0 mapped menu
  positions to meanings with an index enum and an explanatory comment. Correct
  until someone inserts a separator, at which point it silently writes the
  free-space figure into the wrong row with no error anywhere.
- **The free row is always an attributed string.** v0 set `attributedTitle` when
  space was low and reset it to `nil` otherwise, leaving `title` and
  `attributedTitle` as two sources of truth for one row.

## Verification on the installed build

Not "it compiled" — actually exercised:

- Process running from `/Applications/DiskDrama.app`, correctly signed
  (`Developer ID Application: Ludwig Fun`).
- Menubar reads `💾 31.9 GB` against an independent same-moment reading of
  31.93 GB.
- Dropdown renders all rows: Free 31.9 GB / Used 461.3 GB / Total 494.4 GB /
  Usage 93.3% / Last checked / Refresh Now / Open Storage Settings… / Quit.
- **Refresh Now fires** — figure and timestamp both updated (09:35 → 09:37).
  This is v0's commit `912623d` bug (menu item targets not set); confirmed not
  reintroduced.
- Both bundled fonts register: `fonts(SpaceGrotesk=true, Epilogue=true)`.
- Zero build warnings.

## Things done that were not strictly asked for

Flagging these rather than burying them.

- **`.gitignore` contained `*.xcodeproj/`.** Left alone, standing up the project
  would have left it untracked — working here, broken for every other clone, with
  no error to notice. Now only per-user state is ignored, matching Visuals.
- **Switched launch diagnostics from `NSLog` to `os.Logger`** (`Core/Log.swift`).
  `NSLog` from a Developer-ID app launched outside Xcode does not reliably reach
  `log show` — I hit this immediately when trying to read my own diagnostics.
  Paths are deliberately left redacted as `<private>`; they carry the home-folder
  username and project names, and the unified log is readable machine-wide.
- **Removed `DiskDrama.swift`, `build.sh`, `package.sh`, `DiskDrama.zip`.** All
  superseded; leaving `build.sh` behind pointing at a deleted source file is worse
  than removing it. Git history retains everything.
- **Rewrote `README.md`**, which still described v0 as the whole product and gave
  build instructions for a build system that no longer exists.

## Consequence to be aware of

The bundle ID change makes this a **new subject to TCC**, so the app currently
reports `fullDiskAccess=false` — v0's grant belonged to `com.unruly.diskdrama`.
This is expected, not a regression. It needs granting once to the new bundle, and
because `dev-build-install.sh` signs with a stable Developer ID it will then
persist across rebuilds. F05's onboarding (Step 14) is what walks a user through
this properly; until then it can be granted manually if a scan needs to see
`~/Library`.

## Next

Step 2 — SwiftData model layer and settings store.
