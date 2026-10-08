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

Built as `Services/AIVectorIndex.swift` + the `semantic_search` tool in
`AITools.swift`. What shipped, and where it deviates from the sketch above:

1. On-device embeddings — no text leaves the Mac to build the index.
   **Shipped: `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dims.** It
   beat `NLContextualEmbedding` in the spike on the only axis that mattered
   here (it needs no one-time Apple asset download, and its recall was not
   worse), and MLX was never worth a dependency. Measured 91.5 embeddings/s
   sustained across 8 workers on an M3 Pro → **~54 min for a first full build**
   of the real 1.1M-message archive. Incremental syncs after that are seconds.
2. Chunking: consecutive messages of one conversation within a 3-hour window,
   stored as (id = first msg id, source, chat_id, last_msg_id, date, vec).
   Two deviations from the sketch, both forced by measurement:
   - **5 messages per chunk, not 10.** `NLEmbedding` pools word vectors, so a
     longer chunk averages away any single topic in it. Query = a known
     message's own text, scored against every chunk of its conversation, over
     four real conversations: its chunk is in the top ten **56% of the time at
     10 messages, 79% at 5, 90% at 3**. Three would cost 429k chunks / ~78 min
     / 878 MB resident, which is past what can be kicked off unprompted; five
     costs 299,158 chunks / ~54 min / 613 MB against ten's 206k / ~38 min /
     423 MB.
   - **The 3-hour window is symmetric.** `msgs.id` is arrival order, not date
     order: 139,019 messages (12.7%) are older than the previous message in
     the same chat, 39,046 of them by more than 3 hours. A forward-only gap
     check let those into the open chunk, so 17% of chunks contained a >3h
     jump backwards and 6.7% were dated more than a day away from their own
     contents (worst case: three messages spanning 2020→2024). Comparing the
     absolute gap costs +20% chunks and caps the longest chunk at ten hours
     instead of 1,307 days. A chunk's stored `date` is its **earliest**
     message, not its first by id.
   A chunk also closes at the 10k-message batch boundary, which is what makes
   the resume cursor honest (an interrupted build resumes at the same boundary
   and produces the same chunks); at 10 messages that cost +0.7% chunks. The
   embedded text is the raw messages joined by spaces — "Me:"/"Them:" prefixes
   measured 21% slower to embed with no recall gain, so they live only in what
   the tool hands back.
3. Storage: `vec.sqlite` sidecar next to `search.sqlite`, incremental cursor
   sync mirroring `SearchIndex.swift` (schema_version + model id, batch
   transactions, resumable, per-source reset on rewind). **Deviation: no
   sqlite-vec / `vec0`** — vectors are unit-normalized Float32 BLOBs in a plain
   table, and search is a brute-force cosine scan (one `vDSP_mmul` from
   Accelerate) over the matrix loaded into memory on first search. At 300k ×
   512 that is ~610 MB resident and **~14 ms per query** — fast enough that an
   ANN index would only have bought a dependency. `PRAGMA page_size = 16384`
   keeps a 2 KB vector row off overflow pages (measured at 172k chunks: 388 MB
   on disk instead of 677 MB). Kicked off from `AppState` after the FTS sync,
   gated on
   `AIPrototype.isEnabled` — with the flag off the object is never created and
   `vec.sqlite` never exists.
4. New tool `semantic_search(query, person?, after?, before?, limit=15)`:
   embed the query, top-k by cosine, fuse with a parallel FTS bm25 query
   (reciprocal-rank fusion, k=60), hydrate each survivor back into readable
   messages from `search.sqlite`. `search_messages` stays — the model picks
   exact-match vs. meaning-match per question. **Deviation: the index takes the
   scope** (`search(_:limit:chats:after:before:)`) — person *and* dates are
   applied before its top-k, so a narrow question ("the move, in 2016") gets
   the best fifteen chunks inside that scope rather than whatever survives a
   global top-k. The tool description and system
   prompt both push the model to always pass `person`: unscoped meaning-search
   over 1.1M messages is noise (spike: 0/15 queries found the target in the top
   ten unscoped, 8/15 scoped to the right relationship; median global rank
   ~5,400 for chunks that rank ~7 inside their own conversation).

Verify: a fixed 20-question recall set (below) where the FTS-only Phase 1
build failed; Phase 2 must convert ≥ half of the misses.

## Phase 3 — Packaged moments

The subscription pitch in shareable form: three one-shot agent runs over the
Phase 1/2 toolbox (`max_tokens` 64000, `maxToolRounds` 40 against the chat's
25), each with its own system prompt, returning structured sections rendered as
native SwiftUI cards — not raw prose. Built as `Services/AIReports.swift` +
`Views/AIReportView.swift`. What shipped, and where it deviates from the sketch:

1. **Besties Wrapped(year | all-time)** 🎁 — totals, top five people as arcs
   rather than counts, busiest day read back with `read_transcript`,
   phrase-of-the-year counted in searchdb and backed by real quotes, one "you in
   a sentence".
2. **Friendship Wrapped(person)** 💛 — how it started (the real first exchange),
   the arc in two to four eras from `person_summary`'s monthly counts, busiest
   stretch, inside phrases (scoped to the pair's source/chat_id, then checked
   for rarity outside it), longest silence + who broke it, where it stands now.
   Named "Friendship Biography" in the first cut; the enum case is still
   `AIReportKind.biography` and the usage log still says `biography`, because
   `ai-chats` and every line already written to `ai-usage.jsonl` key off those
   names. The rename is user-facing only.
3. **Reconnect draft(person)** — the last real exchange plus a sample of the
   user's own messages *to that person* for register (length, openers,
   punctuation, emoji or none); two or three ready-to-send openers, each on a
   different angle. Buttons: copy / open in Messages — `openInMessages` was
   hoisted to a top-level func in `ContentView.swift` so the drafts reuse the
   leaderboard's `imessage://` plumbing. `imessage://` can't carry a body, so
   "Open in Messages" copies the draft first.

Deviations from the sketch, all in how the structure is obtained and shown:

- **The report is a tool call, not parsed JSON.** Each run's prompt ends with
  "call `render_report`", a tool whose `input_schema` mirrors `AIReport` field
  for field. `AIToolLoop` gained a `terminalTool` config: a tool_use with that
  name ends the run — its input is handed back, no tool_result goes out, nothing
  follows it. So the model's last word is structured by construction instead of
  prose that has to be scraped. A plain-text ending, or a `render_report` call
  that doesn't decode, buys exactly **one** nudge (opening with an `is_error`
  tool_result for the unanswered tool_use, or the API rejects the turn), then
  the run fails with `stopReason` `no_report`. Any interim `textDelta` is
  progress narration and shows as a dim line under the spinner.
- **The client is now shared.** `AIClient.swift` holds `AIToolLoop` (streaming
  + tool loop + per-request usage logging); `AIChatSession` is a thin wrapper
  over it with its own 16k ceiling, 25-round guard and rollback-on-failure, and
  the chat's behaviour is byte-for-byte unchanged. `AIPrompt` split into
  `identity` / `databaseCheatsheet` / `careRules` so the reports reuse them
  verbatim without disturbing the chat's cached system prefix. The system prompt
  is **per kind only** — the year and the person ride on the user turn — so the
  cache prefix is reused across people and years.
- **Nine section kinds, not free-form**: `stat` (consecutive stats auto-group
  into one adaptive grid), `story` (markdown prose), `quotes` (real messages in
  real bubbles — "Me" renders blue and right-aligned), `list`, `drafts`, plus
  the four added by the v2 design below. `MarkdownBody` moved out of
  `AIChatView.swift` into `Views/MarkdownBody.swift` so the chat and the story
  cards render markdown identically. The `kind` string is the whole contract
  between engine and view: an unknown kind falls through to `storyCard` rather
  than failing, and the lenient decode drops a malformed section on its own
  instead of throwing away a report that cost two minutes and 64k tokens.
- **Entry points**: the AI tab's empty state carries three moment cards →
  a picker (a year, or a person from the resolved conversations) → the report
  sheet; and every Reconnect row gets a ✨ button that sets
  `AppState.aiReportRequest` and switches to the AI tab, which consumes it.
  Screenshot mode already masks names, so the cards are the share surface —
  no export path.
- The turn line in `ai-usage.jsonl` is written by `AIReportEngine` (latency
  measured around the whole run, tool time included); the view only displays
  the usage it gets on `.turnCompleted`.

### v2 design — both reports are "Wrapped"

The first cut rendered as an editorial document: white cards, left-aligned
headings, prose. It read like a well-formatted essay, which is not a thing
anyone screenshots. The v2 design, approved on canvas, makes both yearly and
per-person reports poster-shaped and gives the model four new ways to say
something that isn't a paragraph.

- **Poster mode covers both wrapped kinds.** `isWrapped` became `isPoster`
  (`.wrapped` + `.biography`): centered 34pt heavy hero title, and every stat
  becomes a big colored tile from a six-tint rotation instead of a small white
  card. A separate `usesMedals` stays `.wrapped`-only, so the top-five
  leaderboard keeps its 🥇🥈🥉 while Friendship Wrapped's lists — eras, inside
  jokes — render as the plain bulleted `listCard`, which is what they are.
  Consequence for the briefs: the biography brief needed the same "a stat's
  value must be SHORT, the sentence goes in the label" rule Wrapped already
  carried, since its values now render at 40–54pt.
- **`emoji`** — the report's one ink-black tile (`#211E1A` on paper text).
  `heading` is an uppercase eyebrow, `items` are up to five `"<emoji> <count>"`
  lines. The view splits each on its *first* space and prints the count string
  verbatim in 11pt monospace, so `"😂 1,204"` keeps its separator rather than
  being parsed as an Int. Emoji live in `msgs.text` but FTS doesn't tokenise
  them, so the brief tells the model to count them with `text LIKE '%😂%'` in
  one `UNION ALL` — and to pick the candidates from real messages it has read,
  not from a generic emoji list.
- **`badge`** — a warm band (bubbleTan 0.55): one 46pt emoji left, a bold
  rounded title line and a caption right. The texting-personality card (Night
  Owl, Streak Keeper, Double Texter), named from a number the run already
  found and with that number in the caption.
- **`chart`** — a white card of bars, `items` as `"<label> <count>"`, one per
  bar in order. Heights normalize to the peak at 64pt; bars ≥55% of max take
  the sun, the rest bubbleTan; the first, last and two interior labels print
  under the axis, so 8–20 bars reads best. This is what "your eras" should
  always have been — the shape of a friendship over years is a picture, not a
  list of counts. The view splits on the *last* space (so labels may contain
  spaces) and filters the count to digits, so both `2017 1204` and
  `Summer 2017 1,204` work.
- **`photo`** — a real image out of the user's own archive, framed as a
  polaroid: white border, soft shadow, ±1.6° tilt alternating per photo,
  caption underneath. `value` is an absolute POSIX path copied verbatim from
  `attachment.filename`; the view expands `~`, standardizes away `..`, and
  requires the result to sit under `~/Library/Messages/Attachments/` or the
  WhatsApp group-container media dir before it will load it. Anything else — a
  path the model invented, a file that moved — drops the whole section
  silently. This is the only section that can vanish, so nothing else in a
  report is allowed to depend on it.

**The photo section will usually not appear, and that is a data fact, not a
bug.** Attachment rows vastly outlive their files: of 40,280 image attachments
in this Mac's chat.db, **926 (2.3%) still have a file on disk**, concentrated
almost entirely in the last few months (the most recent 200 rows: 82% present).
So Friendship Wrapped's "the first image you two ever exchanged" resolves to a
missing file in nearly every thread, and Besties Wrapped's busiest-day photo
only lands for a recent year. The contract was built exactly as designed and
the drop is graceful, but if the polaroid should actually show up, the cheap
fix is to let `photo` carry `items` as additional candidate paths in preference
order and have the view render the first one that loads — purely additive, a
view that ignores `items` behaves exactly as today. Not done, because it
changes an approved design.

Verify: generate all three for 5 real relationships; grade tone against the
care rules (nothing gossipy, nothing that scores the other person). For the v2
kinds specifically: the emoji counts must match a hand-run `LIKE` query, the
chart's bars must match `person_summary`'s monthly counts rolled up by year,
and any polaroid that renders must be a picture actually in that thread.

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

## Monetization gate (decided 2026-10-04)

> **Superseded 2026-10-08:** no free trial. This gate and the defaults flags
> below were deleted in Phase 3 of `docs/ai-subscription-plan.md`; the AI tab
> is now always visible and shows a paywall until `SubscriptionManager` has
> an active key.

The app stays fully featured and ungated — no history limits, no people
caps. **AI is the product**: one chat question free (over the full history,
so the taste demonstrates the whole power), then the paywall. The Wrapped
moments (Besties Wrapped, Friendship Wrapped, Reconnect drafts) are paid
from the start — a chat answer is the taste, the moments are the payoff.

Prototype simulation: `defaults write com.besties.app freeTier -bool true`
+ relaunch. One successful chat answer (stop reason end_turn — failures
don't count) spends the taste; after that the composer becomes the unlock
bar, preset pills route to the paywall sheet, and the moment cards show 🔒
and open the paywall. Reset the taste with
`defaults delete com.besties.app aiFreePromptsUsed`.

Ship requirement: the counter must be enforced **server-side** in the
proxy (free device/license = 1 credit) — the local counter is a
`defaults delete` away from unlimited free usage on our API key. The
paywall buttons currently stub to besties.gg; real checkout wiring is part
of the proxy/Stripe build, not this prototype.
