# Besties AI subscription — implementation plan

*Drafted 2026-08-30. Status: Phases 1–3 built on branch `ai-prototype` (uncommitted, backend not deployed); Phase 4 not started.*

## Decisions (locked)

- App becomes **free to download** (DMG goes public; the $15 one-time purchase retires).
- The **AI tab is the premium feature**, gated behind a **$10/mo Stripe subscription**.
- Subscribers get **$9/month of AI credit** (breakage model — most won't use it; heaviest users ≈ break-even after OpenRouter's ~5.5% credit fee + Stripe fees).
- **Hard privacy promise**: our servers never see message content. The app talks
  **directly to OpenRouter** using a per-subscriber runtime key minted by our billing
  API with a $9 spend limit. Our infra only knows "this email has an active sub."
- **Visible credit meter** in the app ("$X.XX of $9 left this month"), read straight
  from OpenRouter's key self-inspection endpoint — no server bookkeeping.
- **BYOK** (own `sk-or-…` OpenRouter key) allowed as a subscriber-only perk, same code path.
- **No trial** (re-confirmed 2026-10-08; the prototype's one-free-question gate is deleted) —
  non-subscribers see a paywall with canned example screenshots.
- Sign-in: **email → 6-digit code** (no accounts, no passwords). Code emailed via Resend.
- Existing 2 buyers: comped manually in Stripe (100%-off forever coupon on the sub). No compat code.

## Phase 1 — Backend: 4 Vercel functions next to `site/api/download.js` (~half day)

Storage: Upstash Redis (Vercel Marketplace) for login codes, sessions, OpenRouter key ids.
Email: Resend. New env vars: `UPSTASH_REDIS_REST_URL/TOKEN`, `RESEND_API_KEY`,
`OPENROUTER_PROVISIONING_KEY`, `AUTH_SECRET`, `SEAL_SECRET` (seals stored OpenRouter keys; independent of `AUTH_SECRET`), `STRIPE_WEBHOOK_SECRET`.
Same plain-`fetch`, no-SDK style as `download.js`.

1. `api/auth-request.js` — POST email → Stripe customer lookup, require `active`/`trialing`
   sub → 6-digit code, hashed in Redis, 10-min TTL, rate-limited → send via Resend.
   Always 200 (don't leak who subscribes).
2. `api/auth-verify.js` — POST email+code → HMAC-signed long-lived session token
   (`AUTH_SECRET`) embedding the Stripe customer id.
3. `api/ai-key.js` — Bearer token → re-check sub active → find-or-create the customer's
   OpenRouter runtime key (provisioning API, **$9 limit**) → return it.
4. `api/stripe-webhook.js` — `invoice.paid`: PATCH key limit to `usage + $9` (monthly
   top-up). `customer.subscription.deleted`: PATCH limit to current usage (key dies).
   Signature check in plain crypto.

Verify: curl each endpoint on Stripe test mode + real provisioning key; minted key answers
a completion and dies at its limit.

## Phase 2 — App: port `AIClient.swift` to OpenRouter (~half day)

Confined to `Besties/Besties/Services/AIClient.swift`; `AIToolLoop`'s public API stays
identical so `AIReports.swift` and the chat don't change.

1. Check first whether OpenRouter's Anthropic-compatible `/v1/messages` passthrough is
   live. If yes: endpoint + `Authorization: Bearer` + model slug `anthropic/claude-opus-5`.
2. Else: translate to OpenAI chat-completions — `tools`/`tool_calls` mapping, SSE delta
   shapes, `usage` fields — and keep the moving `cache_control` breakpoint
   (AIClient.swift:203); prompt caching is most of the bill. No extended thinking is
   enabled today, which simplifies the port.

Verify: chat + one Wrapped report end-to-end on a minted key; `AIUsageLog` still populates.

## Phase 3 — App: SubscriptionManager, sign-in, paywall, meter (~1 day)

1. New `Services/SubscriptionManager.swift` — states `noSubscription / needsSignIn /
   active(key)`. Keychain-stores session token + AI key. On launch: refresh key via
   `ai-key.js` (weekly recheck; offline keeps last known state). Meter from OpenRouter
   `GET /v1/key`.
2. Delete the prototype gate enum (AIChatView.swift) and its `defaults` reads. `.ai`
   tab always visible (ContentView.swift:15); `showsAIActions` keys off
   `SubscriptionManager` (ContentView.swift:167).
3. Paywall view in the AI tab: 2–3 canned example Q&As + "Subscribe — $10/mo" (Stripe
   payment link) + "Already subscribed? Sign in."
4. Sign-in sheet: email → 6-digit code.
5. Meter pinned in chat footer, refreshed after each `turnCompleted`. BYOK settings field
   (`sk-or-…`, Keychain) replaces the minted key in the same code path — subscribers only.

Verify: fresh install → paywall → subscribe (test mode) → sign in → ask → meter ticks;
cancel sub → key dies after webhook.

### As built (2026-10-08)

- `Services/SubscriptionManager.swift` (state machine + Keychain + network) and
  `Views/SubscriptionViews.swift` (paywall, sign-in sheet, account popover with BYOK,
  credit meter). Keychain: generic passwords under service `com.besties.app`, accounts
  `aiSessionToken`, `aiRuntimeKey`, `aiOwnKey`. Defaults: `aiAccountEmail`,
  `aiKeyCheckedAt` (weekly recheck clock).
- Recheck rules: active + checked < 7 days ago → no network. Offline / 5xx keep the last
  known state. `ai-key` 401 → full sign-out (token, key, BYOK cleared). 402 → key
  dropped, token kept, so renewing the *same* Stripe subscription (e.g. a paid-up
  past-due invoice) unlocks on the next launch (or the paywall's "Check again") without
  a new code. Resubscribing through the Payment Link can create a **new** Stripe
  customer, and the token is bound to the old customer id, so it stays 402: that path
  is "sign in again with the same email" — the lapsed paywall's "Use a different email"
  signs out and opens the sign-in sheet; `auth-request` then finds the new customer.
  Future work: on 402, `ai-key` could re-look-up an active customer by the token's
  email server-side so no re-sign-in is needed.
- Meter = OpenRouter `GET https://openrouter.ai/api/v1/key` → `data.limit_remaining`
  (USD; null = no limit) over a constant $9 — not `data.limit`, which the webhook grows
  by $9 every invoice. Seeded for free from `ai-key`'s `limit - usage`; a 401 from it
  (key deleted upstream) re-mints through `ai-key`. Hidden for BYOK (it isn't the
  subscription's credit) and for the dev key.
- `auth-request` always answers 200, so the app can't say "no subscription" at the
  email step; the code step says "if that email has a subscription", and "No active
  subscription for that email" only appears when `ai-key` answers 402 after a valid code.
- `SUBSCRIBE_URL` (`SubscriptionManager.subscribeURL`) is a placeholder pointing at
  https://besties.gg until the Stripe subscription payment link exists (Phase 4).
- The semantic index (`AIVectorIndex`, ~1 h of background embedding) is created only
  when AI was unlocked at launch; subscribing mid-session gets it from the next launch.
- **DEV CARVE-OUT — remove at ship:** a non-empty `anthropicKey` default makes the
  state `active(thatKey)` with no meter, no BYOK and no network, so the prototype
  workflow keeps working until the backend is deployed. Delete `Default.devKey`, the
  `isDevKey` branches in `SubscriptionManager`, and the dev note in `AIAccountPopover`
  before Phase 4 ships.

## Phase 4 — Site + rollout (~half day)

1. `site/src/landing.html`: free "Download for Mac" (direct DMG link, gate removed);
   pricing section: app free, **Besties AI $10/mo**; new Stripe subscription payment
   link; thanks-page copy → "open the app and sign in with this email."
   (Apply the `scannable-design` skill.)
2. Retire the $15 payment link; `download.js` stays for old emailed links.
3. Comp the 2 existing buyers (Stripe coupon, manual subs).
4. Ship via the full `release.sh` flow in CLAUDE.md.

## Order & effort

Phase 1 → 2 → 3 → 4; each independently testable. Total ≈ 2.5 days. Biggest unknown:
Phase 2 format port — resolve in the first hour by checking OpenRouter's current API.

Needed from Jordan at build time: OpenRouter provisioning key, Upstash + Resend signups,
new Stripe subscription product + payment link.
