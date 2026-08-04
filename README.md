# DiskDrama

A macOS disk cleanup advisor. It keeps watch on free space from the menubar, and
when action is needed it scans, reasons about what it finds, and presents tiered,
risk-annotated recommendations in plain language. You decide; it only ever
executes on an explicit instruction.

The differentiator over the alternatives — DaisyDisk maps space without advising,
CleanMyMac applies rules without reasoning, DiskCopilot hands off to an external
chatbot — is native reasoned advice plus a *hygiene loop*: delta tracking,
watched offenders, and a free-space target, which turns one-off cleanup into
ongoing disk health.

Full specification: `Efforts/DiskDrama/diskdrama-blueprint.md` (25 user flows) and
`diskdrama-preflight.md` (architecture and decision record) in the Ideaverse vault.

## Status

Expanding from **v0** — a shipped single-file menubar free-space monitor — into
the full advisor. The menubar monitor works today; the scan, recommendation, and
cleanup layers are being built.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel
- Xcode 26 or later to build

## Build & run

```bash
~/Scripts/dev-build-install.sh
```

Builds Debug with stable Developer ID signing, installs to `/Applications`, and
relaunches. Stable signing matters: ad-hoc signatures change hash every rebuild,
so macOS TCC treats each build as a new app and drops the Full Disk Access grant.

## Full Disk Access

Most reclaimable space hides in `~/Library`, which macOS protects. DiskDrama
needs Full Disk Access to see it, granted once in **System Settings → Privacy &
Security → Full Disk Access**. Without it the app still runs — the monitor works
fully and scans still work, but unreadable locations are reported honestly as
blind spots rather than guessed at.

Full Disk Access is fundamentally incompatible with the App Sandbox, and the Mac
App Store requires sandboxing. DiskDrama is therefore direct-distribution only
(notarized, Developer ID signed) — the same reason DaisyDisk and CleanMyMac
aren't on the App Store either.

## Diagnostics

```bash
log show --predicate 'subsystem == "com.bloo.diskdrama"' --last 10m --style compact
```

Launch emits volume totals, the purgeable split, Full Disk Access state, and font
registration. File paths are deliberately redacted as `<private>` — they carry
personal context and the unified log is readable machine-wide.

## Third-party assets

Space Grotesk and Epilogue are bundled under the SIL Open Font License 1.1; the
license text ships with them at `DiskDrama/Resources/OFL.txt`. There are no code
dependencies — system frameworks only.
