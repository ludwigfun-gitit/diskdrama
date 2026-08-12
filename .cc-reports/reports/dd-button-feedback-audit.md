# DiskDrama — button feedback audit

**Asked for:** after `Stop looking here` and `Stop excluding` were both found to
mutate state and change nothing on screen, check every control in the app for
the same failure.

**Scope:** all 60 interactive controls in `DiskDrama/UI/` — `Button`, `Menu`,
`onTapGesture`. Method: for each, trace the action to the state it writes, then
check whether any rendered view reads that state.

**Result:** 4 defects. 3 fixed, 1 judged defended and left alone.

---

## The test applied

A control passes if pressing it changes something the user can see, *in the
place they are looking*, without waiting for a rescan. Three ways to pass:

1. **Self-evidencing** — the action *is* a visible change (open a sheet, switch
   pane, toggle a tick, start a scan, launch another app).
2. **Filtered out of a list** — the action writes to state that a visible list
   filters on, so the row leaves. This is how `Not now`, `Never suggest this`
   and `Never look in this folder` work, and why they always felt responsive.
3. **Explicit notice** — the action can fail, and the failure is rendered.

The two reported bugs were category-2 controls writing to state **no visible
view filtered on**. That is the pattern the audit hunted for.

---

## Findings

### 1. A failed "Put back" was silent — every time · HIGH · fixed

`AppModel.undo` is the restore path behind History's `Put back`. On failure it
sets `deletionError`. The only thing that renders `deletionError` is
`ResultsNotices` — which `MainWindow.contentPane` instantiated **inside the
`.tier` case only**.

`Put back` exists solely on the History pane. So the one failure a user could
provoke from that pane was the one guaranteed never to be shown: the restore
threw, the entry stayed un-restored, the row did not change, and the
explanation went to `Log.app.error` and nowhere else.

Fixed by rendering `ResultsNotices` around every pane rather than inside one
case. It collapses to zero height when it has nothing to say, so the other
panes are unchanged — verified: all four pane headers sit at the same y as
before. The reduced-mode banner is global truth and also benefits.

This also closes the question the DD.B011 brief left open ("leave
Changes/History/Watching out of scope unless it's obviously right to extend
there — say so either way"). It is obviously right, for this reason.

### 2. `Stop looking here` could be the only control in its row, in a style with no chrome · MEDIUM · fixed

Same defect as the one already fixed in `UnscannedPane`, still present in
`BlindSpotRow` (the per-tier footnote). `QuietButtonStyle` renders nothing until
hover, which reads correctly in `ExplanationPanel` where an accent `Delete`
anchors the row. For a `.permissionDenied` spot there is no `Grant access` and
no `Retry`, so it was the row's only control — chrome-less, with nothing to
recess against. That is precisely the state a user reported as "missing".

Now ghost, matching its twin. Also added `Stop listing this`, which existed only
in the pane — whether a location can be dismissed should not depend on which
screen the user found it on.

### 3. A failed Keychain write looked exactly like a successful one · MEDIUM · fixed

```swift
Button("Save key") {
    APIKeyStore.save(apiKey)      // returns Bool; discarded
    hasStoredKey = APIKeyStore.hasKey
    apiKey = ""                   // cleared unconditionally
}
```

`APIKeyStore.save` already reports success — the caller discarded it. On
failure the key vanished from the field (which reads as "saved") and nothing
contradicted that. The only tell was `Remove key` failing to appear, which
requires the user to know it should have.

Now the field is cleared only on success, and a failure states plainly that
nothing was stored and the text is still there. `Remove key` got the same
treatment: it re-reads `hasKey` instead of assuming.

### 4. `openApp` fails silently if the launch fails · LOW · not fixed

`FileActions.openApp` logs and returns when the bundle ID cannot be resolved,
and ignores `openApplication`'s completion. But F12 already re-tiers any item
whose owning app is missing *at classification time*, precisely so no "Open
<App>" button is ever shown for an absent app (`OwningAppLocator`). The
remaining window is an app present at scan time and un-launchable at click
time. Fixing it means adding an error surface for a case the classifier already
prevents; left as is, noted here rather than silently.

---

## Everything that passed

| Area | Controls | Passes because |
|---|---|---|
| Sheets (Delete, BatchClean, Target, Settings, Onboarding) | 13 | open/close, or run then close |
| Navigation (tier cards, nav rows, drill-in, breadcrumb, storage map) | 11 | pane or selection changes |
| Scan (`Scan`/`Stop`, empty-state `Scan`, `Scan again`, `Retry`, `Scan now`, `Scan anyway`) | 8 | scan UI takes over |
| List membership (`Not now`, `Never suggest this`, `Never look in this folder`, `Remove`, `Stop watching`) | 7 | row leaves a list that filters on the state |
| Toggles (`Look inside`/`Hide contents`, `Watch this`/`Watching`, trash toggle, batch ticks) | 6 | label or tick inverts |
| External (`Grant access`, `Open System Settings`, `Open <App>`, `Reveal in Finder`) | 6 | another app comes forward |
| Dismissals (`Dismiss` ×2, `Done`, `Cancel`) | 5 | the thing dismissed disappears |

`Reveal in Finder` passes **only since** the fallback added in `3a5c22c`;
before that it returned silently whenever `fileExists` was false, which includes
every TCC-sealed path.

---

## What this class of bug has in common

All four are the same shape: **an action writes to state, and the code that
would show the result is either absent, scoped to the wrong place, or discarded.**
Not one of them is visible in the button's own definition — you have to follow
the state to whatever renders it, and confirm that thing is on screen at the
moment the button is pressed.

`AppModel.excludedPaths` gets this right and says so in its own doc comment:
it exists to mirror `UserDefaults` "so an excluded folder disappears from the
recommendations the moment it is excluded, instead of lingering until the next
scan and making the action look like it did nothing." The mechanism was there.
The blind-spot list simply never used it.

## Not verified on screen

- The per-tier `BlindSpotRow` fix (#2). No blind spot on this machine
  classifies into a tier, so that section renders for nobody right now — the
  change is by construction against the same code path already verified in
  `UnscannedPane`.
- The `Put back` failure notice (#1). Forcing a restore failure means damaging a
  real Trash item; the fix is structural (the renderer now exists on that pane,
  confirmed by pane-header geometry) rather than behavioural.
- The Keychain failure branch (#3). Requires a failing Keychain.
