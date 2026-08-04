# Step 15 — a traversal floor that silently capped the classifier

**Status:** found, fixed, verified. Commit `7f21b53`.
**Why you're getting a report:** this is a correctness defect in the scan/
classification engine that was declared verified at Step 5 and has been shipping
in every step since. It produced no error, no warning, and no visible symptom —
only fewer recommendations than the rules should have produced.

## What was wrong

`RecommendationBuilder.visit` descended into a child only if the child cleared
`unknownItemFloorBytes / 10` — 100 MB.

That constant exists for Tier 3: unmatched folders below 1 GB are not offered for
review, so Tier 3 doesn't fill with noise. Reusing a tenth of it as the *descend*
floor coupled two unrelated decisions, and the coupling was wrong in one
direction:

- Rule minimums go down to **20 MB** (`__pycache__`), with several at 50 MB
  (`node_modules`, `.build`, DerivedData).
- A parent directory is always at least as large as its child.
- So a folder matching a 50 MB rule but living under a parent below 100 MB was
  never reached. The rule could not fire, because traversal stopped above it.

Net effect: **every rule with a minimum below 100 MB was partly unreachable.**
The smaller the rule's threshold, the larger the unreachable band. A 94 MB
`node_modules` inside a 94 MB project was invisible.

This does not affect the common case — a 4 GB `node_modules` sits inside a
project well over 100 MB — which is why it survived Step 5's verification and
every scan since. It bites exactly the users with many small-to-mid projects.

## How it surfaced

Not by inspection. I built a disposable test tree to exercise F15's partial-batch
path and it returned **zero** recommendations where it should have returned
three. My first assumption was that my test sizes were under the rule minimums;
they weren't — 70/90/60 MB against 50 MB rules. Following why nothing matched led
to the descend floor.

Worth noting for the pattern: the bug was found by a test built for something
else entirely, and only because I checked ground truth (`du`) against what the
app claimed rather than assuming my fixture was wrong.

## The fix

```swift
static var descendFloorBytes: Int64 {
    min(unknownItemFloorBytes / 10, KnowledgeBase.smallestRuleMinimumBytes)
}
```

with `smallestRuleMinimumBytes` derived from the rule table itself
(`rules.map(\.minimumSizeBytes).min()`), not hardcoded. Adding a rule with a
lower minimum can therefore never silently become unreachable again — which is
the actual failure mode, since the original constant was correct on the day it
was written and only became wrong when rules with lower floors were added.

**Before:** test tree → "Nothing safe to clean up."
**After:** same tree → 231 MB across three items.

## What this doesn't fix

`DD.U001` still stands (largest-non-recommendable is one level too coarse). And
the Tier 3 floor of 1 GB is untouched and unexamined — it's a product judgement,
not a bug, but nobody has checked it against a real disk.

## Also in this step

- **F15 partial-batch reporting** was thin to the point of being misleading: a
  per-item failure set `deletionError`, then the sheet closed on top of it. The
  user saw a job that appeared to complete, with leftovers discoverable only by
  noticing the total hadn't moved. The sheet now stays open, names what survived
  and its containing folder, and the rows still listed are the ones that remain.
  Verified against a `chmod 555` parent: partial (2 of 3), total failure, and
  clean-run-closes.
- File counts pluralise ("1 file", not "1 files").
- Settings no longer leaks internal spec IDs (A03, F18, F19, A04) into
  user-facing copy.

## Verification note

The accessibility tree remains the harness (screen capture unavailable). One
thing to know if you use it: SwiftUI exposes `accessibilityLabel` as
**AXAttributedDescription**, and System Events cannot marshal an attributed
string over AppleEvents — it errors with `-10000`. Buttons therefore read as
unlabelled through `osascript` even when they are correctly labelled. I spent
time treating that as an app regression before confirming it's a harness limit.
Anything checking button labels this way needs to know that, or it will keep
"finding" the same non-bug.
