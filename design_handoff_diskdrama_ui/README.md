# Handoff: DiskDrama macOS UI

## Overview
DiskDrama is a macOS utility that scans a Mac for reclaimable disk space and walks the user through cleaning it up — safely. The core idea: not all reclaimable space is equally safe to delete, so the UI organizes everything into three trust tiers (Safe to delete / App-managed / Review first) instead of one flat list. The design also covers the menubar "ambient monitor," a low-space alert, and the first-launch Full Disk Access request.

## About the Design Files
The bundled file, `DiskDrama.dc.html`, is a **design reference built in HTML** — an interactive, clickable prototype showing intended look, layout, and behavior. It is not production code to copy directly. The task is to **recreate this design as a native macOS app** (SwiftUI, per the sibling apps Visuals/Turfs in this same product family) using the codebase's existing patterns — window chrome, sidebar/detail navigation, sheet presentation, etc. Do not attempt to ship or wrap the HTML.

`DiskDrama R2 explorations (superseded).dc.html` is an earlier round of exploration (different layout options for the recommendations list, and a menubar-popover-vs-window comparison) kept for context only — the resolved direction is entirely in `DiskDrama.dc.html`. Ignore it unless you want the "why" behind a decision.

Open `DiskDrama.dc.html` in a browser; it's a single self-contained interactive page. A Light/Dark toggle sits top-right of the canvas. Click into sidebar tiers, expand item rows, and open the three sheets (Clean all, Delete confirm, Get me to) to see all states.

## Fidelity
**High-fidelity.** Every screen has final colors (exact hex, both light and dark), final typography, final spacing, and working interaction states. Recreate pixel-for-pixel where SwiftUI allows; where a value doesn't map 1:1 to a native control (e.g. a custom sheet layout), match the visual result as closely as the platform allows.

## Design system relationship
DiskDrama's surfaces, text colors, and primary accent are **lifted directly from the sibling app Visuals** (`Ideaverse/Repos/Visuals/Visuals/UI/Theme.swift`) — same chrome/canvas/rail/panel grays, same accent blue, same "glow" cyan token. If Visuals' `Theme.swift` (or an equivalent shared token file) already exists in the target codebase, reuse it rather than re-declaring these values. DiskDrama adds exactly three things on top: a blue→purple brand gradient (decorative only — logo/wordmark, not app chrome), a violet tier-intensity system, and a fuchsia danger color (diverges intentionally from Visuals, see below).

## Screens / Views

### 1. Main window (`#3a`)
**Purpose:** The core "what can I delete and why" experience.
**Layout:** macOS window, 1160×748 in the mock (not a fixed app size — recreate at whatever the app's real minimum window size is). Standard traffic-light title bar (46px), then a two-pane body: a 262px fixed sidebar and a flexible content pane.

**Title bar:**
- Traffic lights (standard macOS, 12px circles, `#FF5F57` / `#FEBC2E` / `#28C840`)
- "DiskDrama" title, 13.5px/600
- Right-aligned: "Scanned 3 days ago" (12.5px, `--t3`), a "Get me to…" ghost button, a "Scan" solid accent button

**Sidebar (top to bottom):**
- Free space summary: `42.3 GB` (21px mono/600) + "free of 494" (12px, `--t3`), a 5px progress track, and a one-line reclaimable callout in accent color
- **Tiers section** — eyebrow label "TIERS" (10.5px, tracked caps, `--t3`), then three tier cards, each: 28×28px icon chip (rounded 8px), title (14px/700), subtitle (12px, `--t3`), size (14px mono/700, right-aligned). See "Tier system" below for exact color treatment.
- **Nav rows** (Changes / History / Watching) — 13px text rows, each with a trailing metadata badge (e.g. "3 regrown" in accent, "412 GB all-time" in `--t3`)
- **"Where it all went" mini storage map** — a 3-column CSS-grid treemap of top space users (Xcode/Photos/Docker + 3 empty cells), all cells neutral gray (`--track`) — no cell should be accent-colored; that was a mistake corrected during design (a "selected" look with no selection behind it). A "Map" link (accent, 11.5px) presumably opens a fuller view (not designed).
- Settings row pinned at the bottom (gear icon + label)

**Content pane (per tier, swapped via tier selection):**
- Header: tier title (19px, Space Grotesk/600) + one-line description (13.5px, `--t2`) + a "Clean all N…" button (Safe tier only — the other two tiers have no batch action, by design: App-managed routes to the owning app, Review first is one-at-a-time only)
- Scrollable item list: each row is icon (30px chip) + title (14px/600) + path (11.5px mono, `--t3`) + optional status badge (e.g. "Back again", "Regenerates") + size (14px mono/600) + chevron. First row of the list is pre-selected/expanded (uses a neutral hover-tint background + accent-colored title — NOT an accent-filled background; see "Selection color" note below).
- Fixed-bottom explanation panel (only shown for the selected item): item name (15px, Space Grotesk/600) + metadata line (mono, includes the cyan "high confidence" live-confidence indicator where relevant) + a 2-column explanation ("what this is" / "consequence of deleting") + optional expandable "Look inside" contents table + an action row (Look inside / Reveal in Finder / Watch this / Not now ghost buttons, and a right-aligned primary Delete button)

**Changes view** (sidebar → "Changes"): replaces the tier list with a delta view — items that regrew since last cleaned, shown as `0 GB → 21.4 GB` with an up-arrow in accent color, plus a callout box.

**History view** (sidebar → "History"): chronological cleanup log — icon, item name, "moved to Trash" vs. "deleted permanently", timestamp, size — with an all-time total footer.

### 2. Menubar dropdown (`#3b`)
**Purpose:** Ambient, always-available status + quick actions — the thing users see far more often than the main window.
**Layout:** Simulated macOS menu bar (26px) + a 330px popover anchored top-right. Contents: free-space readout + progress bar + "checked Ns ago" with a live cyan pulse dot, a reclaimable-space callout, then a plain macOS-style menu list (Open DiskDrama / Scan now / Refresh / — / Settings… / Quit), each row showing its ⌘-shortcut.

### 3. Low-space alert (`#3c`)
**Purpose:** The one moment the app proactively interrupts — critically low free space.
**Layout:** A macOS-style notification card. Danger-red icon chip (34px), headline using the danger color for the "4.1 GB free." fragment only, body text in `--t2`, two actions ("Show me" solid accent, "Rescan" ghost).
**Rule to preserve:** danger color appears **only** here and in delete confirmations — nowhere else in the app.

### 4. First-launch Full Disk Access (`#3d`)
**Purpose:** Explain why the permission is needed before asking for it; make skipping easy and non-threatening.
**Layout:** A single-pane onboarding step (step 2 of 3). Large headline (28px, Space Grotesk/600), body copy, a 2-column "What I do / What I never do" reassurance card pair, a waiting-state row with a live cyan pulse dot + "Open System Settings" button, and a "Skip for now" ghost option.

## Interactions & Behavior
- **Tier switching** (sidebar): clicking a tier card swaps the entire content pane (list + explanation panel) to that tier's items. Only one tier active at a time.
- **Item selection**: clicking a row expands/updates the bottom explanation panel for that item. In the mock, only the Xcode DerivedData row is wired to fully expand/collapse via "Look inside" — treat all rows as needing the same behavior in production.
- **"Look inside"** toggles an inline contents table (biggest sub-folders/files) inside the explanation panel.
- **"Clean all N…"** (Safe tier only) opens a modal sheet: a list of all safe items with checkboxes (all checked by default), a running total, and a prominent **"Move to Trash" toggle** — this is the one safety-critical control in the whole app.
- **Delete (single item)** opens a smaller confirm sheet with the same Trash/permanent toggle.
  - **Trash toggle behavior**: when ON (default), the sheet/confirm copy reads "Recoverable from the Trash. The space frees up when you empty it," and the primary button reads "Move N GB to Trash" in the normal accent color. When OFF, copy reads "Removed right now… there is no undo," and the button switches to the danger color and reads "Delete N GB permanently." **This toggle is the app's single most important safety mechanism — implement it exactly as described, including the button re-coloring.**
- **"Get me to…"** opens a sheet where the user sets a free-space target; the app shows a plan (safe items + app-managed items + anything needing manual review) and is explicit when the target is **not fully reachable** — it should never silently overpromise (e.g. it explicitly excludes the Photos/Music libraries from any plan).
- **Theme toggle** (Light/Dark) in this prototype is a presentation convenience for reviewing the design — in the real app, this should follow the system's Light/Dark appearance setting, not be a manual in-app toggle (see Visuals' pattern: `Theme` resolves automatically via dynamic NSColor).

## State Management
Minimum states needed:
- `theme`: 'light' | 'dark' (system-driven in production)
- `activeTier`: 'safe' | 'app' | 'review'
- `activeView`: 'tiers' | 'changes' | 'history' (sidebar nav)
- `selectedItemId` (per tier): which row's explanation panel is showing
- `lookInsideOpen`: boolean, per expanded item
- `activeSheet`: null | 'batchClean' | 'deleteConfirm' | 'getMeTo'
- `moveToTrash`: boolean (defaults true) — scoped per delete action, resets each time a sheet opens
- Batch-clean sheet needs per-item checkbox state + a running total derived from checked items

## Design Tokens

### Colors — Light theme
| Token | Value | Usage |
|---|---|---|
| `--page` | `#EFEFF2` | canvas page background (outside the app window) |
| `--canvas` | `#FBFBFC` | app window / content background |
| `--chrome` | `#E9E9EC` | title bars, menubar popover chrome |
| `--rail` | `#E6E6EA` | sidebar background |
| `--panel` | `#E3E3E7` | secondary panel fill (explanation panel bg) |
| `--line` / `--line2` | `rgba(0,0,0,.09)` / `rgba(0,0,0,.17)` | hairlines / stronger borders |
| `--t1` / `--t2` / `--t3` | `#1D1E22` / `#62646C` / `#9A9CA4` | primary / secondary / tertiary text |
| `--acc` | `#2F7BF6` | **primary accent — identical to Visuals' accent token.** Buttons, links, selected text, focus. |
| `--acc2` | `#1E63D6` | accent hover/pressed variant |
| `--danger` | `#C6324E` | destructive-only: delete confirmations, low-space alert |
| `--glow2` | `#0EA59D` | live-status cyan (freshness dot, confidence indicator, waiting-for-permission dot) — deliberately ~40° of hue apart from `--acc` so the two never read as "the same blue" |
| `--grad-acc` | `linear-gradient(135deg,#1D5FDB 0%,#4C3AC4 100%)` | **decorative only** — wordmark text, screen-reference badges. NOT used on any functional button. |
| `--grad-tab` | `linear-gradient(135deg,#14398C 0%,#332270 100%)` | active sidebar-tier fill — a darkened version of `--grad-acc`'s same two hues, so it reads as "the same family, resting," not a random navy |
| `--tier1/2/3` | `#3F5CDD` (all three — same hue) | tier-card backgrounds: **one flat hue**, opacity increases per tier (`~5% / 11% / 19%`) — Safe faintest, Review most saturated. This is intentionally NOT three different colors and NOT a gradient. |

### Colors — Dark theme
| Token | Value |
|---|---|
| `--page` | `#0B0C0E` |
| `--canvas` | `#0F1013` |
| `--chrome` | `#1B1C20` |
| `--rail` | `#191A1F` |
| `--panel` | `#212329` |
| `--t1` / `--t2` / `--t3` | `#E9EAEF` / `#9C9EA8` / `#6A6C75` |
| `--acc` | `#3F87F5` (Visuals' dark-mode accent, exact) |
| `--danger` | `#C6324E` (same value both themes, intentionally) |
| `--glow2` | `#2DD4C4` |
| `--grad-acc` | `linear-gradient(135deg,#2E6FE0 0%,#5B3FCC 100%)` |
| `--grad-tab` | `linear-gradient(135deg,#1B4386 0%,#36267A 100%)` |
| `--tier1/2/3` | `#8B9AFA` (all three), opacity `7% / 14% / 24%` |

All surface/text/accent values above (excluding gradient, tier, and danger tokens) should match `Theme.swift` in the Visuals codebase if that shared source of truth exists — treat Visuals as canonical and DiskDrama as a consumer, not a fork.

### Typography
- **Space Grotesk** (600 weight): all headline-weight text — wordmark, screen titles, tier titles, item names in the explanation panel, dialog titles. Not used in general app chrome/UI.
- **SF Pro Display / system-ui**: everything else — buttons, nav, body copy, sidebar text. This is the native-mac "structure" layer.
- **Epilogue**: longer explanatory body copy (item descriptions, reassurance card text, alert bodies) — 13–13.5px, line-height 1.5–1.6.
- **ui-monospace / SF Mono**: all numbers — sizes, percentages, timestamps, version-style metadata. This is a hard rule: any GB/percentage/count value must be monospaced.

### Spacing & radii
- `--r-sm`: 10px (buttons, tier cards, item rows)
- `--r-md`: 14px (dialogs, feature cards)
- `--r-mac`: 12px (window corner radius)
- Sidebar width: 262px fixed. Item-row padding: 11px 14px. Button height: 28–32px depending on context.

### Borders — important rule
**The only borders anywhere in the UI are neutral gray**, used exclusively to differentiate a button/control from a same-colored background (e.g. a ghost button's outline against the panel behind it). No colored (accent/danger/tier) borders anywhere — every earlier attempt at a colored border was explicitly removed during design. Selection/emphasis is communicated via fill and text color only, never a colored border or ring.

### Motion
- All transitions: `200ms cubic-bezier(.22,1,.36,1)`
- Button press: `scale(.985)`
- Hover on primary buttons: `filter: brightness(1.08)` + a soft accent glow shadow (`--glow-acc-sm`)

## Assets
No custom icons or images — all icons in the mock are inline SVG stand-ins for **SF Symbols** (per the product's stated "native structure" direction). Recreate with actual SF Symbols in the real app rather than importing an icon library. No photographic or illustration assets used anywhere.

## Files
- `DiskDrama.dc.html` — the resolved, current design. Open in any browser; fully interactive (tier switching, sheets, Look inside, Trash toggle, Light/Dark).
- `DiskDrama R2 explorations (superseded).dc.html` — prior-round layout explorations, for context only.
