# Step 6 — Main window shell, sidebar, tier list

**Date:** 2026-08-04
**Commit:** `1da3d71`
**Flows:** F08 (+ F06/F07 surfaced in the window, F20/F22 views)
**Status:** built, installed, exercised live — tier switching, nav, a completed
scan, and an abandoned scan all verified on the running app.

This is the first step where `DiskDrama.dc.html` was read properly — markup and
the `renderVals()` script both. The script matters: the tier-card, row, nav and
button styles exist *only* there, not in the README.

---

## What the window is

Chrome bar (46px, handoff-drawn, system traffic lights) over a 262px rail and a
content pane that swaps per tier. The rail's reading order is the handoff's and
is load-bearing: *how bad is it* → *what can I do* → *has this happened before*
→ *where did it actually go* → settings.

Built to the HTML rather than the README where the two disagree — see
"Discrepancies" below.

## Three things the design assumes but the engine didn't provide

**1. The window has to show the last scan, and nothing could.** F08's trigger is
"scan completion; **main window at any time (shows last scan)**", but
`ScanEngine.recommendations` only exists for a scan run in this session. Opening
the app the next morning would have shown a blank pane over a perfectly good
snapshot — and a blank recommendations pane reads as a broken app, not as "you
haven't scanned yet". `SnapshotRestorer` rehydrates it.

Only the classification's *identity* is persisted, never its prose. The prose is
re-derived from `KnowledgeBase` by key, so improving an explanation improves it
for old snapshots too. The stored tier is used as-is — the snapshot is a record
of what that scan concluded, not an invitation to re-run the rules against it.

The Changes view gets the same treatment: the delta is recomputed from the two
most recent snapshots, so regrowth survives a relaunch.

**2. Two independent polls of the same volume.** The sidebar needs free space and
so does the menubar. Left alone that would have been two timers reading the same
number on their own schedules, and the first time they disagreed the app would be
showing the user two different answers to "how much space do I have" on one
screen. `DiskMonitor` now owns the poll; both surfaces read it.

**3. Progress read `0 bytes` for minutes.** Step 3 deferred this here, correctly.
The old figure summed the root nodes, which only accrue at post-order, so a deep
tree reported nothing until whole subtrees completed. Accurate and useless is
still useless: a progress number that doesn't move is indistinguishable from a
hang, which is the exact confusion Step 3 spent a day on. Now a running
accumulator — verified climbing from the first tick (`14,340 items · 7.0 GB` →
`73,685 items · 23.8 GB`).

## A correctness bug the first run exposed

The mini storage map claimed "where it all went" and counted the same bytes up to
three times: `Xcode` (23.7 GB), `iOS device support files` (17.9 GB) *inside* it,
and one of that folder's own children. The two source lists nest freely and a
naive merge shows both.

Fixed structurally rather than by filtering the symptom: largest-first plus an
ancestry test, so the cells partition the space instead of overlapping. A second
divergence fed it — the restore path was collecting non-recommendable items from
every persisted depth while the live builder only ever collects the roots'
immediate children. The two paths now agree about the same scan, which matters
more than either being individually richer.

## What live testing changed

I could not screenshot (no screen-recording grant), so verification went through
the accessibility tree — which turned out to be more useful than a picture,
because it caught two things a screenshot wouldn't have.

**Rows had no accessibility identity.** I first built nav and item rows as
`onTapGesture` on a styled rectangle. That renders correctly and is invisible to
VoiceOver, unreachable by keyboard, and has nothing to press. They are `Button`s
now — visually identical under `.plain`, but with a role, focus and an action.

Wrapping them then collapsed their child text into unlabelled elements, so every
control announced as a bare "button". Labels are now explicit and state the size
before the path — the number is what the row is *for*, and a screen-reader user
shouldn't have to sit through a long path to reach it.

**Disabled controls looked live.** A custom `ButtonStyle` gets no disabled
appearance from SwiftUI. "Clean all 11…" and "Get me to…" — both awaiting later
steps — rendered identically to working buttons. A control that invites a click
and does nothing is worse than no control; both styles now read `\.isEnabled`.

**Two formatting defects, both from trusting a stdlib default.**
`Int.formatted()` renders 12991 as `12.991` under a European locale, sitting
beside `6.9 GB` where the same dot is a decimal point — because every size in this
app is formatted non-locally to match Finder. One separator meaning two things in
one line is worse than not localizing at all; `ByteFormat.count` now groups with a
comma. And `RelativeDateTimeFormatter` rendered a just-finished scan as **"Scanned
in 0 seconds"** — future tense, zero magnitude. Anything inside a minute is now
"just now".

**Stopping a scan said nothing.** F07 keeps the previous snapshot authoritative,
so an abandoned scan leaves the window looking exactly as it did before — which
reads as the Stop button having done nothing. The outcome is now stated in the
title bar and cleared when the next scan starts.

## Two hypotheses I tested and dropped

Both would have been plausible bug reports. Neither survived a measurement.

- **"Opening the window blocks the main thread on a store fetch."** Eight
  consecutive polls found no window, then it appeared — consistent with a
  multi-second synchronous SwiftData read. Instrumented it: **0.11 s**. The delay
  was System Events' own menu-tracking overhead. No restructuring done.
- **"A wedged scan thread prevents the app from quitting."** I saw two instances
  coexist and a window apparently vanish. Controlled test — scan wedged 44 s on
  the pathological directory, then quit — **exited cleanly in under 15 s**. The
  "vanished window" was me querying the dying instance during a relaunch race, not
  a window-management bug. Reported as an observation, not a mechanism.

## Discrepancies between the README and the HTML

The HTML is the resolved design, so it wins; flagging both rather than silently
picking.

- README describes tier item rows as "icon (30px chip) + title + path + … +
  chevron". The resolved HTML rows have **neither icon nor chevron** — only
  History rows carry an icon chip. Built to the HTML.
- The mini map has a "Map" link the README itself notes opens a view that was
  never designed. **Omitted** rather than shipped as a dead link.

## Deliberately not in this step

Per the Step 0 plan, and so the seam stays where F08 ends and F09 begins:

- The fixed-bottom explanation panel, Look inside, Reveal in Finder, Open owning
  app, drill-down — Step 7. The per-tier selection this step builds is what that
  panel consumes.
- All three sheets (Clean all, Delete confirm, Get me to…) — Steps 9 and 12. The
  buttons exist and are visibly disabled.
- Settings surface — Step 10. The rail's Settings row is inert and rendered
  rather than hidden; its absence would be the more confusing of the two.
- "Watching" has no destination until F21 (Step 11), so it shows its count and
  is deliberately not a link.

## Out of scope, flagged not fixed

**Largest-non-recommendable is coarser than the design's copy needs.** The
builder collects only the roots' *immediate* children, so with the home directory
as root it can name `Pictures` but never `Photos Library.photoslibrary`. The
handoff's line — "your Photos library (26 GB) and Music (14 GB)" — wants one level
deeper for container-shaped folders. Affects F08's empty case and the Review
tier's "not on this list" callout. Belongs with Step 7 or the Step 15 polish pass,
not with a UI step.

**Blind spots have no designed home.** The design never shows them, but F06 is
explicit that unreadable locations are recorded and shown. I added a callout at
the foot of the tier list stating how many locations couldn't be read and how many
need Full Disk Access — totals over a tree with holes are a floor, not a
measurement. Cross-cutting blind-spot messaging is still Step 15's.

## Verified on the running app

- Window opens from the dropdown's new **Open DiskDrama (⌘O)**; activation policy
  flips to `.regular` and back on close; frame autosaves across launches.
- Rehydration: `restored=true recommendations=3` in **0.11 s**, title bar
  "Scanned 3 hours ago" before any scan ran this session.
- All three tier cards switch the pane. **"Clean all" exists on Safe only** —
  button count drops by exactly one on the other two tiers (A08).
- Changes and History panes reachable and rendering their empty states.
- F08 empty case: *"None of the apps I know about are sitting on storage you'd
  clear from inside them. Your space is mostly Xcode (23.7 GB) — nothing I'd
  advise deleting."*
- Full scan end-to-end from the window's own Scan button: progress climbing,
  results, sidebar and map all updating, "Scanned just now".
- Abandon path: wedged on the 3.7-million-entry index directory, title bar showed
  `Reading "v5"…` → `Still reading "v5" — 102s`, Stop returned the app to idle
  instantly with the reason stated.
- Zero build warnings under Swift 6.

Scan roots were temporarily pointed at `~/Library/Developer` and `~/.npm` to
exercise the success path without waiting on the pathological directory; the
default (home directory) has been restored. Nothing was deleted at any point —
there is no deletion code yet.

## Next

Step 7 — the explanation panel: F09's per-item prose, F10's "Look inside", F11
Reveal in Finder, F12 Open owning app, F13 drill-down.
