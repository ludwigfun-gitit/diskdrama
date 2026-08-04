# Step 9 — Deletion (F14–F16)

**Date:** 2026-08-04
**Commits:** `2678bb7` (build), `ff04f0e` (fixes found by testing)
**Flows:** F14, F15, F16 (A04, A08)
**Status:** **verified end-to-end.** Accessibility came back and the whole flow
was exercised against a disposable tree. Two real defects surfaced and are
fixed.

> The section below describing the verification blocker is kept as written —
> it was accurate when the step was committed, and the misdiagnosis it records
> is worth keeping. **Everything it lists as unverified has since been run.**
> See "Verification results" at the end.

---

## The blocker

Accessibility went down mid-session, system-wide. Not DiskDrama:

```
apps reporting windows:      ← every process on the machine, not just this one
```

System Events can still enumerate processes but can no longer read any app's
windows, so I cannot open the main window, press a Delete button, or read a
sheet. Screen capture was already unavailable. Between them, every channel I had
for driving and observing the UI is gone.

**To restore it:** System Settings → Privacy & Security → Accessibility, and
re-enable whichever terminal or agent process drives `osascript`. It was working
earlier in this session and stopped partway through — most likely a revoked or
lapsed grant rather than anything I changed.

I nearly misdiagnosed this. The window stopped opening right after I wrote the
Step 9 UI, which looked exactly like a regression I had just introduced. I
bisected it — stashed Step 9, rebuilt, tested — and the window still didn't
open. Only then did I check whether *any* app reported windows. It was worth the
two builds: the alternative was "fixing" code that was never broken.

## What I verified anyway

The riskiest filesystem assumption in the step is F16's undo, and that one I
could test without the UI. Against a disposable tree, using the same
`FileManager` calls the service makes:

```
trashed to: /Users/ludwigfun/.Trash/victim
original gone: true
exists in trash: true
restored contents: original contents
gone from trash after restore: true
```

That confirms the two things F16 depends on: `trashItem` hands back a usable
`resultingItemURL`, and moving it back restores the item intact. It does **not**
test my code — only the API contract underneath it.

Also verified: the classification and scan path feeding deletion. A disposable
tree of three folders (two `node_modules`, one `.build`, 378 MB) scanned to
`reclaimable=396.4 MB safe=3/396 MB` with correct rule matches. The tree and the
temporary scan-root override have both been removed; `scan.roots` is back to the
default.

## What is unverified, precisely

Everything from the button to the filesystem:

- The Delete button opening the confirm sheet, and the sheet's copy
- The Trash toggle flipping the primary button's colour and wording
- An actual deletion — trash mode and immediate mode
- The batch sheet's selection, running total, and sequential execution
- "Put back" restoring an item and updating the log
- Every guard **as reached through the UI** (the guard logic itself is
  straightforward and shares one function with the sheet, but it has not been
  observed refusing anything)

## Verification recipe, once Accessibility is back

Do this against a disposable tree, not real files:

```bash
ROOT=/private/tmp/diskdrama-deltest
rm -rf "$ROOT"; mkdir -p "$ROOT"/projectA/node_modules "$ROOT"/lib/.build
for d in projectA/node_modules lib/.build; do
  for i in 1 2 3; do mkfile 42m "$ROOT/$d/chunk$i.bin"; done
done
defaults write com.bloo.diskdrama "scan.roots" -array "$ROOT"
```

Note `mkfile` **without** `-n` — sparse files read as ~0 bytes to this scanner,
which measures physical blocks, so `-n` produces a tree that scans to nothing.

Then: Scan → Safe tier → select a row → Delete → confirm in Trash mode. Check
`~/.Trash`, check the History pane shows "moved to Trash" with a **Put back**
button, press it, confirm the folder returns. Repeat with the toggle **off** and
confirm the button turns red, reads "Delete … permanently", and that the
resulting log row has **no** Put back button. Then "Clean all" for the batch
path. Afterwards:

```bash
rm -rf /private/tmp/diskdrama-deltest && defaults delete com.bloo.diskdrama "scan.roots"
```

## Design decisions worth recording

**One legal call site.** `DeletionService.perform` is the only code in the app
that removes anything — there is no other `trashItem` or `removeItem` anywhere.
Auditing deletion means reading one file.

**An allowlist, not a blocklist.** A path is refused unless it sits *inside* a
configured scan root. Enumerating what to forbid means being wrong about one
entry; requiring membership means anything unanticipated is refused by default.
Scan roots themselves, the home directory, and system prefixes are refused on
top of that.

**The sheet and the service share one guard function.** The sheet calls it to
decide whether to offer the button at all; the service calls it again at
execution. Not two implementations of the same rules that can drift apart.

**Trashed and reclaimed are counted separately.** Trash-mode bytes are still on
the disk until the Trash is emptied. Folding them into a "freed" figure would be
a claim the app cannot back up — and A04's ripple into F24 says so explicitly.

**The Trash toggle resets on every sheet open.** A user who flips one job to
permanent must not find the next job pre-armed. This is the one setting where a
sticky value does real damage.

**A failed deletion is still logged.** The history shows the attempt with its
reason rather than silently omitting it.

## Out of scope, flagged

**The drift check has a ceiling.** Above 200,000 files the subtree is not
re-measured before deleting, because walking a million-entry folder takes
minutes and would look like a hang. Existence and all other guards still apply.
F14's precondition is therefore fully enforced only below that ceiling — the
service reports which case applied rather than implying a check that didn't run.

**Partial-batch reporting is thin.** `DeletionOutcome.partial` exists in the
model and the batch loop runs sequentially so "it stopped here" is answerable,
but the batch sheet does not yet summarise a partially-completed job. F15's
"report exactly what remains" deserves a proper pass — logging it here rather
than half-doing it.

## Next

Step 10 — snooze / dismiss / exclude, and the Settings surface (F17–F19), which
should absorb the interim API-key sheet from Step 8.

**I would not move past this without the verification above being run.** Every
other step's gap costs a wrong number on screen; this one costs files.


---

# Verification results (added after Accessibility was restored)

Run against a disposable tree under `/private/tmp/diskdrama-deltest` —
`node_modules` and `.build` folders of 126 MB each. Nothing real was touched.

| Flow | Result |
|---|---|
| F14 single delete, Trash mode | Folder moved to `~/.Trash`, log `moved to Trash — 132 MB`, row left the list |
| F14 permanent mode | Folder gone from disk **and** absent from the Trash, log `deleted permanently` |
| A04 toggle copy | ON → "Recoverable from the Trash…", OFF → "Removed right now… there is no undo" |
| A04 button changes with it | Confirm button 179pt wide with Trash on, 216pt with it off — the label really does change |
| F15 batch | Sequential, both items trashed, one failure isolated without stopping the job |
| F16 undo | Restored to the original path, gone from the Trash, log `restored from Trash` |
| F16 asymmetry | Trash rows show **Put back**; permanent and failed rows show **no button at all** |
| Guard | Refuses a missing item with the right reason |
| Trash collision | Second delete landed as `node_modules 17-39-21-337` — exactly why `trashedPath` is recorded rather than derived |

## Two defects the test found

**1. The guard's allowlist depended on filesystem state.** `standardizingPath`
collapses `/private/tmp` to `/tmp` **only when the path exists**. So an
already-deleted item normalised differently from the scan root containing it,
the prefix test failed, and the guard refused with *"outside the places you
asked DiskDrama to look"* for a folder plainly inside one.

The refusal erred safe — a mismatch always refuses — but it erred *confusingly*,
and a guard whose answer depends on filesystem timing has no business being the
only thing standing between the app and someone's files. Canonicalisation is now
unconditional and disk-independent. Re-tested: the same case reports *"That
folder isn't there any more — something else removed it since the last scan."*

This is the clearest argument for the brief's `/tmp`-only rule. The bug was
invisible to inspection and only appeared when a batch happened to contain an
item that had already gone.

**2. The history footer counted trashed bytes as freed.** It read *"264 MB freed
all-time"* while half of that was still in the Trash. A04's ripple into F24 says
a Trash job must not claim reclaimed space; that applies to the quiet all-time
figure as much as to the headline. Now: *"132 MB freed all-time, across 6
cleanups. A further 396 MB is in the Trash — that space comes back when you
empty it."*

## An accessibility regression from Step 6, fixed here

The Changes and History nav rows rendered and clicked correctly but exposed
themselves as **AXUnknown** — invisible to VoiceOver, unreachable by keyboard.
Cause: `.accessibilityElement(children: .ignore)` applied *outside* a `Button`
strips its role. `HoverRow` now owns its accessibility per branch — label on the
Button with children hidden, collapse only on the inert row that has no button
to preserve.

Worth noting how it was caught: not by an audit, but because the rows were
missing from the AX tree while I was trying to reach the History pane. The
accessibility tree being my test harness is why it got found at all.

## Also confirmed in passing

**Step 8's API request works.** `explanation — in=136 out=301 cacheWrite=1169
cacheRead=0 model=claude-opus-5`, with no fallback-retry line — so structured
outputs, adaptive thinking, prompt caching and server-side fallbacks are all
accepted together, and the system prompt clears the 512-token cache minimum. The
panel showed genuinely model-written prose, including the observation that a
path under `/private/tmp` "looks like a scratch or test project that macOS may
clear on its own anyway" — which no rule table would have said.

## Left behind

Three `node_modules` folders (~378 MB total) are in the Trash from these tests.
I don't empty the Trash — that one is yours.
