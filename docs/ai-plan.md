# Besties AI — Prototype Plan

Goal: prove (or kill) the AI tier before touching pricing, the site, or any
infrastructure. A chat interface over the full message history, powered by
tools that run locally — the model never sees the archive, only what a tool
returns for the current question. Everything ships on branch `ai-prototype`,
gated behind a defaults flag, using Jordan's own API key. No proxy, no Stripe,
no site changes, no release.

Decision this prototype answers: **are the answers good enough that people
would pay monthly for them?** Instrumentation (below) also yields the real
cost-per-question numbers the pricing model needs.

## Ground rules

- Branch `ai-prototype`, never merged to main until go/no-go. The repo is
  public and the site says "zero network calls" — AI code must not appear on
  main before the copy is rewritten.
- Gate: `defaults write com.besties.app aiPrototype -bool true` + relaunch
  (same pattern as `screenshotMode`, but a plain runtime check — no
  `#if DEBUG`, since local runs are always Release builds for FDA).
- API key: `defaults write com.besties.app anthropicKey sk-ant-…`. Plaintext
  defaults is acceptable for a single-machine prototype; Keychain is a ship
  requirement, not a prototype one.
- Model: `claude-opus-5` for the whole prototype. We are measuring the quality
  *ceiling* — if the best model isn't worth paying for, cheaper ones aren't
  either. Cost-optimization (Haiku routing) is a post-decision task.
- API: raw HTTPS via URLSession (no official Swift SDK). `POST
  https://api.anthropic.com/v1/messages`, headers `x-api-key`,
  `anthropic-version: 2023-06-01`. Always streaming (SSE) — answers and
  reports are long. Omit the `thinking` param (Opus 5 defaults to adaptive
  thinking). `max_tokens` 16000 for chat, 64000 for Phase-3 reports.
- Handle every `stop_reason`: `tool_use` (loop), `end_turn`, `max_tokens`
  (surface truncation), `refusal` (read `stop_details`, show a plain
  "couldn't answer that" state — likely on heavy personal content).
- Prompt caching: request order is tools → system → messages; put a
  `cache_control: {type: "ephemeral"}` breakpoint after the (frozen) system
  prompt, and keep anything volatile (today's date is fine — it changes daily,
  not per-request) at the top of the *user* turn, not in system.

## Phase 1 — Ask Anything (the go/no-go phase)

New files under `Besties/Besties/`:

1. `Services/AIClient.swift` — SSE streaming client + the tool loop.
   `while stop_reason == "tool_use"`: execute all tool_use blocks (they can
   arrive in parallel — return every tool_result in a *single* user message),
   append, continue. Emits events: text delta, tool started/finished (name +
   human summary), usage (input/output/cache-read tokens), error.
2. `Services/AITools.swift` — tool definitions (JSON Schema) + dispatch. Five
   tools, all wrapping code that exists:
   - `list_people(filter?, sort: messages|recent, limit=25)` → from
     `AppState.resolvedConversations`: name, mergeKey, sources, sent/received
     totals, first/last message dates, daysSinceLastMessage.
   - `person_summary(person)` → `Conversation` fields + `RelationshipPeaks`
     (busiest day/month/year, `Models/ChatMessage.swift:39`) + per-month
     message counts for the whole relationship (one GROUP BY query).
   - `search_messages(query, person?, sender: any|me|them, after?, before?,
     limit=20)` → `SearchIndex.search` with existing options; returns date,
     sender, snippet, message id, source.
   - `read_transcript(person, center_date? | after?/before?, limit=40)` →
     windowed fetch via `MessageStore` (reader already pages this way);
     returns [{date, from_me, text}]. Cap 120 messages per call.
   - `run_sql(db: chatdb|searchdb, query, row_limit=200)` — the prototype
     power tool: read-only SQL. Guardrails: `SQLITE_OPEN_READONLY`, single
     statement, must start with SELECT/WITH, `sqlite3_busy_timeout`, hard row
     cap, 5 s interrupt. The system prompt carries a schema cheatsheet
     (message.date = ns since 2001-01-01, the 1:1-chat rules, `item_type = 0
     AND associated_message_type = 0`, WhatsApp id offset `1<<40`).
   - Person args resolve through the same normalization as `mergeKey`
     (name → digits → handle); ambiguous names return the candidate list as
     the tool result so the model can ask.
3. `Services/AIPrompt.swift` — system prompt: what Besties is, today's date
   injected per-turn (user side, not system — keeps the cache prefix stable),
   schema cheatsheet, tool-choice guidance (stats questions → SQL, never
   guess numbers; recall questions → search then read_transcript), and care
   rules: warm, non-judgmental, insights are about *your* habits — never
   verdicts on other people, never "X is a bad friend".
4. `Views/AIChatView.swift` + an **AI** tab in the `Tab` enum
   (`Views/ContentView.swift`) — visible only when `aiPrototype` is set.
   Message list (user right / assistant left, existing bubble styling),
   streaming text, collapsed tool-activity rows ("🔎 searched "ramen" — 12
   hits"), per-answer footer with token count + computed cost, retry on
   error. Conversation is in-memory only; "New chat" clears it.
5. `Services/AIUsageLog.swift` — append one JSON line per API call to
   `~/Library/Application Support/Besties/ai-usage.jsonl`: timestamp, turn id,
   model, input/output/cache-read tokens, latency ms, tool calls made,
   stop_reason. This file is the pricing evidence.

Verify: app builds Release; with the flag off the tab is absent and the app
makes zero non-Sparkle network calls (Little Snitch); with it on, each tool
answers correctly against the real chat.db (spot-check tool outputs vs. the
Search tab / All Time numbers, which are already trusted).

## Phase 2 — Total Recall (semantic search)

Only starts if Phase 1's recall questions are the weak spot (expected: FTS
misses paraphrases — "that ramen place" vs. the actual words used).

1. On-device embeddings — no text leaves the Mac to build the index.
   Candidate A: `NLContextualEmbedding` (built into macOS, zero deps).
   Candidate B: a small sentence-embedding model via MLX. Decide with a
   50-query bake-off over indexed real data; A wins ties (no dependency).
2. Chunking: single texts are too short to embed well. Chunk = up to 10
   consecutive messages from one conversation within a 3-hour window, stored
   as (chunk_id, source, chat_id, first/last msg id, date). Est. ~150–250k
   chunks for 1.15M messages.
3. Storage: `vec.sqlite` sidecar next to `search.sqlite`, using `sqlite-vec`
   (`vec0` virtual table). Incremental cursor sync mirroring
   `SearchIndex.swift` (schema_version, batch transactions, resumable).
   Budget per search-plan.md's ~4× estimate: ~500 MB. First build is a
   background job with progress in Settings; measure wall-clock on the real
   1.15M — if it exceeds ~30 min, ship Phase 2 gated on an opt-in toggle.
4. New tool `semantic_search(query, person?, after?, before?, limit=15)`:
   embed the query, ANN top-k from vec0, fuse with a parallel FTS bm25 query
   (reciprocal-rank fusion), return snippets + ids. `search_messages` stays —
   the model picks exact-match vs. meaning-match per question.

Verify: a fixed 20-question recall set (below) where the FTS-only Phase 1
build failed; Phase 2 must convert ≥ half of the misses.

## Phase 3 — Packaged moments

The subscription pitch in shareable form. All three are prompt templates over
the Phase 1/2 plumbing (same tool loop, `max_tokens` 64000), returning
structured JSON sections rendered as native SwiftUI cards — not raw prose.

1. **Wrapped(year | all-time)** — totals, top people with arcs, busiest day
   with what happened, phrase-of-the-year, one "you in a sentence". Rendered
   as cards; screenshot mode already masks names for sharing.
2. **Friendship Biography(person)** — how it started (real first messages via
   `read_transcript`), the arc by era, busiest stretch, inside phrases
   (SQL n-gram counts scoped to the pair), longest silence + who broke it.
3. **Reconnect draft(person)** — reads the last real exchange + a style
   sample of the user's own messages to that person; drafts 2 openers in the
   user's voice referencing what they last talked about. Buttons: copy /
   open in Messages (reuse the existing `imessage://` plumbing on
   `LeaderboardRow`).

Verify: generate all three for 5 real relationships; grade tone against the
care rules (nothing gossipy, nothing that scores the other person).

## Eval + decision gates

`docs/ai-eval.md` (written with Phase 1): ~20 fixed questions across four
buckets — stats ("who do I ghost most"), recall ("what restaurant did X
recommend"), arcs ("how did Y and I get close"), habits ("am I texting less
than 2023"). Grade each answer 1–5 for correctness and for "would screenshot
this". Gates:

- After Phase 1: stats+arcs ≥ 4 avg, cost/question and p50 latency from
  ai-usage.jsonl look survivable at ~$9/mo → continue; else stop, total cost
  of experiment ≈ a few dollars of API spend.
- After Phase 2: recall bucket ≥ 4 avg.
- After Phase 3: 3 of 5 reports rated "would actually send/share".

## Build execution (workflow-ready)

Each numbered item above is a self-contained task: named target files, wraps
an existing service, and has a stated verify step. Suggested fan-out for a
workflow run on the `ai-prototype` branch:

- Phase 1: task A = AIClient + AIPrompt (pure networking, testable with a
  stub key); task B = AITools + person resolution (testable headlessly
  against the real chat.db/search.sqlite — no app launch needed); task C =
  AIChatView + tab + usage log (depends on A+B's interfaces, agreed up
  front). A and B run in parallel; C follows; then one Release build +
  manual eval pass.
- Phases 2–3 fan out the same way (index builder ∥ tool ∥ UI), but don't
  start until the prior gate passes — the gates are the point.
- Verification agents can query chat.db and search.sqlite directly (this
  machine's terminal has FDA) to diff tool outputs against ground-truth SQL.

## Explicitly out of scope for the prototype

Pricing/tiers, the Vercel proxy, Stripe, credits, site copy, Keychain,
multi-model routing, group chats (excluded app-wide), attachments/OCR, and
any release — release.sh, the DMG, and appcast are untouched by this branch.
