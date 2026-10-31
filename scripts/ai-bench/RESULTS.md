# Benchmark results — Oct 28, 2026

## 1. Hosted models: not run yet (needs an OpenRouter key)

This environment had no model API keys, so hosted models haven't been run.
With a key it's one command (~10 min, under $5):

```sh
OPENROUTER_API_KEY=sk-or-… node bench.mjs --preset all --runs 3 --judge anthropic/claude-opus-5.5
```

**Decision rule for the AI tab's default model:** the cheapest model that
passes every case with **zero hallucinations across 3 runs**, and whose judge
score is within 0.3 of Claude Haiku 5.5's. If nothing cheaper qualifies, use
Haiku 5.5.

## 2. Prices per Besties request (OpenRouter list prices, no key needed)

Busy-month summary ≈ 20,000 input tokens (~1,000 messages) + 350 out; hello ≈
4,000 in + 60 out. "ZDR provider" is the cheapest zero-data-retention endpoint,
which is the only kind the relay uses. Models with **none** can't be used by
the relay.

| Model | $/M in | $/M out | ZDR provider | $/busy-month summary | $/hello | Summaries per $1 |
|---|---|---|---|---|---|---|
| meta-llama/llama-3.1-8b-instruct | $0.020 | $0.040 | DeepInfra | $0.00041 | $0.00008 | 2,415 |
| openai/gpt-oss-20b | $0.018 | $0.090 | AkashML | $0.00044 | $0.00009 | 2,298 |
| inclusionai/ling-3.0-flash | $0.021 | $0.063 | Novita | $0.00044 | $0.00009 | 2,262 |
| nex-agi/nex-n2.5-mini | $0.025 | $0.100 | **none** (no ZDR endpoint) | $0.00053 | $0.00011 | 1,869 |
| qwen/qwen3.7-flash | $0.030 | $0.130 | **none** (no ZDR endpoint) | $0.00065 | $0.00013 | 1,549 |
| ~z-ai/glm-flash-latest | $0.034 | $0.082 | **none** (no ZDR endpoint) | $0.00072 | $0.00014 | 1,391 |
| google/gemma-3-4b-it | $0.050 | $0.100 | Parasail | $0.00082 | $0.00016 | 1,223 |
| google/gemma-3-12b-it | $0.050 | $0.150 | DeepInfra | $0.00084 | $0.00017 | 1,187 |
| inception/mercury-2.5 | $0.040 | $0.150 | Inception | $0.00085 | $0.00017 | 1,173 |
| deepseek/deepseek-v4.1-flash | $0.140 | $0.420 | OpenInference | $0.00093 | $0.00017 | 1,079 |
| ~deepseek/deepseek-v4-flash-latest | $0.048 | $0.157 | **none** (no ZDR endpoint) | $0.0010 | $0.00020 | 995 |
| upstage/solar-mini4 | $0.050 | $0.200 | Upstage | $0.0011 | $0.00021 | 934 |
| meta-llama/llama-3.2-3b-instruct | $0.050 | $0.330 | Parasail | $0.0011 | $0.00022 | 896 |
| ibm-granite/granite-4.2-8b | $0.060 | $0.250 | CoreWeave | $0.0013 | $0.00025 | 798 |
| google/gemma-4-26b-a4b-it | $0.076 | $0.255 | DekaLLM | $0.0013 | $0.00026 | 760 |
| mistralai/mistral-small-3.2-24b-instruct | $0.075 | $0.200 | DeepInfra | $0.0016 | $0.00031 | 636 |
| qwen/qwen3.5-9b | $0.170 | $0.250 | SiliconFlow | $0.0021 | $0.00041 | 487 |
| xiaomi/mimo-v2.6-flash | $0.140 | $0.280 | Io Net | $0.0021 | $0.00042 | 476 |
| openai/gpt-6-luna | $0.100 | $0.500 | Azure | $0.0022 | $0.00043 | 459 |
| anthropic/claude-haiku-5.5 | $0.100 | $0.500 | Google | $0.0022 | $0.00043 | 459 |
| mistralai/ministral-8b-2512 | $0.150 | $0.150 | Mistral | $0.0031 | $0.00061 | 327 |
| google/gemini-3.5-flash-lite | $0.300 | $2.500 | Google | $0.0034 | $0.00068 | 290 |
| google/gemini-3.8-flash | $0.825 | $4.125 | Google | $0.0082 | $0.0016 | 122 |
| openai/gpt-6.1-terra | $1.000 | $5.000 | Azure | $0.0261 | $0.0052 | 38 |
| anthropic/claude-sonnet-5.5 | $2.000 | $10.000 | Google | $0.0435 | $0.0086 | 22 |
| openai/gpt-6.1-sol | $2.000 | $10.000 | Azure | $0.0435 | $0.0086 | 22 |
| anthropic/claude-opus-5.5 | $4.000 | $20.000 | Amazon Bedrock | $0.0870 | $0.0172 | 11 |

Models that think before answering add hidden output tokens on top of this;
the benchmark measures them.

## 3. Local models (for MCP + a local AI app like LM Studio)

Ollama 0.40.12 on a 4-core, 8 GB Linux VM (CPU only, so latency is far worse
than on Apple Silicon), thinking off, months capped at 12,000 characters to
fit small models' default context. 9 cases × 2 runs each.

| Model | Score | Worst | Pass | Halluc. | Errors | p50 latency | Out tok (sum/hello) | $/busy-month summary | $/hello |
|---|---|---|---|---|---|---|---|---|---|
| gemma3:4b#none | 89 | 75 | 44% | 1 | 0 | 31.7s | 254 / 25 | – | – |
| qwen3.5:4b#none | 88 | 67 | 44% | 4 | 0 | 35.1s | 231 / 35 | – | – |
| llama3.2:3b#none | 80 | 50 | 17% | 1 | 0 | 20.5s | 260 / 29 | – | – |

Median time on this CPU: summary ~50 s, hello 9–16 s.

What reading every answer showed (beyond the automatic checks):

- All three get the big facts. Their typical mistake is **who did what**:
  Qwen booked the May trip for "March 9th", called Mia's cat "your cat", and
  said "your flight" (it was Dad's); Gemma said "Rosa's flight" and addressed
  Mia as "you". These are now forbidden checks in `fixtures.mjs`.
- Months longer than the 12,000-character cap only cover their start. Without
  a cap, Ollama's default 8K context silently dropped the start of the
  prompt, including the instructions, and the models "analyzed the chat"
  instead of summarizing — worth knowing for anyone pairing MCP with a
  small local model.
- Thinking on (Qwen 3.5 4B's default) scored the same and took ~27× longer
  (median 954 s vs 35 s).
- Llama 3.2 3B wraps drafts in quotes and ignores the user's style most often.

**Best small local model: `gemma3:4b`** (fewest mix-ups). Bigger Macs should
do better with `gemma3:12b` / `gpt-oss:20b`; benchmark them with
`--preset local` once there's a key.
