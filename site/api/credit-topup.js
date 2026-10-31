// Daily cron (site/vercel.json): monthly credit for yearly subscribers.
// A yearly plan is invoiced once, so invoice.paid (stripe-webhook.js) only
// credits its first month. This tops up each later month on its anniversary
// of the billing period's start: key limit = usage + monthly credit, unused
// credit not rolling over — the same as a monthly plan.
//
// Each (subscription, period, month) is credited once (`orcredit:…` marker).
// The marker is set even when the customer has no key yet: ai-key mints a
// fresh key at a full month's credit, so a later top-up would double it.
//
// Env: CRON_SECRET (Vercel sends it as a bearer token), STRIPE_SECRET_KEY,
//      STRIPE_PRICE_YEARLY, UPSTASH_REDIS_REST_URL/TOKEN, OPENROUTER_PROVISIONING_KEY
const { MONTHLY_CREDIT } = require("./_lib/plan");

const CREDIT_TTL = 40 * 24 * 3600;

async function redis(...cmd) {
  const r = await fetch(process.env.UPSTASH_REDIS_REST_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.UPSTASH_REDIS_REST_TOKEN}` },
    body: JSON.stringify(cmd),
  });
  const j = await r.json();
  if (!r.ok || j.error) throw new Error(`redis ${cmd[0]}: ${j.error || r.status}`);
  return j.result;
}

async function openrouter(path, init = {}) {
  const r = await fetch(`https://openrouter.ai/api/v1/keys${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${process.env.OPENROUTER_PROVISIONING_KEY}`,
      "Content-Type": "application/json",
    },
  });
  if (!r.ok) throw new Error(`openrouter ${init.method || "GET"} keys${path}: ${r.status}`);
  return r.json();
}

// Same as stripe-webhook.js: limit = usage + extra. No key yet → nothing to do.
async function setLimit(customerId, extra) {
  const record = await redis("GET", `orkey:${customerId}`);
  if (!record) return;
  const { hash } = JSON.parse(record);
  const { data } = await openrouter(`/${hash}`);
  await openrouter(`/${hash}`, { method: "PATCH", body: JSON.stringify({ limit: data.usage + extra }) });
}

// Whole months from `start` to `now` by calendar anniversary (UTC): Jan 31 →
// Feb 28 counts as not yet a month; Jan 31 → Mar 1 counts as one.
function monthsElapsed(start, now) {
  let months = (now.getUTCFullYear() - start.getUTCFullYear()) * 12 + now.getUTCMonth() - start.getUTCMonth();
  const anniversary = new Date(start);
  anniversary.setUTCMonth(start.getUTCMonth() + months);
  if (anniversary > now) months -= 1;
  return months;
}

async function* yearlySubscriptions() {
  let after;
  for (;;) {
    const q = new URLSearchParams({ price: process.env.STRIPE_PRICE_YEARLY, status: "active", limit: "100" });
    if (after) q.set("starting_after", after);
    const r = await fetch(`https://api.stripe.com/v1/subscriptions?${q}`, {
      headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` },
    });
    if (!r.ok) throw new Error(`stripe subscriptions: ${r.status}`);
    const page = await r.json();
    yield* page.data;
    if (!page.has_more || !page.data.length) return;
    after = page.data[page.data.length - 1].id;
  }
}

async function run(now = new Date()) {
  let credited = 0;
  for await (const sub of yearlySubscriptions()) {
    // current_period_start moved onto subscription items in API 2025-03-31.
    const start = sub.items?.data?.[0]?.current_period_start ?? sub.current_period_start;
    if (!start) continue;
    const month = monthsElapsed(new Date(start * 1000), now);
    if (month < 1 || month > 11) continue; // month 0 is the invoice's own credit
    const marker = `orcredit:${sub.id}:${start}:m${month}`;
    if ((await redis("SET", marker, "1", "EX", String(CREDIT_TTL), "NX")) !== "OK") continue;
    try {
      await setLimit(sub.customer, MONTHLY_CREDIT);
      credited++;
    } catch (e) {
      await redis("DEL", marker); // retry tomorrow
      console.error("credit-topup:", sub.id, e.message);
    }
  }
  return credited;
}

module.exports = async (req, res) => {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  if (!process.env.STRIPE_PRICE_YEARLY) {
    res.status(200).json({ credited: 0, note: "no yearly price configured" });
    return;
  }
  try {
    res.status(200).json({ credited: await run() });
  } catch (e) {
    console.error("credit-topup:", e.message);
    res.status(500).json({ error: "topup_failed" });
  }
};

module.exports.monthsElapsed = monthsElapsed;
module.exports.run = run;
