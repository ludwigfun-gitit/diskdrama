# Step 4 — Classification knowledge base

**Date:** 2026-08-04
**Commit:** `45d18ec`
**Flows:** F08 (+ the data behind F09's explanation panel)
**Status:** built, installed, verified against real directories on this machine.

---

## What it does

The local, deterministic tiering layer — the half of the AI story that costs
nothing. ~30 rules covering Xcode (derived data, index stores, device support,
simulator caches, archives), npm/yarn/pnpm, SwiftPM, Cargo, Gradle, Maven, pip,
Homebrew, CocoaPods, Docker, Podcasts, Adobe, DaVinci Resolve, and Photos.

Per the preflight's two-layer split, the Anthropic API is **not** involved here
and never will be for tiering. Asking a model to re-derive "build artifacts
regenerate" on every scan would be slower, more expensive, and less reliable than
a table. The API is reserved for F09's deeper prose on items the user actually
opens.

## Verified on real data

Three roots (`~/Library/Developer`, `~/Projects/Visuals`, `~/.npm`):

```
101,422 entries · 25.90 GB · 3.8s
reclaimable = 23.24 GB   safe 3/22.1 GB · appManaged 0 · review 1/1.1 GB

T1  17.9 GB   iOS device support files    [xcode.deviceSupport]
T1   4.1 GB   Xcode derived data          [xcode.derivedData]
T3   1.1 GB   Xcode archives              [xcode.archives]
T1   127 MB   Installed npm packages      [node.modules]
```

Three things worth noting in that output:

- **17.9 GB of iOS device support** is real, genuinely reclaimable space that
  Finder and System Settings → Storage give the user no way to find.
- **Derived data is one row, not forty.** Terminal rules stop descent, so the
  same gigabytes are never counted twice in one list — which is the fastest way
  a cleanup tool loses trust.
- **Xcode archives correctly landed in Tier 3**, not Tier 1, despite obviously
  being build output. Deleting one means crash reports from that shipped build
  can never be symbolicated again, and it is not practically rebuildable. This is
  the kind of call a pattern-matcher gets wrong unless the rule author thinks
  about consequence rather than category.

## Four editorial rules the table is built on

These are in the source as a doc comment, because the table will be extended and
the reasoning needs to travel with it.

1. **Tier 1 does not mean free — it means "regenerates without losing anything
   you made."** A rebuild that costs twenty minutes is worth saying out loud, so
   `rebuildCost` is a first-class field rather than a footnote.
2. **Confidence below a floor forces Tier 3**, whatever the rule claims. Demoted
   once inside `classify()` rather than at every call site that reads `.tier`.
   The motivating case is `~/Library/Caches`: conventionally disposable, but some
   apps misuse it for state they never rebuild — so it is Tier 1 at 0.75
   confidence, and the UI can say so plainly.
3. **Tier 2 never gets a delete action**, only a pointer to the owning app. Docker
   is the sharpest example: deleting its disk image by hand destroys every named
   volume, including database data. The rule says that, and routes to Docker
   Desktop.
4. **Everything unmatched is Tier 3 with an explicit "I can't tell what this
   is."** A gap in the table produces an over-careful recommendation, never a
   dangerous one — and never an invented, confident-sounding explanation, which
   is F09's stated failure case.

## Step 3's accident became a feature

The 3.7-million-entry Xcode index directory found while debugging the scan is now
a first-class finding. A folder of that shape is invisible to Finder, System
Settings → Storage, and DaisyDisk-style treemaps alike — they all report *bytes*,
and this is a problem of *entry count* — yet it slows every backup, every
Spotlight pass, and every tool that walks the disk.

`RecommendationSet` also carries the largest **non**-recommendable consumers,
which F08's empty case requires: with nothing to suggest, the app must say where
the space actually went ("mostly Photos — nothing I'd advise deleting") rather
than show an empty list that reads as a broken scan.

## One deliberate omission in the headline figure

`totalReclaimableBytes` excludes Tier 2. DiskDrama cannot free that space itself —
it can only point at the app that can — so counting it would promise something the
app does not deliver.

## Next

Step 5 — snapshot persistence and delta computation (F06, F20). The recommendation
set built here is what gets pruned and written.
