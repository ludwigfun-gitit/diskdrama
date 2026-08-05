# Step 16 — Apple's on-device model, and what it turned out not to be safe for

**Status:** built, verified live, committed (`8d94660`). Working.
**Why you're getting a report:** the brief said reuse `CachedExplanation`'s
four-field shape. The on-device provider now generates **one** of those fields
and passes the other three through from the rule table. That is a deviation from
the obvious reading of the brief, it was forced by a genuine safety finding, and
it's the sort of thing that should inform the wider multi-provider decision
rather than sit in a commit message.

## The finding

Written the obvious way — rewrite all four fields — the on-device model inverted
the meaning of its own source material.

Given the rule table's text for `node_modules`:

> Reconstructable in full from that project's package.json and lockfile.

it produced, in the **consequence of deleting** field:

> Deleting this folder will cause the webapp project to need to be rebuilt from
> scratch, as the project's package.json and lockfile will be lost.

That is false. `package.json` and the lockfile live *outside* `node_modules` and
survive its deletion. The model took "the thing it can be rebuilt **from**" and
re-bound it as "the thing that gets **lost**" — and put that sentence directly
above a delete button, in the field whose entire job is telling someone what
they're about to lose.

It is worth being precise about why this is the bad case rather than a typo:
it is fluent, it is specific, it names real files, and it is exactly wrong. A
user who trusts it either abandons a safe cleanup or misunderstands what is at
stake. This app's whole proposition is being trustworthy about deletion.

### It got worse before it got better

Adding an explicit rule — *only things inside this folder can be lost; source
files and lockfiles live elsewhere and are untouched* — did fix the inversion.
Two of the next three generations then contained this, verbatim, as user-facing
prose:

> Source code, configuration files and lockfiles live elsewhere in the project
> and are untouched by deleting it.

One generation led with it. Stating a constraint using concrete nouns makes a
small model echo the constraint. Removing the rule brought the inversion back.

That bind is the actual result: **prompt engineering was not converging on a
consequence field I would put my name to.**

## What I did instead

The model no longer writes the fields that carry stakes.

| Field | Source |
|---|---|
| `whatThisIs` | generated on-device |
| `consequenceOfDeleting` | rule table, verbatim |
| `rebuildCost` | rule table, verbatim |
| `confidence` | rule table, passed through |

The rule table's consequence text is accurate and human-written. Passing it
through eliminates the entire failure class rather than trying to instruct a
small model out of it, and it leaves the model doing the one job it is
genuinely good at: making a generic description specific to this folder.

`confidence` is passed through for a related reason. It reports how sure the
*identification* is, and the identification came from the rule table. Asking a
small model to introspect its own calibration would produce a number with
nothing behind it — worse than no number.

Result after narrowing, round 6 of 7:

> Third-party JavaScript packages installed for **the webapp project**.
> Reconstructable in full from the project's package.json and lockfile.

Correct, specific, names the owning project, and cannot invert anything because
it was never asked to reason about consequences.

## Two smaller findings, same shape

- **It fabricated counts.** Sent "Files inside: 41" it wrote "41 third-party
  JavaScript packages". Labelling the unit inline ("a count of files, not of
  packages or projects") did not stop it. The file count is now withheld from
  this provider — least decision-relevant measurement, only one reliably
  producing a false statement. The cloud provider still gets it.
- **It copied my example.** A `@Guide` description reading *"as a fragment like
  'about a minute of rebuilding'"* produced the output "About a minute of
  rebuilding" for a source that said "seconds to a few minutes". Examples
  containing a value get treated as the value. Guides now carry no example
  fragments.

Both are the same failure as the inversion: it reproduces the *shape* of what
it is shown, including the parts that were only ever meant as instruction.

## Honest assessment of what on-device buys us

Modest. For well-known folder types the rule table is already good, and the
narrowed model output is often close to the generic text with the project name
added. The wins are real but small; the cost is ~5-8 seconds per explanation
(vs ~7.7s for Claude, so no speed advantage — the advantage is free, offline
and private).

Where it should pay off better is unfamiliar folders — which is also where I
have not tested it, because it cannot identify those by design. Worth knowing
before this shapes any commercial multi-provider plan: **the on-device model is
a text-shaper here, not a second opinion.** Claude is the second opinion. They
are not substitutes, and a Settings picker that presents them as equivalent
choices would be misleading.

## Verification

- Live, in the running app: panel showing `· looked closer · Apple Intelligence,
  on this Mac`, `provider=apple.systemLanguageModel`, across seven generations
  with fresh fingerprints each time.
- Anthropic path re-verified *through the new seam* by temporarily forcing the
  on-device factory to nil: `provider=claude-opus-5 seconds=7.7 confidence=0.93`.
  Not replaced, still works.
- macOS 14 constraint verified structurally rather than assumed:
  `otool -l` reports `LC_LOAD_WEAK_DYLIB` for FoundationModels with `minos 14.0`.
  I could not test on an actual Sonoma machine — the weak link and the
  `@available` gating are the evidence, not a live run.

Accessibility was working; the Step 9 outage did not recur.

## Not built, as instructed

OpenAI, Ollama, a Settings picker, any pricing decision. The seam is a protocol
and a factory — deliberately not a registry.
