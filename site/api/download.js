// Verifies a completed Stripe Checkout session, then hands over the app.
// The zip lives at an unguessable path (env var, since this repo is public)
// that only this endpoint reveals.
const ZIP_PATH = process.env.DOWNLOAD_PATH;

module.exports = async (req, res) => {
  const sessionId = String(req.query.session_id || "");
  if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sessionId)) {
    res.status(400).send("Missing or invalid session ID.");
    return;
  }
  const r = await fetch(
    `https://api.stripe.com/v1/checkout/sessions/${sessionId}`,
    { headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` } }
  );
  if (!r.ok) {
    res.status(404).send("We couldn't find that purchase.");
    return;
  }
  const session = await r.json();
  if (session.payment_status !== "paid") {
    res.status(402).send("This purchase hasn't been completed yet.");
    return;
  }
  res.redirect(302, ZIP_PATH);
};
