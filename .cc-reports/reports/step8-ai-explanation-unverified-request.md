# Step 8 — AI explanation layer: the request itself is unverified

**Date:** 2026-08-04
**Commit:** `009e8e5`
**Flows:** F09 (deeper prose), A02, A05
**Status:** built, installed, exercised — **except the one thing that matters most.**

Reporting this under the new cadence because it is a genuine risk, not routine
progress: **the live API request has never been executed.**

---

## What could not be verified, and why

There is no Anthropic API key available in this environment — `ANTHROPIC_API_KEY`
is unset and the `ant` CLI is not installed. And I do not enter API keys into
credential fields on your behalf, so I could not configure one in the app either.

The consequence is specific: everything *around* the call is verified, and the
call itself is not. The request body was assembled from the current API
reference, and it combines several things at once:

| Element | Why it's in the request |
|---|---|
| `output_config.format` — json_schema | The four fields land in `CachedExplanation` with no prose parsing |
| `output_config.effort: "low"` | Short explanations; the cheap end of the ladder |
| `thinking: {type: "adaptive"}` | Preferred over disabling — disabled thinking on this model can leak `<thinking>` tags into output |
| `cache_control` on the system block | Same system prompt every request |
| `fallbacks: "default"` + beta header | A policy decline gets re-served instead of dead-ending |

Each is individually documented. **I have not confirmed they are accepted
together**, and a rejected combination returns a 400 — which means the feature
would fail on its first real use rather than at build time.

## What I did about it

A 400 retries once with the optional `fallbacks` parameter and its beta header
dropped. Everything load-bearing — model, schema, prompts, caching — is
identical on both attempts.

That is deliberately narrow, and it is not general defensive padding: the
fallback parameter is the one part of this request gated on a **dated beta
flag**, so it is the part that can go stale independently of anything the
feature actually needs. It buys a graceful degradation for the failure mode I
can specifically anticipate. It does **not** cover a malformed schema or a bad
`output_config` — those would fail both attempts, and the panel would show
"couldn't look closer" with the local explanation still standing.

## How to verify in about a minute

1. Open DiskDrama → **Settings** in the sidebar → paste an API key → Save.
2. Select any item in a tier. The metadata line should go
   `· looking closer…` → `· looked closer` (cyan), and the two explanation
   columns should fill with richer text.
3. Confirm the call and the cache:

```bash
log show --predicate 'subsystem == "com.bloo.diskdrama"' --last 5m --style compact | grep explanation
```

A successful line reads
`explanation — in=… out=… cacheWrite=… cacheRead=… model=claude-opus-5`.

**Two things to look at in that line.** If `cacheRead` stays `0` across several
different items, the system prompt is below the model's 512-token minimum and is
silently not caching — it would work, just cost full price every time. And if a
`retrying without the fallbacks parameter` line appears first, the combination
above was rejected and the retry saved it; the 400 body is logged with it.

Selecting a second item, then returning to the first, should produce **no** new
log line — that is the fingerprint cache doing its job.

## Design notes worth keeping

**Structured output, not prose.** `CachedExplanation` already stored exactly
four fields mirroring a local `Classification`. So an AI explanation is a richer
version of the same thing rather than a second format, and the panel needed no
special-casing — the columns read from whichever source is available.

**The panel says where its prose came from.** "A rule table matched a path" and
"a model looked at this" are different claims, and the user is being asked to
delete files on the strength of them. Quietly swapping in richer text and
letting it read as the same source was the alternative, and it was the
dishonest one.

**Confidence comes from the model when it has an opinion.** It looked at the
item; the rule table only matched a path. Where they disagree the better-informed
number wins.

**A cached explanation from a different model is ignored, not shown.**
`CachedExplanation.modelIdentifier` exists to record provenance; presenting an
older model's prose as this one's would make that field a lie.

## Two things I want on the record

**The Settings sheet is a Step 8 addition, not a Step 10 preview.** The sidebar's
Settings row now opens a minimal API-key sheet. Without it the feature is
unreachable and unverifiable. Step 10 should absorb it as one section of the
real Settings surface rather than treat it as done.

**Explanations are generated on first view, per A05 — which means selecting a
row spends money.** That is the resolved behaviour and I implemented it as
written, but it is worth being deliberate about: browsing ten items in a tier is
ten API calls the first time through, and free every time after. If that reads
wrong once you've used it, the alternative is an explicit "look closer" button,
which is a small change to `ExplanationPanel`.

## Verified without the key

- Builds clean under Swift 6, zero warnings; installs, launches, window opens.
- With no key configured the feature is **not offered** — no marker, no button,
  no failed request. The local explanation stands on its own.
- Settings row → sheet renders: description, secure field, Keychain/privacy
  note, Save disabled while empty, no "Remove key" until one exists.
- Nothing about the user's disk is sent anywhere at rest — the request carries
  one folder's name, size, file count, and age, and only for the selected item.

## Next

Step 9 — deletion service, confirm sheets, batch, undo (F14–F16). The brief's one
hard rule applies there: built and exercised only against disposable trees under
`/tmp`, never real files, until you verify it yourself.
