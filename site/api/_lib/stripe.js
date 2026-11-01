// Minimal Stripe REST client — form-encoded params, no SDK, same as
// download.js has always talked to Stripe.
async function stripe(path, { method = "GET", params } = {}) {
  const query = params ? new URLSearchParams(params).toString() : "";
  const isGet = method === "GET";
  const r = await fetch(`https://api.stripe.com/v1/${path}${isGet && query ? `?${query}` : ""}`, {
    method,
    headers: {
      Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`,
      ...(isGet ? {} : { "Content-Type": "application/x-www-form-urlencoded" }),
    },
    body: isGet ? undefined : query,
  });
  const json = await r.json();
  if (!r.ok) {
    const error = new Error(json.error?.message || `Stripe request failed: ${r.status}`);
    error.status = r.status;
    throw error;
  }
  return json;
}

module.exports = { stripe };
