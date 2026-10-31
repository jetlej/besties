// Model lists for bench.mjs / prices.mjs (OpenRouter ids, Oct 2026).
export const PRESETS = {
  // Cheapest hosted models worth trying for Besties AI.
  cheap: [
    "inclusionai/ling-3.0-flash", "openai/gpt-oss-20b", "qwen/qwen3.7-flash",
    "~deepseek/deepseek-v4-flash-latest", "deepseek/deepseek-v4.1-flash", "~z-ai/glm-flash-latest",
    "inception/mercury-2.5", "nex-agi/nex-n2.5-mini", "mistralai/mistral-small-3.2-24b-instruct",
    "google/gemma-3-12b-it", "ibm-granite/granite-4.2-8b", "upstage/solar-mini4",
    "xiaomi/mimo-v2.6-flash", "google/gemini-3.5-flash-lite", "openai/gpt-6-luna",
    "anthropic/claude-haiku-5.5",
  ],
  // Mid and top tiers, for comparison.
  reference: [
    "google/gemini-3.8-flash", "openai/gpt-6.1-terra", "anthropic/claude-sonnet-5.5",
    "openai/gpt-6.1-sol", "anthropic/claude-opus-5.5",
  ],
  // Open-weight models small enough to run on a Mac (the app's "On this Mac"
  // option), benchmarked through OpenRouter with the same weights. Rough RAM
  // needed at 4-bit: 4B ≈ 8 GB Mac, 8–12B ≈ 16 GB, 20–26B ≈ 24–32 GB.
  local: [
    "google/gemma-3-4b-it", "meta-llama/llama-3.2-3b-instruct", "mistralai/ministral-8b-2512",
    "meta-llama/llama-3.1-8b-instruct", "qwen/qwen3.5-9b", "google/gemma-3-12b-it",
    "openai/gpt-oss-20b", "google/gemma-4-26b-a4b-it",
  ],
};
PRESETS.all = [...new Set([...PRESETS.cheap, ...PRESETS.reference, ...PRESETS.local])];
