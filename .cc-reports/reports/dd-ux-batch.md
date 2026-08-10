# DiskDrama — UX review batch

Five bugs filed in MC:L and worked through in the order the brief asked for:
the data-model one first, then the rest.

| MC:L | bug | status |
|---|---|---|
| `DD.B002` | Deleted rows stay interactive; delete dialog focuses the wrong control | in progress |
| `DD.B003` | Chatty aside about Library/Pictures, no user options | in progress |
| `DD.B004` | "couldn't read 4 locations" is opaque | in progress |
| `DD.B005` | Nested rows double-count | **fixed** |
| `DD.B006` | Focus rings don't match element geometry | in progress |

---

## DD.B005 — nested rows double-count — FIXED

### What was actually happening

Worse than the report described. Instrumented a real home scan and dumped every
recommendation with its path and matching rule:

```
89 recommendations
54 of them nested inside another recommendation
15.7 GB counted more than once
```

One chain, five deep, every level matched by the *same rule*:

```
4.43 GB  ~/Library/Caches                                 [generic.caches]
 +0.74   ~/Library/Caches/CloudKit                        [generic.caches]
 +0.66   ~/Library/Caches/CloudKit/com.apple.bird         [generic.caches]
 +0.66   .../com.apple.bird/2b405a4a…                     [generic.caches]
 +0.65   .../2b405a4a…/MMCS                               [generic.caches]
```

### Root cause

`generic.caches` used `matcher: .under("~/Library/Caches")` with
`isTerminal: false`.

`.under` matches the directory *and every path beneath it*, so the rule matched
at every depth. `isTerminal: false` meant the walk kept descending after a match
instead of stopping. Together, one rule claimed a container and each of its
descendants as separate rows.

The file already explains why that must not happen — the comment on `isTerminal`
reads "this is what prevents recommending DerivedData *and* each of the forty
projects inside it — the same gigabytes counted twice in one list is the fastest
way for a cleanup tool to lose trust." This rule opted out of that protection.

`isTerminal: false` was itself deliberate: descend so a *more specific* cache
rule can claim a subfolder. That intent is preserved below.

### Fix

**A `.childOf` matcher.** Matches immediate children only — not the container,
not anything deeper. `generic.caches` becomes one row per app cache. Every
specific cache rule (`homebrew.cache`, `yarn.cache`, `cocoapods.cache`,
`creativecloud.cache`) is itself an immediate child of `~/Library/Caches`, and
those rules are ordered ahead of the catch-all, so they still win — verified:
Adobe still matches `creativecloud.cache`, not the generic rule. Coverage is
unchanged, which is why the rule can now be terminal.

**An antichain guarantee.** After sorting, the builder drops any row nested
inside another, keeping the outermost. With the matcher fixed this finds nothing;
it stays because "the numbers add up" deserves enforcing where it is stated
rather than relying on every future rule to preserve it by construction. It keeps
the ancestor because the ancestor's total already contains the descendant —
dropping the ancestor would lose bytes, dropping the descendant loses only detail
still reachable through "Look inside".

### Verified

Real home scan, before and after:

| | rows | nested inside another |
|---|---|---|
| before | 89 | 54 |
| after | **46** | **0** |

Cache rows are now one per app: CloudKit 0.74 GB, Adobe 0.47 GB, Firefox
0.47 GB, and so on. `~/Library/Caches` itself no longer appears as a row.

### Not done, and flagged

The brief also asks for **expand/collapse on rollup rows**. Not built. The app
already ships a drill-in for exactly this — "Look inside" (F10) enumerates a
row's children, and F13 descends into them with a breadcrumb back — so the
capability exists, just not as an inline disclosure triangle on the row. Worth
deciding whether the existing affordance is enough before building a second one.
