// Authorization: Bearer <session token from auth-verify> → re-checks the
// Stripe subscription, then finds or creates that customer's OpenRouter
// runtime key ($9 limit) and returns {key, limit, usage} (USD).
//
// OpenRouter returns a key's plaintext only once, at creation
// (POST /api/v1/keys), so Redis keeps {hash, sealed key} per customer:
// `hash` drives GET/PATCH /api/v1/keys/{hash}; the key itself is
// AES-256-GCM sealed under a key derived from SEAL_SECRET. If a stored key
// can't be unsealed (SEAL_SECRET changed), it's replaced: the old key is
// deleted and a new one minted carrying over the old key's remaining credit.
//
// A $9 mint for a new key records the subscription's latest invoice as
// credited (`orcredit:<invoice id>`), so stripe-webhook doesn't top up the
// same invoice again when its invoice.paid arrives after the mint.
//
// Env: STRIPE_SECRET_KEY, UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN,
//      OPENROUTER_PROVISIONING_KEY (an OpenRouter "management key"), AUTH_SECRET,
//      SEAL_SECRET (dedicated sealing secret, independent of AUTH_SECRET so
//      rotating session tokens doesn't strand stored keys)
const crypto = require("crypto");

const MONTHLY_CREDIT = 9; // USD
const CREDIT_TTL = 40 * 24 * 3600; // one billing period + Stripe's retry window
const OR_KEYS = "https://openrouter.ai/api/v1/keys";

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
  const r = await fetch(`${OR_KEYS}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${process.env.OPENROUTER_PROVISIONING_KEY}`,
      "Content-Type": "application/json",
    },
  });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`openrouter ${init.method || "GET"} keys${path}: ${r.status}`);
  return r.json();
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// Returns the token payload, or null if the signature doesn't check out.
function verifyToken(token) {
  const [v, payload, sig] = String(token).split(".");
  if (v !== "v1" || !payload || !sig) return null;
  const expected = crypto.createHmac("sha256", process.env.AUTH_SECRET)
    .update(`v1.${payload}`).digest("base64url");
  if (!safeEqual(sig, expected)) return null;
  try {
    const p = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return typeof p.cid === "string" ? p : null;
  } catch {
    return null;
  }
}

function sealKey() {
  // Falling back to AUTH_SECRET keeps keys sealed before SEAL_SECRET existed
  // readable. Temporary: once SEAL_SECRET is set in production, drop the
  // fallback (keys sealed under AUTH_SECRET are then re-minted on first use).
  const secret = process.env.SEAL_SECRET || process.env.AUTH_SECRET;
  return crypto.createHmac("sha256", secret).update("openrouter-key-seal").digest();
}

function seal(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", sealKey(), iv);
  const ct = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), ct]).toString("base64url");
}

function unseal(sealed) {
  const b = Buffer.from(sealed, "base64url");
  const d = crypto.createDecipheriv("aes-256-gcm", sealKey(), b.subarray(0, 12));
  d.setAuthTag(b.subarray(12, 28));
  return Buffer.concat([d.update(b.subarray(28)), d.final()]).toString("utf8");
}

// The customer's active/trialing subscription, or undefined.
async function activeSub(customerId) {
  const r = await fetch(
    `https://api.stripe.com/v1/subscriptions?customer=${encodeURIComponent(customerId)}&status=all&limit=100`,
    { headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` } }
  );
  if (!r.ok) throw new Error(`stripe subscriptions: ${r.status}`);
  const subs = await r.json();
  return subs.data.find((s) => s.status === "active" || s.status === "trialing");
}

// Stored record → {key, limit, usage}, or null if the OpenRouter key is gone.
async function describe(record) {
  const { hash, key } = JSON.parse(record);
  const info = await openrouter(`/${hash}`);
  if (!info) return null;
  return { key: unseal(key), limit: info.data.limit, usage: info.data.usage };
}

async function findOrCreateKey(customerId, sub) {
  const slot = `orkey:${customerId}`;
  let limit = MONTHLY_CREDIT;
  let carriedOver = false;
  const existing = await redis("GET", slot);
  if (existing) {
    const { hash, key } = JSON.parse(existing);
    const info = await openrouter(`/${hash}`);
    if (info) {
      try {
        return { key: unseal(key), limit: info.data.limit, usage: info.data.usage };
      } catch {
        // Sealed under a different secret: the plaintext is gone for good.
        // Replace the key, carrying over what's left of this month's credit.
        limit = Math.max(0, info.data.limit - info.data.usage);
        carriedOver = true;
        await openrouter(`/${hash}`, { method: "DELETE" });
      }
    }
    await redis("DEL", slot); // key gone (or just replaced) on OpenRouter's side; mint a new one
  }

  const created = await openrouter("", {
    method: "POST",
    body: JSON.stringify({ name: `Besties ${customerId}`, limit }),
  });
  const record = JSON.stringify({ hash: created.data.hash, key: seal(created.key) });
  if ((await redis("SET", slot, record, "NX")) === "OK") {
    const invoice = typeof sub.latest_invoice === "string" ? sub.latest_invoice : sub.latest_invoice?.id;
    if (!carriedOver && invoice) {
      await redis("SET", `orcredit:${invoice}`, "1", "EX", String(CREDIT_TTL));
    }
    return { key: created.key, limit: created.data.limit, usage: created.data.usage };
  }
  // A concurrent request stored its key first — drop ours and use theirs.
  await openrouter(`/${created.data.hash}`, { method: "DELETE" });
  const winner = await describe(await redis("GET", slot));
  if (!winner) throw new Error("openrouter key vanished after race");
  return winner;
}

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "GET" && req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }
  const auth = String(req.headers.authorization || "");
  const session = auth.startsWith("Bearer ") ? verifyToken(auth.slice(7).trim()) : null;
  if (!session) {
    res.status(401).json({ error: "invalid_token" });
    return;
  }
  try {
    const sub = await activeSub(session.cid);
    if (!sub) {
      res.status(402).json({ error: "no_subscription" });
      return;
    }
    res.status(200).json(await findOrCreateKey(session.cid, sub));
  } catch (e) {
    console.error("ai-key:", e.message);
    res.status(502).json({ error: "upstream_error" });
  }
};
