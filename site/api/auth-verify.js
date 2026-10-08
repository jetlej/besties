// POST {email, code} → checks the 6-digit code from auth-request (max 5 tries
// per code) and returns a long-lived session token:
//   v1.<base64url {"cid","email","iat"}>.<base64url HMAC-SHA256(AUTH_SECRET)>
// The token never expires on its own; ai-key re-checks Stripe on every use.
//
// Every attempt is counted before the code is looked at, and the counting is
// identical whether or not a code exists, so neither a burst of parallel
// guesses nor the status/latency pattern says anything about who subscribes.
// Also capped per IP and by a global failure budget.
//
// Env: UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN, AUTH_SECRET
const crypto = require("crypto");

const CODE_TTL = 600; // seconds — matches auth-request
const MAX_TRIES = 5;
const IP_MAX_PER_HOUR = 30;
const GLOBAL_FAIL_MAX_PER_HOUR = 500; // across all emails; past it, every verify gets 429
const FAIL_KEY = "rl:verify:fail";

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

// INCR then EXPIRE NX, so a recreated key always gets a TTL.
async function count(key, ttl) {
  const n = await redis("INCR", key);
  await redis("EXPIRE", key, String(ttl), "NX");
  return n;
}

function tooMany(res) {
  res.status(429).json({ error: "too_many_attempts" });
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }
  let body = req.body || {};
  try {
    if (typeof body === "string") body = JSON.parse(body);
  } catch {
    body = {};
  }
  const email = String(body.email || "").trim().toLowerCase();
  const code = String(body.code || "").trim();
  if (!email || !/^\d{6}$/.test(code)) {
    res.status(400).json({ error: "invalid_code" });
    return;
  }

  if (Number(await redis("GET", FAIL_KEY)) >= GLOBAL_FAIL_MAX_PER_HOUR) return tooMany(res);
  const ip = String(req.headers["x-forwarded-for"] || req.headers["x-real-ip"] || "")
    .split(",")[0].trim() || "unknown";
  if ((await count(`rl:verify:ip:${ip}`, 3600)) > IP_MAX_PER_HOUR) return tooMany(res);

  const emailHash = crypto.createHash("sha256").update(email).digest("hex");
  const codeKey = `login:${emailHash}`;
  // Count first, then read the code. Past the cap the code is burned without
  // being compared; the tries key is never deleted here (that would let
  // in-flight requests start over at 0) — it expires, or a new code resets it.
  if ((await count(`${codeKey}:tries`, CODE_TTL)) > MAX_TRIES) {
    await redis("DEL", codeKey);
    return tooMany(res);
  }

  const stored = await redis("GET", codeKey);
  const hash = crypto.createHmac("sha256", process.env.AUTH_SECRET)
    .update(`code:${email}:${code}`).digest("hex");
  const { h, c: customerId } = stored ? JSON.parse(stored) : {};
  // "No code" and "wrong code" take the same path and answer the same 400.
  if (!stored || !safeEqual(hash, h)) {
    await count(FAIL_KEY, 3600);
    res.status(400).json({ error: "invalid_code" });
    return;
  }
  await redis("DEL", codeKey);

  const payload = Buffer.from(JSON.stringify({
    cid: customerId,
    email,
    iat: Math.floor(Date.now() / 1000),
  })).toString("base64url");
  const sig = crypto.createHmac("sha256", process.env.AUTH_SECRET)
    .update(`v1.${payload}`).digest("base64url");
  res.status(200).json({ token: `v1.${payload}.${sig}` });
};
