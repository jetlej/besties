#!/usr/bin/env node
// Runs Besties' AI requests across many models, several times each, and
// scores the answers. Talks to any OpenAI-compatible endpoint: OpenRouter
// (default), or a local server such as Ollama / LM Studio.
//
//   OPENROUTER_API_KEY=… node bench.mjs --preset cheap --runs 3
//   node bench.mjs --base http://localhost:11434/v1 --models gemma4:e4b,qwen3.5:4b --runs 2
//   node bench.mjs --fixtures private/real.json …      (real cases, see export_real.py)
//
// Options:
//   --models a,b#low,c      model ids; "#effort" sets reasoning effort (none|minimal|low|medium|high)
//   --preset NAME           cheap | reference | all (OpenRouter model lists below)
//   --runs N                repeats per case (default 3)
//   --cases id,id           only these cases (default: all, incl. the long month)
//   --skip-long             leave out the ~700-message month (slow on local CPUs)
//   --concurrency N         parallel requests (default 6; use 1 for a local model)
//   --no-zdr                OpenRouter: allow providers without zero data retention
//   --judge MODEL           also have MODEL grade accuracy/tone 1–5 (costs extra)
//   --out FILE              results JSON (default results/<timestamp>.json)
//   --char-budget N         cap a month at N chars (12000 suits small local models)
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { allFixtures } from "./fixtures.mjs";
import { requestFor } from "./prompts.mjs";
import { score, cleanAnswer } from "./score.mjs";
import { report } from "./report.mjs";
import { PRESETS } from "./presets.mjs";

const here = dirname(fileURLToPath(import.meta.url));


function parseArgs(argv) {
  const args = { runs: 3, concurrency: 6, zdr: true, base: "https://openrouter.ai/api/v1" };
  for (let i = 0; i < argv.length; i++) {
    const [k, v] = [argv[i], argv[i + 1]];
    if (k === "--models") { args.models = v.split(","); i++; }
    else if (k === "--preset") { args.models = PRESETS[v]; i++; }
    else if (k === "--runs") { args.runs = Number(v); i++; }
    else if (k === "--cases") { args.cases = v.split(","); i++; }
    else if (k === "--skip-long") args.skipLong = true;
    else if (k === "--concurrency") { args.concurrency = Number(v); i++; }
    else if (k === "--base") { args.base = v.replace(/\/$/, ""); i++; }
    else if (k === "--no-zdr") args.zdr = false;
    else if (k === "--judge") { args.judge = v; i++; }
    else if (k === "--fixtures") { args.fixtures = v; i++; }
    else if (k === "--out") { args.out = v; i++; }
    else if (k === "--char-budget") { args.charBudget = Number(v); i++; }
    else throw new Error(`unknown option ${k}`);
  }
  if (!args.models?.length) throw new Error("pass --models or --preset");
  return args;
}

const isOpenRouter = (base) => base.includes("openrouter.ai");

// POST JSON with no client-side timeouts: fetch() gives up after 5 minutes
// without response headers, and a local model on a slow CPU can take longer.
function postJSON(url, headers, body) {
  const u = new URL(url);
  const data = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = (u.protocol === "https:" ? https : http).request(u, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), ...headers },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (text += c));
      res.on("end", () => {
        let json = {};
        try { json = JSON.parse(text); } catch {}
        resolve({ status: res.statusCode, json });
      });
    });
    req.on("error", reject);
    req.end(data);
  });
}

// One chat completion. Returns text, usage, latency; throws on HTTP errors.
async function complete(args, spec, system, prompt) {
  const [model, effort] = spec.split("#");
  const body = {
    model,
    messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
  };
  if (isOpenRouter(args.base)) {
    // Same routing rule as the hosted relay: only providers that don't keep data.
    if (args.zdr) body.provider = { data_collection: "deny", zdr: true };
    if (effort) body.reasoning = effort === "none" ? { enabled: false } : { effort };
  } else if (effort) {
    body.reasoning_effort = effort;
  }
  const key = process.env.OPENROUTER_API_KEY || process.env.BENCH_API_KEY;
  const started = Date.now();
  for (let attempt = 0; ; attempt++) {
    const r = await postJSON(`${args.base}/chat/completions`, key ? { Authorization: `Bearer ${key}` } : {}, body);
    const json = r.json;
    if ((r.status === 429 || r.status >= 500) && attempt < 2) {
      await new Promise((ok) => setTimeout(ok, 2000 * (attempt + 1)));
      continue;
    }
    if (r.status < 200 || r.status >= 300) throw new Error(`HTTP ${r.status}: ${json.error?.message || JSON.stringify(json).slice(0, 200)}`);
    const choice = json.choices?.[0];
    return {
      text: choice?.message?.content ?? "",
      finish: choice?.finish_reason,
      latencyMs: Date.now() - started,
      promptTokens: json.usage?.prompt_tokens ?? null,
      completionTokens: json.usage?.completion_tokens ?? null,
      reasoningTokens: json.usage?.completion_tokens_details?.reasoning_tokens ?? 0,
      cost: json.usage?.cost ?? null,
      provider: json.provider ?? null,
    };
  }
}

async function judge(args, f, request, answer) {
  const facts = f.facts.map(([n]) => `- ${n}`).join("\n");
  const system = "You grade AI-written texts for a messaging app. Be strict and brief. Reply with JSON only: "
    + '{"accuracy": 1-5, "tone": 1-5, "notes": "one sentence"}. accuracy: faithful to the messages, '
    + "no invented or wrong details, covers what matters. tone: warm, natural, and (for drafted texts) "
    + "sounds like the user.";
  const prompt = `TASK GIVEN TO THE AI:\n${request.system}\n\nMESSAGES:\n${request.prompt}\n\n`
    + `KEY FACTS IN THE MESSAGES:\n${facts}\n\nTHE AI'S ANSWER:\n${answer}`;
  const r = await complete({ ...args, zdr: false }, args.judge, system, prompt);
  const json = JSON.parse(cleanAnswer(r.text).replace(/^```(json)?|```$/g, "").trim());
  return { accuracy: json.accuracy, tone: json.tone, notes: json.notes, cost: r.cost };
}

async function pool(items, limit, fn) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await fn(items[next++]);
  }));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let fixtures = args.fixtures
    ? JSON.parse(readFileSync(args.fixtures, "utf8")).map(reviveFixture)
    : allFixtures();
  if (args.skipLong) fixtures = fixtures.filter((f) => f.id !== "lena-long-month");
  if (args.cases) fixtures = fixtures.filter((f) => args.cases.includes(f.id));

  const jobs = [];
  for (const model of args.models)
    for (const f of fixtures)
      for (let run = 1; run <= args.runs; run++) jobs.push({ model, f, run });

  const results = [];
  let done = 0;
  await pool(jobs, args.concurrency, async ({ model, f, run }) => {
    const request = requestFor(f, { charBudget: args.charBudget });
    const row = { model, case: f.id, kind: f.kind, run };
    try {
      Object.assign(row, await complete(args, model, request.system, request.prompt));
      Object.assign(row, score(f, row.text));
      if (args.judge && row.text) row.judge = await judge(args, f, request, row.text).catch((e) => ({ error: e.message }));
    } catch (error) {
      Object.assign(row, { error: error.message, score: 0, pass: false, failed: ["request failed"], hallucinations: [] });
    }
    results.push(row);
    done++;
    process.stderr.write(`\r${done}/${jobs.length} ${model.padEnd(40)} ${f.id.padEnd(24)} ${row.error ? "ERR " + row.error.slice(0, 60) : row.score}`.padEnd(140));
  });
  process.stderr.write("\n");

  const out = args.out || join(here, "results", `${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify({ args: { ...args }, results }, null, 1));
  console.log(await report(results, { pricedAt: isOpenRouter(args.base) }));
  console.error(`\nraw results: ${out}`);
}

// Real cases exported by export_real.py store regexes as strings.
function reviveFixture(f) {
  const re = (s) => new RegExp(s, "i");
  return {
    ...f,
    facts: (f.facts || []).map(([n, s]) => [n, re(s)]),
    forbidden: (f.forbidden || []).map(([n, s]) => [n, re(s)]),
  };
}

main().catch((e) => { console.error(e.message); process.exit(1); });
