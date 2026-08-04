# Step 5 — Snapshot persistence and delta

**Date:** 2026-08-04
**Commit:** `ad3ec85`
**Flows:** F06, F20
**Status:** built, installed, verified end-to-end across four consecutive scans.

This closes the engine layer. Scan → classify → persist → delta now works
end-to-end without any UI.

---

## Verified end-to-end

Four consecutive scans on real directories, adding and then removing a 2 GB file:

| Scan | Total | Delta |
|---|---|---|
| 1 — baseline | 25.77 GB | *first scan, no baseline to compare against* |
| 2 — no change | 25.77 GB | all zero |
| 3 — +2 GB added | 27.93 GB | `appeared=1 regrown=1 net=+2.2 GB` |
| 4 — 2 GB removed | 25.77 GB | `gone=1 net=−2.2 GB` |

The added folder classified as **Tier 3 `[unknown]`** — the correct cautious
default for something no rule recognises, rather than an invented explanation.

Pruning confirmed: **93,906 entries scanned → 969 rows persisted** across four
snapshots. That is the whole point of the design and it is holding.

(The test file was created by me under `/tmp`-equivalent discipline inside a
scratch folder I made, and removed again — scan 4 above *is* the removal. Nothing
of Ludwig's was touched.)

## Design points worth recording

**Totals are computed over the full tree, details are pruned.** If roll-ups were
computed over the persisted subset, every headline figure would silently
under-report whatever fell below the floor. The prune also walks *pruned* rather
than walking whole and discarding — if a subtree's total is below the floor,
nothing inside it can be above it.

**The delta honours both snapshots' prune floors, not the current setting.** This
is the kind of thing that only bites months later: raise the floor in a future
version and every item that merely stopped being written would appear as
"disappeared". Storing the floor on the snapshot (Step 2) is what makes this
possible.

**Regrowth is separated from ordinary growth.** F20's real question is not "what
changed" but *"is this a new problem, or the same one again?"* Something returning
from near-zero is the signature of a build folder that was cleaned and has
refilled — so `regrown` is its own accessor, sorted biggest-first, rather than
being one row among many increases. This is the input to F21's watch suggestions.

**A first scan yields `nil`, not an empty delta.** "First scan, nothing to compare
against" and "nothing changed" are different statements, and the UI must not
render them the same way.

**`phase` stays `.finishing` until the write lands.** Results are never presented
as settled while history is still being written — a quit in that window would
otherwise lose the scan silently. And a failed store degrades the app to "works
but does not remember" rather than discarding a scan the user just waited for.

## Test-harness note

One false negative during testing was mine, not the app's: `dd if=... of=~/path`
does not expand `~` after `of=`, so the file was never created and the delta
correctly reported no change. Worth noting only because for a minute it looked
like a real bug in the delta.

## Next

Step 6 — the main window shell, sidebar and tier list, per the Claude Design
handoff. This is where `DiskDrama.dc.html` gets read properly for the first time.
