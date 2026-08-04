# Step 0 — Orient & propose the build plan

**Date:** 2026-08-04
**Brief:** `.cc-reports/briefs/mvp-build-kickoff.md`
**Status:** complete — proceeding directly into Step 1 per the cadence override.

---

## What I read

Full orientation chain resolved. Machine is **Caballero**, so this is CC in the executor role with shell, filesystem, and (with one caveat below) MC:L access.

- `CLAUDE.md` (project) → `~/.claude/CLAUDE.md` → vault `Bootstrap.md`, `Me.md`, `AI OS/dev-workflow.md`, `~/.claude/skills/dev-workflow/SKILL.md`
- `AI OS/architectural-rules.md` and `AI OS/design-rules.md` — both apply
- `Efforts/DiskDrama/diskdrama-blueprint.md` (25 flows, A01–A09 all resolved) and `diskdrama-preflight.md` (GO, 2026-08-04)
- `.cc-reports/briefs/mvp-build-kickoff.md` — cadence override + the deletion safety rule
- `design_handoff_diskdrama_ui/README.md` — full token/typography/screen spec. The 82 KB `DiskDrama.dc.html` itself I have **deliberately not read yet**; it is the pixel reference for Steps 6+ and reading it now would burn context I need for the engine layers. It gets read when the UI steps start.
- v0 source: `DiskDrama.swift` (191 lines), `build.sh`, `package.sh`

## State found on disk vs. what the brief expected

Three of the four "first-session TODOs" turned out to be either already done or now done:

| Item | Expected state | Actual |
|---|---|---|
| MC:L project record | "not yet created" | **Already existed** — `proj_2FQ0N4nl`, code `DD`. Nothing to create. `CLAUDE.md` now filled in. |
| First `decision` entry | to be logged | **Logged** as `DD.D001` — scope, platform, and the architecture commitments below. |
| Vault submodule under `Repos/DiskDrama` | missing | **Added** this step (see Housekeeping). |
| Real Xcode project | missing | Still missing — this is Step 1. |

**MC:L reachability caveat, worth recording.** `hombre.tailfe78ee.ts.net` does **not** resolve through the shell's system resolver on Caballero, despite Tailscale being up and `hombre` being online at `100.96.118.115`. `host` returns NXDOMAIN and a plain `curl` gets HTTP 000. Pinning the IP works:

```bash
curl -s --resolve "hombre.tailfe78ee.ts.net:443:100.96.118.115" "https://hombre.tailfe78ee.ts.net/mc/api/lifecycles/projects"
```

This is a MagicDNS resolution problem in the shell environment, not an MC:L problem — the API answers correctly once reached. Noted in `CLAUDE.md` so the next session doesn't rediagnose it. **Not fixed** — it is outside this build's scope and touching DNS config is not mine to do.

## Existing backlog

One open entry, and it lands squarely inside Step 1:

- **`DD.B001`** (open) — free-space readout off by ~22 GB on Hombre vs macOS Storage. Hypothesis in the ticket: `volumeAvailableCapacityKey` excludes purgeable space where macOS Storage's `…ForImportantUsageKey` includes it. A scheduled remote agent was supposed to open a PR on 2026-05-04; no such PR is in the repo, so the fix never landed.

I am folding this into Step 1 since I am migrating exactly that code — but **not** by applying the suggested two-line change on faith. Per the standing correction on this project (verify the units before redesigning the data source), Step 1 dumps both capacity values from the running process alongside what Storage reports, and the fix follows the ground truth. If the hypothesis holds, the change is trivial; if it doesn't, I report rather than patch.

## Architecture — my read

Mostly a confirmation of the preflight, with **one deliberate divergence** I want on the record before I write code.

### The divergence: POSIX `fts(3)` for traversal, not `FileManager`

The preflight's API surface names `FileManager` for scan enumeration. I am using `fts_open`/`fts_read` + `lstat` instead.

Reasoning: `architectural-rules.md` §5.1 lists `url.resourceValues(forKeys:)`, `url.lastPathComponent`, and `url.pathExtension` as synchronous File-Provider XPC triggers on iCloud-backed paths, and the preflight ranks iCloud XPC hangs as **risk #1** — concrete, not theoretical, because Ludwig's home directory really does contain the iCloud-synced vault. `FileManager.enumerator` hands back `URL`s, so a scanner built on it is one careless property access away from the exact hang Visuals spent real time diagnosing.

`fts` never constructs a `URL` at all. It walks `char *` paths and returns `struct stat` inline. That makes the whole failure class **structurally impossible** rather than avoided by vigilance — which is what §1 asks for ("if the enforcement mechanism is a comment, it is not enforcement"). It is also the traversal API `du` itself uses, so it scales to the millions-of-small-files case (build indexes, `node_modules`) that this app exists to find.

Same outcome the preflight wanted, stronger mechanism. Excluding `~/Library/Mobile Documents` by default (per the preflight's A03 lock) stays in place as belt-and-braces.

### Other commitments

- **Sizes are physical, not logical.** Reclaim figures use `st_blocks * 512`, not `st_size` — that is what actually frees on delete. This will diverge from Finder's logical numbers on sparse/compressed/cloned files; the UI states it rather than hiding it. (F24's "explain divergence in plain language" already anticipates this.)
- **Snapshots are pruned before persisting.** A full home-directory tree is millions of nodes; SwiftData is the wrong tool for that and the preflight only chose it on the premise that the data is small. So I keep the full tree in memory for the session and persist only nodes above a size floor + all recommendation items + roll-ups. That is everything F20's delta needs, and it keeps the preflight's SwiftData choice honest instead of quietly breaking its premise.
- **Deletion is GCD-bridged, never `Task.detached`** — §3.1's trap (continuations can resume on main even from a detached task) makes this mandatory. Guarded by a path allowlist rooted in the configured scan roots, so the service structurally cannot be pointed at `/` or `~/Library` wholesale.
- **Full Disk Access probe** = attempt a read of a known TCC-protected path (`~/Library/Safari`), infer from success/failure. No query API exists; this is the standard technique and the preflight already named it.
- **Bundle ID moves** `com.unruly.diskdrama` (v0's, in `package.sh`) → `com.bloo.diskdrama` (per the preflight). Consequence: the new build is a different app to TCC and to Launch Services, so Full Disk Access must be granted once to the new bundle. Expected, not a regression.

### Blocker found in `.gitignore`

Current `.gitignore` contains `*.xcodeproj/`. Standing up the Xcode project with that in place would leave the project file untracked — the build would work locally and be broken for everyone else, silently. Fixed in Step 1. (Visuals commits its `.xcodeproj`; same treatment here.)

## Proposed step plan

Bottom-up: engine before UI, so every layer is verifiable before the one above it depends on it. Each step = one commit + one report.

| # | Step | Flows |
|---|---|---|
| 1 | Xcode project foundation — migrate v0, `com.bloo.diskdrama`, macOS 14, universal, entitlements, fonts + OFL, trimmed `Theme.swift`, `.gitignore` fix, `DD.B001` verified-then-fixed | F01–F04 |
| 2 | SwiftData model layer + settings store (roots, thresholds, deletion default, exclusions, ignore list) | A03, A04 |
| 3 | Scan engine — `fts` traversal, exclusions, blind spots, pause/cancel, throttled progress | F06, F07 |
| 4 | Classification knowledge base — tier rules, recommendation assembly | F08 |
| 5 | Snapshot persistence + delta computation | F06, F20 |
| 6 | Main window shell, sidebar, tier list (CD handoff) | F08 |
| 7 | Item detail / explanation panel / Look inside / drill-down / Reveal / Open owning app | F09–F13 |
| 8 | AI explanation layer — Anthropic via `URLSession`, fingerprint cache | F09 |
| 9 | Deletion service + confirm sheets + batch + undo (`/tmp` trees only) | F14–F16 |
| 10 | Snooze / dismiss / exclude + Settings surface | F17–F19 |
| 11 | Watch offenders + cleanup log + notifications | F21, F22 |
| 12 | Free-space target planner + verify reclaimed space | F23, F24 |
| 13 | Low-space alert + menubar dropdown rebuild per handoff | F25, F01–F04 |
| 14 | First-launch onboarding + Full Disk Access walkthrough | F05 |
| 15 | Cross-cutting error/blind-spot messaging + light/dark parity + polish | all |

Two ordering notes. The FDA **probe** lands in Step 1 (the scan engine needs it); the FDA **onboarding UI** is Step 14, because it reuses window chrome that does not exist until Step 6. And Step 9 is the safety-critical one — it is built and exercised only against disposable trees I create under `/tmp`, never Ludwig's real files, until he verifies it himself.

## Housekeeping done this step

- `CLAUDE.md` — MC:L id/code filled in, build command documented, MagicDNS workaround recorded, TODO list reconciled.
- `DD.D001` decision entry logged to MC:L.
- `Efforts/DiskDrama/diskdrama-history.md` created in the vault with its first entry.
- Repo added as a submodule at `Repos/DiskDrama` in `ideaverse-vault`. Committed the submodule + `Efforts/DiskDrama/` only — the vault also had unrelated uncommitted changes (`Atlas/Projects MOC.md`, `Efforts/Visuals/visuals-history.md`, a `Repos/Visuals` pointer move) which I left untouched per the brief.

## Nothing is blocked

No open question the Ambiguity Register fails to answer. Proceeding into Step 1.
