// POST {email} → if that email has an active/trialing Stripe subscription,
// email it a 6-digit sign-in code (valid 10 min). Always answers 200 with the
// same body after the same minimum delay, so callers can't tell who subscribes.
// The delay covers the whole subscriber path including the Resend send: there's
// no package.json here, so @vercel/functions' waitUntil isn't available to send
// the email after responding.
//
// Env: STRIPE_SECRET_KEY, UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN,
//      RESEND_API_KEY, AUTH_SECRET
const crypto = require("crypto");

const CODE_TTL = 600; // seconds
const EMAIL_MAX_PER_HOUR = 3;
const IP_MAX_PER_HOUR = 10;
const MIN_RESPONSE_MS = 3000; // flattens timing between subscriber / non-subscriber paths
const FROM = "Besties <login@besties.gg>";

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

// Counts this request against a 1-hour window; returns true while under `max`.
// INCR first, then EXPIRE NX: a key that expired between two calls is recreated
// by INCR and still gets a TTL (SET NX + INCR could leave it without one).
async function underLimit(key, max) {
  const n = await redis("INCR", key);
  await redis("EXPIRE", key, "3600", "NX");
  return n <= max;
}

async function stripe(path) {
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` },
  });
  if (!r.ok) throw new Error(`stripe ${path.split("?")[0]}: ${r.status}`);
  return r.json();
}

// The list filter is case-sensitive but read-after-write; search is
// case-insensitive but lags ~1 min. Union both so a just-paid buyer and a
// differently-cased address both resolve. Search is fuzzy (it can match
// another customer's address), so every candidate must equal `email` exactly.
async function subscribedCustomerId(email) {
  const [list, search] = await Promise.all([
    stripe(`customers?limit=10&email=${encodeURIComponent(email)}`),
    stripe(`customers/search?limit=10&query=${encodeURIComponent(`email:'${email}'`)}`),
  ]);
  const ids = [...new Set([...list.data, ...search.data]
    .filter((c) => String(c.email || "").trim().toLowerCase() === email)
    .map((c) => c.id))];
  for (const id of ids) {
    const subs = await stripe(`subscriptions?customer=${id}&status=all&limit=100`);
    if (subs.data.some((s) => s.status === "active" || s.status === "trialing")) return id;
  }
  return null;
}

async function handle(req) {
  let body = req.body || {};
  if (typeof body === "string") body = JSON.parse(body);
  const email = String(body.email || "").trim().toLowerCase();
  // No quotes/backslashes: the address is interpolated into a Stripe search query.
  if (email.length > 254 || !/^[^\s@"'\\]+@[^\s@"'\\]+\.[^\s@"'\\]+$/.test(email)) return;

  const ip = String(req.headers["x-forwarded-for"] || req.headers["x-real-ip"] || "")
    .split(",")[0].trim() || "unknown";
  const emailHash = crypto.createHash("sha256").update(email).digest("hex");
  // Count every request (subscriber or not) so limits never reveal anything.
  if (!(await underLimit(`rl:ip:${ip}`, IP_MAX_PER_HOUR))) return;
  if (!(await underLimit(`rl:email:${emailHash}`, EMAIL_MAX_PER_HOUR))) return;
  // A new code request resets auth-verify's attempt counter for everyone, so
  // the counter never behaves differently for subscribers.
  await redis("DEL", `login:${emailHash}:tries`);

  const customerId = await subscribedCustomerId(email);
  if (!customerId) return;

  const code = String(crypto.randomInt(0, 1000000)).padStart(6, "0");
  // Keyed SHA-256 (HMAC) so a Redis dump can't be brute-forced over 10^6 codes.
  const hash = crypto.createHmac("sha256", process.env.AUTH_SECRET)
    .update(`code:${email}:${code}`).digest("hex");
  await redis("SET", `login:${emailHash}`, JSON.stringify({ h: hash, c: customerId }), "EX", String(CODE_TTL));

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM,
      to: [email],
      subject: `Your Besties sign-in code: ${code}`,
      text: `Your Besties sign-in code is ${code}\n\nIt expires in 10 minutes. If you didn't ask for it, ignore this email.`,
    }),
  });
  if (!r.ok) throw new Error(`resend: ${r.status}`);
}

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }
  const started = Date.now();
  try {
    await handle(req);
  } catch (e) {
    console.error("auth-request:", e.message);
  }
  const wait = MIN_RESPONSE_MS - (Date.now() - started);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  res.status(200).json({ ok: true });
};
