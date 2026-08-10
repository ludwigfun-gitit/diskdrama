# DiskDrama — URGENT: slow-directory finding is offering whole user folders as one-click "safe to delete"

## Severity
Treat as blocking, ahead of whatever else is in flight. A real scan of a real
home directory just produced `~/Library` (156.4 GB), `~/Pictures` (45.4 GB),
and `~/Documents` (212 MB) all showing as "Safe to delete" with a one-click
delete button, in the tier whose own UI copy says "nothing here is something
you made." That's wrong in the most dangerous possible direction.

## Root cause (confirmed by reading the code, not guessed)
`KnowledgeBase.slowDirectoryFinding(path:name:seconds:)` is the finding for
"this directory took a long time to enumerate" — reasonable to want to
surface, per its own doc comment (the Index.noindex case: millions of
entries, unremarkable in Finder because Finder reports bytes, not entry
count). But it's wired with `tier: .safe`, and `RecommendationBuilder.visit`
checks `slowByPath[node.path]` *before* real classification and *before*
descending into the folder, returning immediately when it hits. So the very
first large, slow-to-list folder encountered at any level — for most home
directories, that's `~/Library` itself — gets a blanket Tier-1-safe
recommendation and the walk never looks inside to find what's actually
there.

This directly violates the rule stated at the top of `KnowledgeBase.swift`:
"everything unmatched is Tier 3, a gap should produce an over-careful
recommendation, never a dangerous one." The existing `unknown()` fallback
right next to it gets this right — `tier: .reviewFirst`, confidence 0, "look
inside before deciding." `slowDirectoryFinding` should have followed the
same pattern and didn't.

The self-contradiction visible in the screenshot is the tell: the
description text hedges ("check what it belongs to before removing it")
while the tier badge and Delete button assert certainty. Two parts of the
same finding disagreeing, because the prose was written cautiously and the
tier wasn't.

## What to fix

1. **`slowDirectoryFinding` must not use `tier: .safe`.** At most
   `.reviewFirst`, matching `unknown()`'s posture — arguably this finding
   shouldn't sit in an actionable delete tier at all, since nothing about it
   confirms the contents are disposable. Your call on `.reviewFirst` vs. a
   separate non-actionable "observation" surfaced outside the three
   deletion tiers entirely — either is fine as long as `.safe` is gone.

2. **Stop short-circuiting before classification and descent.** Today the
   `slowByPath` check runs first and returns immediately. It should run
   *after* real classification is tried (`KnowledgeBase.classify`) and after
   descending into children the normal way — so a slow folder that actually
   contains recognizable things (real DerivedData, real caches) still finds
   and recommends those specifically, the way it would if it happened to be
   fast to list. Only fall back to the generic "huge entry count" finding
   for what's left over unclassified after descent — the same shape as the
   existing `unknown()` fallback, and it's reasonable for the two to share
   that fallback slot (prefer the more informative "this was slow to list"
   explanation over the plain "I don't know what this is" one when both
   apply to the same leftover node).

3. Check whether anything currently persisted (prior snapshots, cached
   recommendations) needs the fix to actually take effect, or whether the
   next scan naturally recomputes and self-corrects — don't assume, verify.

## Verification — this time, actually look at it
Step 17's report already explains why this slipped through: the
Accessibility outage blocked UI-driven verification, so Part C got verified
through code paths instead of eyes-on-the-real-app. That gap is exactly how
a bug like this — visually obvious the moment a human looks at the screen,
invisible to a code-path check — survived multiple committed steps. For
this fix specifically: run a real scan of the real home directory and
actually look at the resulting tier list. `~/Library`, `~/Pictures`, and
`~/Documents` must not appear as blanket Safe-to-delete items. Confirm
whatever real build-cache/index folders are actually inside `~/Library`
still get found and correctly classified on their own merits. If
Accessibility is down again when you get to this, say so plainly rather
than substituting a code-path check for this one — this fix's entire point
is a UI-visible failure mode.

## Not in scope
The parallel-scan-engine brief, anything else currently in flight. This is
its own fix, independent of that work.
