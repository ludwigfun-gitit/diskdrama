# DiskDrama — Settings UI for the low/critical warning thresholds

## Context
`Settings.swift` (F01) already has `lowThresholdBytes` (default 5 GB) and
`criticalThresholdBytes` (default 1 GB) fully wired — `UserDefaults`-backed,
with working get/set accessors. `MenubarController.render()` already reads
them live to pick the icon's tint (just verified working after the SF Symbol
swap: white/black normal, orange below `lowThresholdBytes`, red below
`criticalThresholdBytes`). The only missing piece is a way for the user to
actually change these two numbers — right now it's UserDefaults-or-nothing.

## What to build
A new section in `SettingsSheet.swift`, matching the existing `Section(title:blurb:)`
pattern used by `scanRootsSection` / `exclusionsSection` / etc. Two controls:

- "Warn below" → `Settings.shared.lowThresholdBytes`
- "Critical below" → `Settings.shared.criticalThresholdBytes`

Numeric GB input (whole or fractional), styled consistently with the rest of
the sheet (`Theme.mono` for the number, `settingsCaption()` for helper text,
same spacing/card conventions as `PathList`). Exact control type (TextField,
Stepper, TextField+Stepper combo) and exact placement in the section order
are your call — nothing here is load-bearing, just keep the existing visual
language, don't introduce a new one.

### Validation
`criticalThresholdBytes` must always stay strictly below `lowThresholdBytes`
— a value below critical is definitionally also below low, so an inverted or
equal pair is a contradiction the UI should never allow. Decide the exact
handling yourself (clamp the other value, reject with an inline caption,
whatever reads cleanest against the existing caption pattern in
`deletionSection`) — not worth escalating, just make sure it's impossible to
save a broken pair.

### Live propagation
Changing a threshold needs to update the menubar icon immediately — the
`DiskMonitor` poll interval defaults to 10 minutes, so without an explicit
refresh hook the user would type a new value and see nothing happen for up
to 10 minutes. `AppModel` doesn't currently have a path to reach
`MenubarController` (it's owned by `AppDelegate`, wired via closures —
`onScanRequested`, `onSettingsRequested`, etc., all menubar→model direction).
Add the missing direction: an `AppModel` closure (name it consistently with
the existing ones) fired when a threshold changes, wired in `AppDelegate` to
`menubar?.refreshDisplay()` — same closure convention already in use, not a
new mechanism (no `NotificationCenter`, no polling change).

## Constraints
- Reuse `Settings.shared`'s existing accessors — no new storage path.
- Match the existing section's visual style exactly — `Section(title:blurb:)`,
  `settingsCaption()`, existing button styles if a control needs one.
- GB only — no unit picker, no percentage mode, no per-volume thresholds.
- Live-verify before calling it done: build/install/launch, actually change
  both thresholds in the running app, confirm the menubar tint updates
  immediately (no relaunch, no waiting for a poll), confirm both values
  persist across a relaunch.
- Same reporting cadence as the rest of this build: only stop and report for
  a genuine risk, deviation, or blocker. Otherwise commit with a clear
  message and keep going.

## Not in scope
Per-volume thresholds, percentage-based thresholds, the alert quiet-period
setting (F25, already exists, untouched), any other Settings section.
