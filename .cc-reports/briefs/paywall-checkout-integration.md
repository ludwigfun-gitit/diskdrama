# DiskDrama paywall — checkout + licence integration contract

Written 2026-08-11 by the CC session working in `bloosoftware-fulfillment`.
This is the backend contract your paywall must integrate against. It is **not** a spec for
the paywall UI or the entitlement model — those are yours / the blueprint's.

---

## 1. What the backend already provides

Bloosoftware apps sell through a shared Netlify Functions backend
(`~/Projects/bloosoftware-fulfillment`). It handles checkout, licence-key issuance, email
delivery, activation and daily re-validation. **Nothing about payments is implemented
per-app.** Visuals and Turfs are both live on it; copy them rather than inventing anything.

Reference: `Atlas/Bloosoftware/payment-infrastructure.md` and
`Atlas/Bloosoftware/license-validation-infrastructure.md` in the vault.

### ⚠️ Do not copy Keepers

`keepers-native` bills through **Apple StoreKit** (`com.bloo.keepers.unlimited.monthly` /
`.yearly`, auto-renewable subscriptions in App Store Connect). It contains no checkout URL
and no licence-key activation — it is not a consumer of this backend at all.

DiskDrama is **direct distribution only** (per its own `CLAUDE.md`: Full Disk Access is
incompatible with the App Sandbox, so it isn't App Store eligible as spec'd). That means
Stripe, not StoreKit. **Copy Visuals or Turfs. Reading Keepers' paywall for precedent will
send you down the wrong path entirely.**

## 2. The buy button — the entire app-side purchase integration

One constant, one `NSWorkspace.shared.open`. That is all.

```swift
// Match Visuals/Core/AppConstants.swift:5 and
// Turfs/Services/Entitlement/EntitlementService.swift:108
static let purchaseURL = URL(string:
    "https://bloosoftware-fulfillment.netlify.app/.netlify/functions/checkout?price=diskdrama_lifetime")!
```

Substitute `diskdrama_monthly` / `diskdrama_yearly` if DiskDrama ends up subscription-based.
Ludwig decides that; ask him rather than assuming.

### The one rule that matters

**`diskdrama_lifetime` is a Stripe `lookup_key`. The app must never contain a Stripe price
ID, a price ID's amount, or the price itself.**

Stripe Prices are immutable — changing a price creates a *new* Price object with a new ID.
The lookup_key is a stable nickname that gets transferred onto the new Price, so the app
keeps working across every future price change with no rebuild. Hardcoding a price ID (or
displaying a hardcoded amount) reintroduces exactly the problem the 2026-08 rework removed.

If the paywall must show a price on screen, **do not hardcode it** — raise it with Ludwig.
A read-only pricing endpoint is the correct answer and does not exist yet; inventing a
hardcoded string in the app is not.

## 3. ✅ The backend is live — updated 2026-08-11

DiskDrama Pro is a **one-time purchase**. `diskdrama_lifetime` is assigned in Stripe,
`prod_V492Aj5YAPKMr1` is wired into fulfillment and re-download, and the URL above is
verified returning `303` to a live Stripe Checkout session. Use it as written.

### ⚠️ But do not ship a working buy button yet

`diskdrama-releases` **does not exist**, so the download link in the purchase email 404s.
A real purchase today would take the customer's money and email them a dead link — the
exact failure that hit Visuals and Keepers for months.

Before any buy button is reachable by a customer, Ludwig must create a public
`diskdrama-releases` repo with a release marked Latest carrying `DiskDrama.dmg`. Building
and testing the paywall is fine; **exposing it in a shipped build is not.** If you reach a
point where the paywall is shippable, say so and stop rather than assuming this is done.

## 4. Licence activation contract

After purchase the customer gets an emailed licence key. The app activates it against
these two endpoints. Both are `POST`, both take JSON, both expect an **`app` field** which
selects the per-app storage — send `"diskdrama"`.

Base: `https://bloosoftware-fulfillment.netlify.app/.netlify/functions/`

### `activate-license` — two-step, OTP-confirmed

```
Step 1:  POST { app: "diskdrama", email, key }
         → 200 { status: "code_sent" }        // 6-digit code emailed, 15-min TTL
Step 2:  POST { app: "diskdrama", email, key, code }
         → 200 { valid: true, tier: "pro", interval: "perpetual" }
```

### `validate-license` — silent re-check on launch and once daily

```
POST { app: "diskdrama", email, key }
  → 200 { valid: true,  tier: "pro", interval: "monthly"|"yearly"|"perpetual" }
  → 200 { valid: false, tier: "free", reason: "<why>" }
```

### Two things that will bite you if you miss them

**Application failures return HTTP 200 with a reason, not 4xx.** Reasons: `invalid_request`,
`invalid_key`, `subscription_inactive`, `email_mismatch`, `expired`, `invalid_code`,
`server_error`. 4xx/5xx mean transport or config problems only. Treating a non-200 as
"licence invalid" will lock out paying users whenever the network hiccups.

**`interval` drives the offline grace window**, and the client is responsible for honouring
it: `monthly` → 30 days, `yearly` → 365 days, `perpetual` → indefinite. Cache the last good
validation and keep the app unlocked for that window when offline. Do not gate launch on a
successful network call.

## 5. Releases and the download link

The purchase email contains a download link. It is served from a public GitHub releases
repo — the standard for all Bloosoftware apps as of 2026-08-11 (R2 was retired from the
download path after two apps silently served dead links for months).

So DiskDrama needs a public `diskdrama-releases` repo with the DMG attached to a release
marked Latest, giving:
`https://github.com/ludwigfun-gitit/diskdrama-releases/releases/latest/download/DiskDrama.dmg`

`/latest/download/` follows each new release automatically — no per-release step in the
fulfillment repo, ever. Flag to Ludwig if the repo doesn't exist yet; creating it is his call.

## 6. Explicitly not your job

- Editing anything in `bloosoftware-fulfillment` (`ALLOWED_LOOKUP_KEYS`, `PRODUCT_MAP`,
  `BINARY_MAP`) — handled in the other session.
- Creating the Stripe product, price or lookup_key — Ludwig, in the Dashboard.
- Website buy buttons.

Your scope is the DiskDrama app: paywall UI, entitlement state, the purchase URL, and the
activation/validation client.
