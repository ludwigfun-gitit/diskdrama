# Step 7 — Explanation panel, Look inside, drill-down, hand-off actions

**Date:** 2026-08-04
**Commit:** `0d28a90`
**Flows:** F09, F10, F11, F12, F13
**Status:** built, installed, all five flows exercised live against real data —
including a real Tier 2 item, which took some finding.

---

## What this step is

The fixed-bottom panel the tier list has been feeding since Step 6. Everything
above it is a list of folders and numbers, which any disk tool produces; this is
the part that says what a thing *is*, what happens if it goes, and how sure the
app is — and it is the reason a user can make the call without going off to read
a thread about what `DerivedData` does.

Two rules it holds to, both from F09's failure case:

- **Never invent an explanation.** An unrecognised folder says so in as many
  words and stays in Review first. A confident-sounding guess is the fastest
  possible route to someone deleting something they needed.
- **State consequence, not category.** "Build artifacts" is a category. "Xcode
  rebuilds it on your next build — one slow clean build per project" is a
  consequence, and only one of those helps.

## Decisions worth recording

**Confidence is a band, not a number.** `0.75` invites arithmetic the reader has
no basis for; "reasonably confident" is the actual content of that number. Three
bands, and only the top one lights the cyan indicator — a live dot on a
low-confidence item turns a warning into decoration.

**Rebuild cost folds into the consequence.** "It regenerates" and "regenerating
costs six minutes a project" are one thought, and giving them separate rows lets
a reader take the first half and stop.

**F12's failure case belongs in the knowledge base, not the panel.** An item whose
owning app has been removed must be re-tiered — and tier decides which list it is
in, whether it is batch-eligible, and what the sidebar counts say. Deciding that
in the view would leave every other surface disagreeing with the panel. It is
also deliberately *not* re-tiered to Safe: the data outlived its app, nobody can
say what is in there now, and "probably leftovers, look before you delete" is the
honest line.

**A drilled-into child takes its own name.** Subtree rules match children too, so
the first version showed "iOS device support files" as the title for one specific
device folder — descending looked like only the numbers changed. The rule's prose
still describes what kind of thing it is and stays; the name is the child's own.

**The breadcrumb shows ancestors only.** The design has no breadcrumb because it
never shows a drilled-in state, but F13 requires a path back and an unmarked
one-way descent would be worse than not offering the descent at all. Including
the current item printed the same name twice in adjacent lines.

## A delta bug this step surfaced

Not a UI bug, and worth stating plainly because it silently produced wrong
numbers: `DeltaComputer` compared any two consecutive snapshots without checking
they covered the same ground. Changing scan roots — which A03 makes a normal user
action — therefore reported everything in the old roots as *disappeared*.

Observed live while testing: `gone=205 net=−24.1 GB`, none of which happened.

The delta is now nil when the two scans' roots differ. "I can't compare these" is
the only true answer, and the Changes view already renders an absent delta
distinctly from an empty one (Step 5's own rule).

## Full Disk Access turns out to gate most of Tier 2

Verifying F12 needed a real App-managed item, and finding one was harder than
expected. Every candidate on this machine sits behind TCC:

| Candidate | Outcome |
|---|---|
| `~/Movies/DaVinci Resolve/CacheClip` (3.0 GB, Resolve installed) | `~/Movies` is protected — `entries=0, blindSpots=1` in 0.0 s |
| `~/Library/Group Containers` (18 GB) | wedged; abandoned |
| `~/Library/Group Containers/…podcasts` (5.4 GB) | **succeeded** — 168 s, 6,007 entries |

That last one is the finding worth carrying: **without Full Disk Access, App-
managed is empty in practice**, because the storage other apps own lives almost
entirely in protected locations. It is consistent with Step 3's result and it
raises the stakes on F05's onboarding (Step 14) — reduced mode is not a mildly
degraded experience for this tier, it is an absent one.

I did not grant Full Disk Access to work around this. That is a system security
setting and Ludwig's call, not mine.

## Verified live

Against `~/Library/Group Containers/…podcasts` (Tier 2) and the restored
`~/Library/Developer` snapshot (Tier 1):

- **F09** — panel reads `Podcast downloads` · `5.5 GB · 607 files ·` + cyan
  `high confidence`, then "Episodes downloaded for offline listening." and
  "Podcasts re-downloads episodes on demand, but removing them through the app
  keeps its library in step."
- **F12 pointer** — `Podcasts → Settings → Downloads.` rendered in the
  consequence column, emphasized. This is the line F12 requires and it is easy to
  forget, because launching the app *feels* like the whole flow.
- **F12 action** — pressing "Open Podcasts" launched Podcasts. Confirmed by
  process check, then closed again.
- **F11** — "Reveal in Finder" opened Finder with
  `243LU875E5.groups.com.apple.podcasts` frontmost and the item selected.
- **Tier 2 has no delete button at all**, and no "Clean all" in the header — not
  a disabled one, none. A greyed-out control would imply DiskDrama merely can't
  reach into another app's storage right now, rather than that it doesn't.
- **F10** — instant on the in-memory tree (in-session scan); the on-demand walk
  path exercised separately on the restored `iOS DeviceSupport` snapshot, three
  child rows returned.
- **F13** — drilled from `iOS device support files` (17.9 GB, 13,054 files) into
  `iPhone16,2 26.6 (23G71)` (6.0 GB, 4,373 files), then back via the breadcrumb to
  the parent. Round trip clean.
- Zero Swift warnings.

## A design contradiction I resolved one way — flagging it

The Review-tier Delete button. The resolved HTML draws it **danger-outlined**
(`border:1px solid var(--danger); color:var(--danger)`), while three separate
statements say that must not exist:

- README: *"danger color appears only here and in delete confirmations — nowhere
  else in the app."*
- README: *"No colored (accent/danger/tier) borders anywhere — every earlier
  attempt at a colored border was explicitly removed during design."*
- The HTML's **own** caption on screen 3c: *"Red appears here and in the delete
  confirmation — nowhere else. Tiers are told apart by where they sit and what
  they say, not by colour."*

I built the HTML's version, for consistency with the Step 6 precedent (where the
README and the HTML disagreed about item rows, the artifact won) and with the
handoff's "recreate pixel-for-pixel" instruction.

**But I think the prose is more likely right**, and this is a one-line change:
the app's single most important safety mechanism is the confirm sheet's Trash
toggle recolouring its button to danger, and spending red one screen earlier
dilutes exactly that signal. Say the word and I'll flip it to the accent
treatment Tier 1 uses.

## Deliberately not in this step

- **Delete** (F14/F15), **Watch this** (F21), **Not now / Never suggest this**
  (F17/F18) — buttons exist, visibly disabled, wired in Steps 9–11.
- The Anthropic explanation layer (F09's deeper prose, A05) is **Step 8**. This
  panel renders the local knowledge base only, which is the whole of the
  deterministic half and is already enough to decide with.

## Out of scope, flagged not fixed

**The orphaned-owning-app branch is implemented but not exercised.** Every Tier 2
rule's app is installed on this machine, so the re-tiering path has no live
confirmation — only a read of the code. Worth exercising deliberately before
release rather than discovering it in the field.

**`DD.U001` still stands** — largest-non-recommendable is one level too coarse for
the handoff's own copy. Untouched here.

## Next

Step 8 — the AI explanation layer: Anthropic via `URLSession`, fingerprint-keyed
cache (A05), generated on first view for items the user actually opens.
