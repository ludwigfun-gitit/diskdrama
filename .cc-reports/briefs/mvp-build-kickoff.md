# DiskDrama — MVP Build Kickoff

## Context

Preflight is complete — **GO**, 2026-08-04. Full spec lives in the vault:
- `Efforts/DiskDrama/diskdrama-blueprint.md` — 25 user flows (F01–F25), all ambiguities (A01–A09) resolved.
- `Efforts/DiskDrama/diskdrama-preflight.md` — architecture & feasibility, MVP estimate (~47 Ludwig-hours), market analysis, legal & compliance. All green, no blockers.

**This is an expansion of an existing shipped app, not a new build.** v0 (`DiskDrama.swift`, `build.sh`) is a working single-file AppKit menubar free-space monitor — read it before touching anything. It's the retained starting point for F01–F04, not a rewrite target.

## Cadence override for this build — read carefully, this deviates from dev-workflow.md's default

Ludwig's explicit instruction (2026-08-04): **build as much as possible without interruption.** Do not stop after every step for advisory-Claude/Ludwig review. Specifically:

- Step 0 (orient + propose your own step plan derived from the blueprint and architecture doc) does not require waiting for approval before continuing. Read the spec, form your own picture of the integration points, propose your plan in your Step 0 report, then proceed directly into implementing it.
- Move through your own proposed steps continuously. Still commit at each logical unit (one concern per commit), still write a report per unit to `.cc-reports/reports/` before moving to the next — the reports are the audit trail Ludwig reviews asynchronously, not a gate you wait on.
- Still build, install, and launch the app yourself to confirm it runs without crashing before each commit — a self-check you perform, not a "wait for Ludwig to look at it" gate. Batch relaunches to natural checkpoints (end of a flow group), not every single change.
- Still diagnose properly rather than trial-and-error patch. Still follow `architectural-rules.md` (off-main file ops, iCloud/File-Provider caution, the `Task.detached` trap) and `design-rules.md` / the CD handoff for anything UI-facing.

**Stop and write a report flagging the issue (don't guess, don't proceed) only when:**
- You hit a genuine blocker — build won't succeed after real diagnosis, or an API doesn't behave as the architecture doc assumed.
- Something isn't resolved by the blueprint's Ambiguity Register (A01–A09) and you're genuinely unsure which way to go — check the register first, it's most likely already answered there.
- Context limit is hit — commit cleanly at the nearest step boundary, report state, stop (per dev-workflow's existing rule).

**One hard rule that does not bend for build speed:** never test deletion logic (F14/F15) against Ludwig's real files. Build and exercise a disposable test directory you create yourself (e.g. under `/tmp`, populated with dummy files) until a human explicitly verifies the real thing. This is the app's single irreversible-ish operation — the one place autonomy stops.

## Scope for this brief

The full MVP — all 25 flows (F01–F25) per the blueprint's MVP Scope Summary, nothing deferred. Suggested grouping below — yours to reorder/refine in your Step 0 proposal, this is the *what*, not a prescribed *how*:

1. **Foundation** — Xcode project migration from v0, entitlements, Full Disk Access onboarding (F05), SwiftData models.
2. **Scan engine** — traversal, off-main threading, default iCloud exclusion (`~/Library/Mobile Documents`), snapshot persistence, delta (F06, F07, F20).
3. **Classification + AI** — local tiering knowledge base (F08), Anthropic API explanation layer with fingerprint caching (F09).
4. **Recommendations UI** — main window per the CD handoff (`design_handoff_diskdrama_ui/`), tier list, item detail/preview/drill-down, Reveal in Finder, Open owning app (F08–F13).
5. **Actions** — delete flow, batch approval, confirmation dialogs with the A04 mode checkbox, undo, snooze/dismiss/exclude (F14–F19).
6. **Hygiene loop** — watch offenders, cleanup log, free-space target planner, verify reclaimed space, low-space alert (F21–F25).
7. **Settings, menubar dropdown integration, theme integration** (copy trimmed `Theme.swift`, don't package-extract — see preflight's Architecture section for why), polish pass.

## First-session housekeeping (do this in/around Step 0)

- Create the MC:L project record (`POST /mc/api/lifecycles/projects`) if it doesn't exist yet — the Cowork sandbox that ran this preflight couldn't reach the Tailnet, so it's still pending. Fill in this project's `CLAUDE.md` with the resulting `proj_id`/code.
- Add this repo as a git submodule inside `ideaverse-vault` under `Repos/DiskDrama` — every other active project has this, DiskDrama doesn't yet. Check `git status` in the vault first — there were other uncommitted changes sitting alongside the preflight/blueprint edits as of 2026-08-04 that aren't yours; don't sweep them into your commit.
- Log a first `decision` entry on the new MC:L project per dev-workflow's bootstrap step 6, capturing scope/architecture.

## Reporting rule

After every commit, write a report to `.cc-reports/reports/<slug>.md`. Also append a matching entry to `Efforts/DiskDrama/diskdrama-history.md` in the vault per dev-workflow's existing rule — create that file (it doesn't exist yet for this project) with your first entry.
