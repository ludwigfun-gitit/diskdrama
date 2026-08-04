# Step 9 — Deletion: built, and **not verified end-to-end**

**Date:** 2026-08-04
**Commit:** `2678bb7`
**Flows:** F14, F15, F16 (A04, A08)
**Status:** builds clean, installs, launches. **The delete flow has never been
run.** This is the one step where that gap matters most, so it is not going past
without saying so.

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
