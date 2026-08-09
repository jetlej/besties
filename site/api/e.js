// First-party event relay → Reddit Conversions API.
// The browser only ever talks to besties.gg, so ad blockers never see a
// Reddit hostname. Token lives in the REDDIT_CAPI_TOKEN env var (this repo
// is public — never commit it).
const PIXEL_ID = "a2_jhid4j1rgdlj";
const TYPES = new Set(["PageVisit", "AddToCart", "Purchase"]);

module.exports = async (req, res) => {
  if (req.method !== "POST") { res.status(405).end(); return; }
  const b = req.body || {};
  if (!TYPES.has(b.t)) { res.status(204).end(); return; }

  const event = {
    event_at: new Date().toISOString(),
    event_type: { tracking_type: b.t },
    user: {
      ip_address: String(req.headers["x-forwarded-for"] || "").split(",")[0].trim() || undefined,
      user_agent: req.headers["user-agent"],
      uuid: typeof b.id === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(b.id)
        ? b.id : undefined,
      screen_dimensions:
        b.sw && b.sh ? { width: Number(b.sw), height: Number(b.sh) } : undefined
    }
  };
  if (typeof b.cid === "string" && b.cid) event.click_id = b.cid.slice(0, 512);
  if (b.t === "Purchase") {
    event.event_metadata = {
      currency: "USD",
      value_decimal: 11,
      item_count: 1,
      // Stripe session id — Reddit dedupes retries/reloads on this.
      conversion_id: typeof b.conv === "string" && b.conv ? b.conv.slice(0, 256) : undefined
    };
  }

  try {
    await fetch(`https://ads-api.reddit.com/api/v2.0/conversions/events/${PIXEL_ID}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.REDDIT_CAPI_TOKEN}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ events: [event] })
    });
  } catch (e) { /* never let tracking break the page */ }
  res.status(204).end();
};
