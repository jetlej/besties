#!/usr/bin/env node
// Price comparison for Besties' AI requests, from OpenRouter's public model
// and endpoint lists (no API key needed).
//
//   node prices.mjs [model ids…]      (default: every model in the bench presets)
//
// "ZDR" is the price at the cheapest zero-data-retention endpoint, which is
// what the hosted relay pays (it only routes to ZDR providers). Costs per
// query use the README's request sizes and a typical answer length; models
// that think before answering spend more output tokens than this assumes, so
// prefer bench.mjs's measured numbers once you have them.
import { PRESETS } from "./presets.mjs";

const SIZES = { summary: { input: 20_000, output: 350 }, hello: { input: 4_000, output: 60 } };

const per1M = (s) => Number(s) * 1e6;

// Price for a request of `input` prompt tokens, honoring long-prompt tiers.
function tierPrice(pricing, input) {
  let p = { input: per1M(pricing.prompt), output: per1M(pricing.completion) };
  for (const o of pricing.overrides || []) {
    if (input >= o.min_prompt_tokens) p = { input: per1M(o.prompt), output: per1M(o.completion) };
  }
  return p;
}

export async function priceTable(models) {
  const [{ data: all }, { data: zdr }] = await Promise.all([
    fetch("https://openrouter.ai/api/v1/models").then((r) => r.json()),
    fetch("https://openrouter.ai/api/v1/endpoints/zdr").then((r) => r.json()),
  ]);
  const byId = Object.fromEntries(all.map((m) => [m.id, m]));
  return models.map((id) => {
    const m = byId[id];
    if (!m) return { id, missing: true };
    const zdrEndpoints = zdr.filter((e) => e.model_id === id || e.model_id === m.canonical_slug);
    const cost = (pricing) => {
      const s = tierPrice(pricing, SIZES.summary.input);
      const h = tierPrice(pricing, SIZES.hello.input);
      return {
        input: per1M(pricing.prompt), output: per1M(pricing.completion),
        summary: (SIZES.summary.input * s.input + SIZES.summary.output * s.output) / 1e6,
        hello: (SIZES.hello.input * h.input + SIZES.hello.output * h.output) / 1e6,
      };
    };
    const zdrCosts = zdrEndpoints.map((e) => ({ provider: e.provider_name, ...cost(e.pricing) }))
      .sort((a, b) => a.summary - b.summary);
    return { id, list: cost(m.pricing), zdr: zdrCosts[0] ?? null, context: m.context_length };
  });
}

const usd = (x) => (x < 0.001 ? `$${x.toFixed(5)}` : `$${x.toFixed(4)}`);

async function main() {
  const models = process.argv.slice(2).length ? process.argv.slice(2) : PRESETS.all;
  const rows = await priceTable(models);
  console.log("| Model | $/M in | $/M out | ZDR provider | $/busy-month summary | $/hello | Summaries per $1 |");
  console.log("|---|---|---|---|---|---|---|");
  for (const r of rows.sort((a, b) => (a.zdr?.summary ?? a.list?.summary ?? 9) - (b.zdr?.summary ?? b.list?.summary ?? 9))) {
    if (r.missing) { console.log(`| ${r.id} | not on OpenRouter | | | | | |`); continue; }
    const c = r.zdr ?? r.list;
    console.log(`| ${r.id} | $${r.list.input.toFixed(3)} | $${r.list.output.toFixed(3)} | ${r.zdr ? r.zdr.provider : "**none** (no ZDR endpoint)"} | ${usd(c.summary)} | ${usd(c.hello)} | ${Math.floor(1 / c.summary).toLocaleString()} |`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
