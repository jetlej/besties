# AI benchmark

Compares models for Besties AI on cost and quality: the same requests across
many models, several times each, scored automatically. Besties AI is the
paid product, so the goal is **the cheapest model that is reliably good
enough** — useful for picking the AI tab's default model and for sizing how
many credits an answer costs.

## What it tests

`fixtures.mjs` has made-up conversations with facts planted in them, each
aimed at a way cheap models fail:

| Case | Kind | What it catches |
|---|---|---|
| mia-busy-month | summary | missing the big things (new job, trip, sick cat, birthday, inside joke); hallucinating (wedding, a dog) |
| sam-quiet-month | summary | padding a near-empty month with invented events |
| family-group | summary | group chats: treating "Family" as one person |
| theo-cancelled-plans | summary | reporting a cancelled trip as if it happened |
| lena-long-month | summary | ~700 messages: recall of 5 facts buried in small talk |
| alex-lowercase | hello | matching an all-lowercase, no-emoji texting style |
| priya-formal | hello | matching a formal style; picking up the real thread |
| sofia-spanish | hello | replying in the conversation's language |
| ben-emoji | hello | matching an emoji-heavy style |

`prompts.mjs` builds a one-shot month recap and a drafted hello: the core
skills behind the AI tab's reports and reconnect drafts (the app's own prompts
are tool-driven, in `AIPrompt.swift` / `AIReports.swift`). `score.mjs` awards a point per fact
mentioned and per format/style check passed, and subtracts a point per
forbidden claim. **Pass** = every fact, every check, no hallucination.

## Running it

```sh
# price table, no key needed
node prices.mjs

# hosted models through OpenRouter (same zero-data-retention routing as the relay)
OPENROUTER_API_KEY=sk-or-… node bench.mjs --preset cheap --runs 3
OPENROUTER_API_KEY=sk-or-… node bench.mjs --preset reference --runs 3 --judge anthropic/claude-opus-5.5
OPENROUTER_API_KEY=sk-or-… node bench.mjs --preset local --runs 3     # open models that fit on a Mac

# a local server (Ollama shown) — what an MCP + local-model user would run
node bench.mjs --base http://localhost:11434/v1 --models gemma3:4b#none --runs 2 --concurrency 1 --char-budget 12000
```

`#effort` after a model id sets reasoning (`none`, `minimal`, `low`, …).
Raw answers land in `results/` (gitignored). A full `--preset all --runs 3`
is ~800 requests and costs well under $5, mostly the reference models.

## Real conversations (on your Mac)

`export_real.py` turns real conversations into private test cases with facts
you know are true. It reads `chat.db` read-only (Terminal needs Full Disk
Access) and writes to `private/cases.json`, which is gitignored. Running the
benchmark on those cases sends them to every model you test.

```sh
python3 export_real.py summary --handle +15551234567 --name "Mia" --month 2025-03 \
    --fact "Lisbon trip=lisbon" --fact "her new job=bakery|crumb" --forbid "Porto=went to porto"
python3 export_real.py hello --handle alex@example.com --name "Alex" --fact "the marathon=marathon|chicago"
OPENROUTER_API_KEY=sk-or-… node bench.mjs --fixtures private/cases.json --preset cheap --runs 3
```

## Cost model

`report.mjs` projects each model's measured output length (hidden reasoning
tokens included) onto real request sizes: a busy month ≈ 20,000 input tokens
(~1,000 messages), a hello ≈ 4,000 (the last 200 messages). `prices.mjs`
uses the cheapest zero-data-retention endpoint, which is what the relay pays.
