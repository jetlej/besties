// Stripe webhook (subscribe the endpoint to invoice.paid and
// customer.subscription.deleted only).
//   invoice.paid                  → OpenRouter key limit = usage + monthly credit (the
//                                   month's top-up; unused credit doesn't roll over;
//                                   yearly plans get months 2–12 from credit-topup.js).
//                                   Skipped for an
//                                   invoice already credited (`orcredit:<id>`, set by
//                                   ai-key's mint or an earlier top-up).
//   customer.subscription.deleted → OpenRouter key limit = usage (key stops working),
//                                   unless the customer still has another active sub
// Customers who haven't signed in yet have no key; ai-key mints one at the monthly credit.
// Each event id is processed once: a 60 s in-progress lock while it runs, and a
// 7-day done marker written only after it succeeds. A run killed mid-way leaves
// no done marker, so Stripe's retry (after the lock expires) processes it.
//
// Env: STRIPE_WEBHOOK_SECRET, STRIPE_SECRET_KEY, UPSTASH_REDIS_REST_URL,
//      UPSTASH_REDIS_REST_TOKEN, OPENROUTER_PROVISIONING_KEY
const crypto = require("crypto");

const { MONTHLY_CREDIT } = require("./_lib/plan"); // USD per month
const TOLERANCE = 300; // seconds, same as Stripe's libraries
const SEEN_TTL = 7 * 24 * 3600; // Stripe retries for up to 3 days
const LOCK_TTL = 60; // seconds; a normal run takes a few (one Stripe + two OpenRouter calls)
const CREDIT_TTL = 40 * 24 * 3600; // one billing period + Stripe's retry window

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

// The signature covers the exact bytes Stripe sent. Vercel's Node helpers
// buffer the body and replay it on 'data'/'end', so the stream is still readable.
function rawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(Buffer.from(c)));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// Stripe-Signature: t=<unix>,v1=<hex hmac>[,v1=…][,v0=…]; signed payload is "<t>.<body>".
function signatureValid(header, body) {
  let t = null;
  const sigs = [];
  for (const part of String(header || "").split(",")) {
    const i = part.indexOf("=");
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === "t") t = v;
    else if (k === "v1") sigs.push(v);
  }
  if (!/^\d+$/.test(t || "") || !sigs.length) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(t)) > TOLERANCE) return false;
  const expected = Buffer.from(
    crypto.createHmac("sha256", process.env.STRIPE_WEBHOOK_SECRET).update(`${t}.${body}`).digest("hex")
  );
  return sigs.some((s) => {
    const got = Buffer.from(s);
    return got.length === expected.length && crypto.timingSafeEqual(got, expected);
  });
}

// Sets the customer's key limit to `usage + extra` (USD). No key yet → nothing to do.
async function setLimit(customerId, extra) {
  const record = await redis("GET", `orkey:${customerId}`);
  if (!record) return;
  const { hash } = JSON.parse(record);
  const { data } = await openrouter(`/${hash}`);
  await openrouter(`/${hash}`, {
    method: "PATCH",
    body: JSON.stringify({ limit: data.usage + extra }),
  });
}

// True if the customer has an active/trialing subscription other than `exceptId`.
async function hasOtherActiveSub(customerId, exceptId) {
  const r = await fetch(
    `https://api.stripe.com/v1/subscriptions?customer=${encodeURIComponent(customerId)}&status=all&limit=100`,
    { headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` } }
  );
  if (!r.ok) throw new Error(`stripe subscriptions: ${r.status}`);
  const subs = await r.json();
  return subs.data.some((s) => s.id !== exceptId && (s.status === "active" || s.status === "trialing"));
}

async function handle(event) {
  const obj = event.data.object;
  if (event.type === "invoice.paid") {
    // `parent.subscription_details` on API ≥ 2025-03-31; `subscription` before that.
    const sub = obj.parent?.subscription_details?.subscription || obj.subscription;
    if (!sub) return;
    const creditKey = obj.id && `orcredit:${obj.id}`;
    if (creditKey && (await redis("GET", creditKey))) return; // already credited
    await setLimit(obj.customer, MONTHLY_CREDIT);
    if (creditKey) await redis("SET", creditKey, "1", "EX", String(CREDIT_TTL));
  } else if (event.type === "customer.subscription.deleted") {
    if (await hasOtherActiveSub(obj.customer, obj.id)) return;
    await setLimit(obj.customer, 0);
  }
}

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }
  const body = await rawBody(req);
  if (!signatureValid(req.headers["stripe-signature"], body)) {
    res.status(400).json({ error: "bad_signature" });
    return;
  }
  const event = JSON.parse(body);
  const seenKey = `whevt:${event.id}`;
  const lockKey = `${seenKey}:lock`;
  if (await redis("GET", seenKey)) {
    res.status(200).json({ received: true, duplicate: true });
    return;
  }
  if ((await redis("SET", lockKey, "1", "EX", String(LOCK_TTL), "NX")) !== "OK") {
    // Another run holds it (or was killed holding it): not done yet, so make
    // Stripe retry rather than mark it delivered.
    res.status(409).json({ error: "in_progress" });
    return;
  }
  try {
    await handle(event);
  } catch (e) {
    await redis("DEL", lockKey); // let Stripe's retry run it again
    console.error("stripe-webhook:", event.type, e.message);
    res.status(500).json({ error: "processing_failed" });
    return;
  }
  await redis("SET", seenKey, "1", "EX", String(SEEN_TTL));
  await redis("DEL", lockKey);
  res.status(200).json({ received: true });
};
