# DiskDrama

Read ~/.claude/CLAUDE.md for global orientation.

- MC:L project: `proj_2FQ0N4nl`, code `DD` (already existed — it did not need creating)
- Backlog: GET http://192.168.254.77:5173/api/lifecycles/entries?project_id=proj_2FQ0N4nl
- Reports: write to `.cc-reports/reports/` in this directory
- Briefs: read from `.cc-reports/briefs/` in this directory
- Architectural rules apply: yes
- Design rules apply: yes (macOS-scoped section of design-rules.md is thin — see the preflight's Process Decisions for what Round 1 fell back to)
- Platform: macOS 14 Sonoma+, Swift, SwiftUI + AppKit (menubar stays AppKit per v0), com.bloo.diskdrama
- Distribution: direct only (notarized, Developer ID) — Full Disk Access is incompatible with the App Sandbox, not App Store eligible as spec'd

## Quick context

**This is an expansion of an existing shipped app, not a new build.** v0 (`DiskDrama.swift`, `build.sh`) is a working single-file AppKit menubar free-space monitor — read it before touching anything, it's the retained starting point for F01–F04, not a rewrite target.

Full spec: `Efforts/DiskDrama/diskdrama-blueprint.md` (25 user flows, all resolved) and `Efforts/DiskDrama/diskdrama-preflight.md` (architecture, MVP estimate, market, legal — all phases GO as of 2026-08-04) in the ideaverse-vault. Read both before Step 0.

Visual design: `design_handoff_diskdrama_ui/` in this repo (Claude Design handoff — high-fidelity tokens, typography, all screens/sheets). Shares Visuals' `Theme.swift` tokens by explicit design call — see `Repos/Visuals/Visuals/UI/Theme.swift` in the vault, copy (don't package-extract) per the preflight's Architecture section.

Key risk to read before writing the scan engine: iCloud/File Provider XPC hangs (architectural-rules.md §5.1/§2.2/§2.3/§5.2) — this vault is itself iCloud-synced, so the risk is concrete, not theoretical. Default scan roots exclude `~/Library/Mobile Documents`.

## Build & run

```bash
~/Scripts/dev-build-install.sh          # build Debug (Developer ID), install to /Applications, relaunch
```

v0's `build.sh` / `package.sh` (raw `swiftc`) are retained only as historical reference — the Xcode project is authoritative.

**MC:L note (updated 2026-08-12):** the Tailnet is no longer in use. Hombre is on
the LAN at `192.168.254.77` and MC:L is reached directly on port 5173. The `/mc`
prefix was the Tailnet reverse proxy and is **gone** — paths start at `/api`:

```bash
curl -s "http://192.168.254.77:5173/api/lifecycles/projects"
```

## Testing on Hombre

Hombre is a second Mac (`ludwigfun@192.168.254.77`). DiskDrama can't ship through
TestFlight at all — Full Disk Access is incompatible with the App Sandbox — so a
test build goes over directly:

```bash
~/Scripts/dev-deploy-remote.sh --build ludwigfun@192.168.254.77 DiskDrama
```

Notarization is not involved. `com.apple.quarantine` is set by whatever downloads
a file; `scp` sets nothing, so a Developer ID build copied this way launches with
Gatekeeper uninvolved. `make-dmg.sh` is the distribution path, not this one.

Grant Full Disk Access on Hombre **once**, after the first deploy. It survives
every later deploy because the build is signed with a constant Developer ID
rather than ad-hoc, so the signature hash — and therefore the TCC grant — is
stable.

## First-session TODOs (Phase 9)

- [x] MC:L project record — already existed as `proj_2FQ0N4nl` / `DD`.
- [x] Repo added as a git submodule inside `ideaverse-vault` under `Repos/DiskDrama`.
- [x] First `decision` entry logged on MC:L (`DD.D001`) capturing scope/architecture.
- [ ] Stand up a real Xcode project — Step 1 of the MVP build.

## Cadence override (Ludwig, 2026-08-04)

For this project, dev-workflow.md's default "stop and review after every step" cadence is relaxed: CC should build continuously through its own proposed step plan without waiting for a new instruction after each unit, still committing/reporting per unit. Full detail in `.cc-reports/briefs/mvp-build-kickoff.md`. This override applies until Ludwig says otherwise — don't assume it silently expires after one session.
