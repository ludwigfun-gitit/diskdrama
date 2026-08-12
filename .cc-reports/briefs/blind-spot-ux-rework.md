# DiskDrama — blind-spot UI: stop treating a deliberate choice like a bug

Four tickets, same surface (`BlindSpotsSheet.swift`, `TierPane.swift`'s
`blindSpotNotice`, `BlindSpotReason` in `Models.swift`, `AppModel.exclude`).
Found by re-reading that code against a fresh round of user feedback on the
already-shipped DD.B004 sheet — DD.B004 fixed "opaque count" but not these.

| ticket | bug |
|---|---|
| `DD.B007` | Sheet always needs a click, even for a two-item list |
| `DD.B008` | Retry/Ignore offered uniformly; Ignore silently hard-excludes locations that were never optional |
| `DD.B009` | An exclusion you set yourself reads as an error, with no path back |
| `DD.B010` | DD's own default cloud-storage skips are indistinguishable from your exclusions |

## DD.B007 — no glance path for short lists

`TierPane.blindSpotNotice` always renders a callout with a "Show list"
button that opens `BlindSpotsSheet`. For 1-3 items that's a click to see
information that would fit inline. Show the paths directly in the callout
(name + one-line reason) when the count is small — 3 or fewer is a
reasonable cutoff, your call — and fall back to "Show list" only once it
would genuinely clutter the callout. The sheet itself is fine and can stay
as the fallback.

## DD.B008 — Retry/Ignore is a blanket pair, and Ignore isn't safe to blanket

`BlindSpotsSheet.row` offers Retry and Ignore for every reason. Grant Access
is already correctly conditional — good precedent, follow it for the other
two:

- `.permissionDenied`: Retry cannot fix a macOS permission wall. Remove it
  for this reason.
- `.excludedByUser`: Retry is a no-op — `FileTreeWalker` filters the path
  out of `skipSet` before the walk reaches it, so nothing changes. Remove
  it. (Ignore is already correctly disabled here — see DD.B009 for what
  should replace it.)
- `.unreadable`: Retry stays (offline volume, transient failure — can
  legitimately change between runs).

Separately, a naming collision worth fixing while you're in here: `Ignore`
on this sheet calls `AppModel.exclude(path:)`, which is the *hard* F19
mechanism (`Settings.exclusions` — never scanned again, size unknown by
design). The app already has a *different*, softer mechanism with almost
the same name — `ignoredPaths` (F18, "Ignored" in Settings) — still
scanned, still counted, just excluded from recommendations. Two different
things, one of them called "Ignore" here and "Ignored" there. For
`.permissionDenied` and `.unreadable` the hard skip is actually correct
(nothing was scanned, so there's nothing to softly ignore) — but give the
button a name that doesn't collide with the other feature. "Stop looking
here" or similar.

## DD.B009 — excludedByUser needs its own header and real actions, not a disabled button

Right now a location you deliberately excluded shows up in the same list,
same visual weight, as a genuine read failure — with an explanation
sentence and a greyed-out Ignore button that does nothing. That's what
reads as a bug: the fix you already applied (exclude it) still shows up
looking like an open problem.

Group `.excludedByUser` rows under their own header, separate from actual
failures — something like "You've told DiskDrama not to look here" as a
heading, not a per-row caveat. Replace the disabled Ignore with two real
actions:

1. **Stop excluding** — calls the existing `AppModel.unexclude(path:)`,
   already written, just not wired to this sheet. Removes it from
   `Settings.exclusions` for good.
2. **Scan anyway** — includes it in the *next* scan without permanently
   removing the exclusion. If a genuine one-off override is disproportionate
   plumbing (the skip set is computed once at scan start from
   `Settings.exclusions`), the simpler equivalent — unexclude, then trigger
   `onScan()` — is an acceptable substitute. Say in the report which one you
   built.

## DD.B010 — two of these "exclusions" aren't yours

`Settings.defaultExclusions` pre-populates `~/Library/Mobile Documents` and
`~/Library/CloudStorage` — not something the user set, something DD decided
for them, because walking into a File Provider root risks a real hang
(documented in `Settings.swift`'s own comment on `defaultExclusions`,
citing `architectural-rules.md` §5.1). Right now DD.B009's "you've told
DiskDrama not to look here" header would be false for these two — DD told
itself.

Distinguish them: if an `.excludedByUser` path exactly matches one of
`Settings.defaultExclusions`, use different copy — something like "DiskDrama
skips iCloud Drive by default, entering it can hang for minutes while macOS
decides what to download" — and do **not** offer "Scan anyway" as a casual
one-click action for these two specifically. The hang risk is real and
immediate, not hypothetical, so removing the skip should route to Settings
(where `Settings.swift` already says these are meant to be "opt-in-able")
rather than a same-click override sitting in an unreadable-locations sheet.
"Stop excluding" can still apply — it's the same underlying mechanism — just
without the low-friction "scan anyway" sibling for these two roots.

## Verification

Same requirement as last time, stated because it's the reason DD.B004's
bug analogue (the Safe-tier one) got missed once already: actually look at
the screen. Specifically:
- A scan with 1-3 blind spots shows them inline, no click required.
- A scan with an excluded path shows it under its own header with working
  Stop-excluding / Scan-anyway (or unexclude+rescan) buttons, not a disabled
  Ignore.
- The two default cloud roots, if excluded, get the distinct copy and no
  casual scan-anyway button.
- Retry is gone from `.permissionDenied` and `.excludedByUser` rows.
If Accessibility/System Events can't drive button presses again, use the
geometry-matching approach from `5940ae3` rather than skipping verification.

## Not in scope
The scan engine, exclusion persistence model, and everything else DD.B004
already shipped and this doesn't touch (Grant Access, the callout's
optional title/action, focus rings).
