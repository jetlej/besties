// Turns raw benchmark rows into a per-model table (Markdown).
//
// Cost columns project each model's *observed* output (including hidden
// reasoning tokens) onto real request sizes, at OpenRouter list prices:
//   busy-month summary ≈ 20,000 input tokens (~1,000 messages)
//   hello draft        ≈  4,000 input tokens (the last 200 messages)
export const TYPICAL_INPUT = { summary: 20_000, hello: 4_000 };

let pricesPromise;
export function openRouterPrices() {
  pricesPromise ??= fetch("https://openrouter.ai/api/v1/models")
    .then((r) => r.json())
    .then(({ data }) => Object.fromEntries(data.map((m) => [m.id, {
      input: Number(m.pricing?.prompt ?? NaN) * 1e6,
      output: Number(m.pricing?.completion ?? NaN) * 1e6,
    }])))
    .catch(() => ({}));
  return pricesPromise;
}

const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN);
const median = (xs) => {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};
const usd = (x) => (Number.isFinite(x) ? (x < 0.01 ? `$${x.toFixed(5)}` : `$${x.toFixed(4)}`) : "–");

export async function summarize(results, { pricedAt = true } = {}) {
  const prices = pricedAt ? await openRouterPrices() : {};
  const byModel = new Map();
  for (const r of results) {
    if (!byModel.has(r.model)) byModel.set(r.model, []);
    byModel.get(r.model).push(r);
  }
  const rows = [];
  for (const [model, rs] of byModel) {
    const ok = rs.filter((r) => !r.error);
    const price = prices[model.split("#")[0]];
    const outTokens = (kind) => mean(ok.filter((r) => r.kind === kind && r.completionTokens != null).map((r) => r.completionTokens));
    const project = (kind) => price
      ? (TYPICAL_INPUT[kind] * price.input + (outTokens(kind) || 0) * price.output) / 1e6
      : NaN;
    const summaryCost = project("summary");
    const helloCost = project("hello");
    rows.push({
      model,
      score: mean(rs.map((r) => r.score)),
      worst: Math.min(...rs.map((r) => r.score)),
      passRate: rs.filter((r) => r.pass).length / rs.length,
      hallucinations: rs.reduce((n, r) => n + (r.hallucinations?.length || 0), 0),
      errors: rs.filter((r) => r.error).length,
      runs: rs.length,
      latency: median(ok.map((r) => r.latencyMs)) / 1000,
      summaryOut: outTokens("summary"),
      helloOut: outTokens("hello"),
      measuredCost: mean(ok.filter((r) => r.cost != null).map((r) => r.cost)),
      summaryCost,
      helloCost,
      judge: mean(ok.filter((r) => r.judge?.accuracy).map((r) => (r.judge.accuracy + r.judge.tone) / 2)),
      price,
    });
  }
  return rows.sort((a, b) => b.score - a.score || a.summaryCost - b.summaryCost);
}

export async function report(results, opts) {
  const rows = await summarize(results, opts);
  const hasJudge = rows.some((r) => Number.isFinite(r.judge));
  const head = ["Model", "Score", "Worst", "Pass", "Halluc.", "Errors", "p50 latency", "Out tok (sum/hello)",
    "$/busy-month summary", "$/hello", ...(hasJudge ? ["Judge 1–5"] : [])];
  const lines = [
    `| ${head.join(" | ")} |`,
    `|${head.map(() => "---").join("|")}|`,
    ...rows.map((r) => `| ${[
      r.model, r.score.toFixed(0), r.worst, `${Math.round(r.passRate * 100)}%`, r.hallucinations,
      r.errors ? `${r.errors}/${r.runs}` : 0, `${r.latency.toFixed(1)}s`,
      `${Math.round(r.summaryOut || 0)} / ${Math.round(r.helloOut || 0)}`,
      usd(r.summaryCost), usd(r.helloCost), ...(hasJudge ? [Number.isFinite(r.judge) ? r.judge.toFixed(1) : "–"] : []),
    ].join(" | ")} |`),
  ];
  // Which checks each model missed most, to see *how* cheap models fail.
  const misses = new Map();
  for (const r of results) for (const f of [...(r.failed || []), ...(r.hallucinations || []).map((h) => `HALLUCINATED: ${h}`)]) {
    const key = `${r.model}\u0000${r.case}: ${f.replace(/ \(\d+\)$/, "")}`;
    misses.set(key, (misses.get(key) || 0) + 1);
  }
  const top = [...misses].sort((a, b) => b[1] - a[1]).slice(0, 25)
    .map(([k, n]) => { const [m, what] = k.split("\u0000"); return `- ${m} — ${what} ×${n}`; });
  return `${lines.join("\n")}\n\nMost frequent misses:\n${top.join("\n")}`;
}
