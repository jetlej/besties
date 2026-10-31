// Starts a Besties AI subscription: /api/subscribe?plan=monthly|yearly creates
// a Stripe Checkout session for STRIPE_PRICE_MONTHLY ($7/mo) or
// STRIPE_PRICE_YEARLY ($69/yr) and sends the browser there. Checkout creates
// the Stripe customer with the email entered, which is what auth-request looks
// up when the app signs in. Afterwards Stripe returns to /subscribed.html.
const { stripe } = require("./_lib/stripe");
const { SITE_URL } = require("./_lib/email");

const PRICES = {
  monthly: () => process.env.STRIPE_PRICE_MONTHLY,
  yearly: () => process.env.STRIPE_PRICE_YEARLY,
};

module.exports = async (req, res) => {
  const plan = PRICES[req.query.plan] ? req.query.plan : "monthly";
  const price = PRICES[plan]();
  if (!price) { res.status(503).send("Subscriptions aren't open yet."); return; }
  const session = await stripe("checkout/sessions", {
    method: "POST",
    params: {
      mode: "subscription",
      "line_items[0][price]": price,
      "line_items[0][quantity]": "1",
      allow_promotion_codes: "true",
      success_url: `${SITE_URL}/subscribed.html?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${SITE_URL}/#ai`,
    },
  });
  res.redirect(303, session.url);
};
