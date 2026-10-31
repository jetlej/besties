// Besties AI plan: what a subscription buys. Prices themselves live in Stripe
// (STRIPE_PRICE_MONTHLY $7/mo, STRIPE_PRICE_YEARLY $69/yr); the site shows
// AI_PRICE_MONTHLY / AI_PRICE_YEARLY from site/build.sh — keep all three equal.
//
// MONTHLY_CREDIT is the OpenRouter spend limit added each month (USD of model
// usage). Users only ever see it as credits (1 credit = $0.001).
// The app's meter denominator (SubscriptionManager.monthlyCredit) must match.
const MONTHLY_CREDIT = Number(process.env.AI_MONTHLY_CREDIT || 3);

module.exports = { MONTHLY_CREDIT };
