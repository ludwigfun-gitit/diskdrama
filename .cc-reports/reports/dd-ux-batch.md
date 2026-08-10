# DiskDrama — UX review batch

Five bugs filed in MC:L and worked through in the order the brief asked for:
the data-model one first, then the rest.

| MC:L | bug | status |
|---|---|---|
| `DD.B002` | Deleted rows stay interactive; delete dialog focuses the wrong control | **fixed** |
| `DD.B003` | Chatty aside about Library/Pictures, no user options | **fixed** |
| `DD.B004` | "couldn't read 4 locations" is opaque | **fixed** |
| `DD.B005` | Nested rows double-count | **fixed** |
| `DD.B006` | Focus rings don't match element geometry | **fixed, not visually verified** |

---

## DD.B005 — nested rows double-count — FIXED

### What was actually happening

Worse than the report described. Instrumented a real home scan and dumped every
recommendation with its path and matching rule:

```
89 recommendations
54 of them nested inside another recommendation
15.7 GB counted more than once
```

One chain, five deep, every level matched by the *same rule*:

```
4.43 GB  ~/Library/Caches                                 [generic.caches]
 +0.74   ~/Library/Caches/CloudKit                        [generic.caches]
 +0.66   ~/Library/Caches/CloudKit/com.apple.bird         [generic.caches]
 +0.66   .../com.apple.bird/2b405a4a…                     [generic.caches]
 +0.65   .../2b405a4a…/MMCS                               [generic.caches]
```

### Root cause

`generic.caches` used `matcher: .under("~/Library/Caches")` with
`isTerminal: false`.

`.under` matches the directory *and every path beneath it*, so the rule matched
at every depth. `isTerminal: false` meant the walk kept descending after a match
instead of stopping. Together, one rule claimed a container and each of its
descendants as separate rows.

The file already explains why that must not happen — the comment on `isTerminal`
reads "this is what prevents recommending DerivedData *and* each of the forty
projects inside it — the same gigabytes counted twice in one list is the fastest
way for a cleanup tool to lose trust." This rule opted out of that protection.

`isTerminal: false` was itself deliberate: descend so a *more specific* cache
rule can claim a subfolder. That intent is preserved below.

### Fix

**A `.childOf` matcher.** Matches immediate children only — not the container,
not anything deeper. `generic.caches` becomes one row per app cache. Every
specific cache rule (`homebrew.cache`, `yarn.cache`, `cocoapods.cache`,
`creativecloud.cache`) is itself an immediate child of `~/Library/Caches`, and
those rules are ordered ahead of the catch-all, so they still win — verified:
Adobe still matches `creativecloud.cache`, not the generic rule. Coverage is
unchanged, which is why the rule can now be terminal.

**An antichain guarantee.** After sorting, the builder drops any row nested
inside another, keeping the outermost. With the matcher fixed this finds nothing;
it stays because "the numbers add up" deserves enforcing where it is stated
rather than relying on every future rule to preserve it by construction. It keeps
the ancestor because the ancestor's total already contains the descendant —
dropping the ancestor would lose bytes, dropping the descendant loses only detail
still reachable through "Look inside".

### Verified

Real home scan, before and after:

| | rows | nested inside another |
|---|---|---|
| before | 89 | 54 |
| after | **46** | **0** |

Cache rows are now one per app: CloudKit 0.74 GB, Adobe 0.47 GB, Firefox
0.47 GB, and so on. `~/Library/Caches` itself no longer appears as a row.

### Not done, and flagged

The brief also asks for **expand/collapse on rollup rows**. Not built. The app
already ships a drill-in for exactly this — "Look inside" (F10) enumerates a
row's children, and F13 descends into them with a breadcrumb back — so the
capability exists, just not as an inline disclosure triangle on the row. Worth
deciding whether the existing affordance is enough before building a second one.

---

## DD.B002 — deleted items remain interactive — FIXED

### The row was not the problem

`items(in:)` already filters `deletedPaths`, so a deleted top-level row does
leave the list. The ghost was the **drill stack**: `detailItem` reads
`drillStackByTier` *before* the selection, and nothing ever removed a deleted
path from it. Descend into a child, delete it, and the panel kept showing that
folder with a live Delete button while its row was already gone from the list.

Deleting now clears the path — and anything beneath it, since deleting a folder
deletes its contents — from every drill stack and selection.

### Scan-vs-reality is resolved before the dialog, not inside it

`presentDeleteSheet` now checks the item is still on disk (one `lstat`, no
`URL`, so §5.1 does not apply — and only on invoke, never per row per render).
If it has gone, the item is dropped from the list and the reason is said inline
instead of opening a confirmation for something that no longer exists.

That message needed somewhere to live: the only place `deletionError` surfaced
was inside the delete sheets, which does not work when the answer is "there is
no sheet". The results view now carries a dismissible notice.

**Verified live** on a disposable tree, with the folder removed by `rm` behind
the app's back:

```
sheets opened: 0
“node_modules” isn't there any more — something else removed it since the
last scan. I've taken it off the list.
reclaimable: 220 MB → 94 MB
```

### Focus

`@FocusState` plus `.defaultFocus` puts initial focus on the destructive primary
button. Previously the first focusable control took it — the Trash checkbox — so
return toggled a setting rather than confirming. Applied but **not visually
verified**: focus rings need a screenshot, and screen capture is unavailable in
this environment.

---

---

## DD.B003 — Library/Pictures callout — FIXED

Shipped the supplied copy verbatim, with a title and no action button.
`Callout` gained an optional title and an optional trailing action, since it
previously had neither.

Verified on screen, Review tier:

```
Not recommended for cleanup
Library (156.2 GB) and Pictures (45.4 GB) are scanned but excluded from
recommendations. They contain data managed by apps and Photos, where
deletions can break apps or lose photos.
```

**One caveat, flagged not fixed.** The second sentence names apps and Photos
specifically, but the two folders are chosen dynamically — they are whichever
largest scanned-but-not-recommended folders the scan found. On a Mac where those
are, say, `Movies` and `Downloads`, the sentence will name Photos about folders
that have nothing to do with it. Shipped as specified because it is your copy;
worth a generic second sentence if that case is likely.

---

## DD.B004 — blind spots UI — FIXED

Callout summary reworded and given a **Show list** action, verified on screen:

```
4 locations couldn't be read. Totals are a floor, not the full picture.  [Show list]
```

`BlindSpotsSheet` lists each path with its reason and three per-item actions.
Reasons are phrased in terms of what the user can do, not the errno that caused
them — "macOS is withholding this until DiskDrama has Full Disk Access" rather
than "EPERM".

**Grant access** appears only when the reason is actually a missing grant. A
button that cannot work is worse than no button, so a symlink loop or a
system-owned folder does not get one. **Retry** closes the sheet and rescans.
**Ignore** routes to the existing exclusion list, so the choice is visible and
reversible in Settings rather than a per-scan flag the user can never find again.

The footer notes that granting access needs a relaunch before a scan can use it,
which is true of TCC and would otherwise look like the grant had not worked.

**Now verified end to end.** The first attempt failed on the harness, not the
code — SwiftUI exposes button labels as `AXAttributedDescription`, which System
Events cannot read, so finding a named button means matching on geometry instead.
Enumerating every button in the content column and picking the one whose width
fits the label found it.

Driven against a controlled tree with two excluded subfolders, so the blind spots
are deterministic:

```
2 locations couldn't be read
Anything inside these is missing from every total DiskDrama shows you.
That makes the figures a floor rather than a measurement.

/private/tmp/dd-bs/hidden-one
  You've told DiskDrama not to look here. Remove it from "Never look here"
  in Settings to include it again.
/private/tmp/dd-bs/hidden-two
  You've told DiskDrama not to look here. Remove it from "Never look here"
  in Settings to include it again.
```

Each path named with a reason that says what to do about it. The
`excludedByUser` rows correctly disable **Ignore** — it is already ignored — and
show no **Grant access**, since a grant would not change anything.

---

## DD.B006 — focus ring geometry — FIXED, NOT VISUALLY VERIFIED

The previous pass gave the styles a `contentShape`, which fixed a ring anchored
to the **wrong rect**. It could not fix the ring's **shape**, which is not
something `contentShape` controls — that was the remaining bug.

A `FocusRing` modifier now switches off the system effect and draws the ring from
the same corner radius the control fills itself with, so the two cannot disagree.
Folded into `AccentButtonStyle`, `GhostButtonStyle` and `QuietButtonStyle` rather
than applied per call site, so every button in the app inherits it and no future
call site can forget.

**This cannot be verified here.** A focus ring needs real focus plus AppKit
rendering — the accessibility tree does not expose it, an offscreen render will
not draw it, and screen capture is unavailable in this environment ("could not
create image from display"). The ticket's own verification criterion is visual.
Please look at a focused button and confirm the ring hugs the corners; if it
still sits wrong, the radius constants are in one place per style.


## All five closed

Notes retained from when the last three were still open:

- **B003** — the proposed replacement copy says "Excluded from scan by default",
  but `~/Library` and `~/Pictures` **are** scanned and counted; they appear in
  that callout precisely because they are the largest things the scan found that
  it will not recommend deleting. Shipping that wording would trade a chatty
  truth for a tidy falsehood. The intent — less chatty, give the user an option —
  is right; the wording needs to say "scanned, not recommended" instead. Worth
  settling before implementing.
- **B004** — the data already exists. `ScanResult.blindSpots` carries a path and
  a `BlindSpotReason` for each, and `FullDiskAccess.openSystemSettings()` is
  already wired for the Grant-access deep link. This is UI work over data that is
  already there, not new plumbing.
- **B006** — partially attempted earlier in the session: `AccentButtonStyle` and
  `QuietButtonStyle` gained a `contentShape` matching their corner radius, which
  fixed a ring that was anchored to the wrong rect entirely. The remaining work
  is the radius mismatch this ticket describes, which likely needs
  `focusEffectDisabled` plus a `@FocusState`-driven overlay per the ticket.
