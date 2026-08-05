# DiskDrama — Add Apple Intelligence (on-device) as an explanation provider

## Context

F09's explanation layer (Step 8) currently only talks to the Anthropic API. Ludwig wants to test Apple's on-device model — Apple Intelligence is confirmed enabled on this Mac — as a second, free, offline source for the same feature. Partly to test it now; partly because a shipped commercial version of this app will likely need to support multiple providers (Anthropic, OpenAI, Ollama, on-device) so users aren't forced into API costs. This brief scopes just the on-device piece — the fuller multi-provider Settings surface, OpenAI, and Ollama are separate, not-yet-decided pieces of scope. Don't build those here.

## What to build

Add Apple's `FoundationModels` / `SystemLanguageModel` as a second source for `CachedExplanation`, alongside the existing Anthropic path — not replacing it.

## Constraints

- **Deployment target stays macOS 14.** Do not raise the whole app's minimum OS for this. The on-device framework needs macOS 26 (Tahoe) + Apple Silicon, which most users won't have for a while yet. Gate it behind `SystemLanguageModel.default.availability` — same graceful-degradation pattern already built for "no Anthropic key configured": available → offer it; unavailable (device not eligible / Apple Intelligence off / model not ready) → don't offer it, no error, the local rule-based explanation stands alone exactly as it does today.
- **Reuse `CachedExplanation`'s existing four-field shape.** This is a second source for the same structure, not a new format. The `modelIdentifier` provenance field applies here too — an on-device result and a cloud result must not be conflated as the same source.
- **Structure a small seam now.** Since this is genuinely a second provider, not hypothetical, worth having both the Anthropic path and the on-device path conform to one minimal protocol rather than hard-wiring the on-device call directly next to Anthropic-specific code — future providers are a live possibility and re-tearing this up immediately would be wasted work. Keep it proportionate: a small interface, not a full pluggable settings system — that's separate, undecided scope.
- **Match the on-device model's actual strengths.** Per Apple's own framing it's good at short text generation/summarization/classification, weak at broad reasoning or world knowledge — keep the request shape close to what already works for the Anthropic call (structured output into the same four fields), don't assume deep reasoning capability.
- **Same verification bar as everything else.** Build, install, launch, actually exercise it live — an item's explanation panel showing an on-device-sourced result — before calling it done. If Accessibility is still broken from Step 9, report that blocker the same way, don't guess past it.
- **Same reporting cadence as already established.** Only stop and write a report if this surfaces a genuine risk or deviation from the plan. Otherwise commit and move straight on.

## Not in scope here

OpenAI support, Ollama support, a Settings picker between providers, any pricing or commercial-distribution decisions. All explicitly deferred — flag if tempted, don't build.
