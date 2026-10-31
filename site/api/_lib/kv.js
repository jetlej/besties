// Upstash Redis over its REST API (Vercel Marketplace → Upstash), no SDK.
// Accepts both env var spellings the integration has used.
const BASE = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

const configured = Boolean(BASE && TOKEN);

// Runs commands in one round trip and returns each command's result.
async function pipeline(commands) {
  if (!configured) throw new Error("KV is not configured");
  const r = await fetch(`${BASE}/pipeline`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(commands),
  });
  if (!r.ok) throw new Error(`KV request failed: ${r.status}`);
  return (await r.json()).map((reply) => {
    if (reply.error) throw new Error(`KV error: ${reply.error}`);
    return reply.result;
  });
}

// Fixed-window rate limit: true while `key` has been hit at most `limit`
// times in the current `seconds`-long window.
async function allow(key, limit, seconds) {
  const [count] = await pipeline([["INCR", key], ["EXPIRE", key, seconds, "NX"]]);
  return count <= limit;
}

module.exports = { configured, pipeline, allow };
