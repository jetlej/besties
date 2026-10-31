// Besties AI plan: what a subscription buys. Prices themselves live in Stripe
// (STRIPE_PRICE_MONTHLY $7/mo, STRIPE_PRICE_YEARLY $69/yr); the site shows
// AI_PRICE_MONTHLY / AI_PRICE_YEARLY from site/build.sh — keep all three equal.
//
// MONTHLY_CREDIT is the OpenRouter spend limit added each month (USD of model
// usage). $2.20 keeps a $4 margin on the $7 plan even if every cent is used:
//   $7 − Stripe (2.9% + 0.7% Billing + $0.30 = $0.55) − $2.20 × 1.055 (OpenRouter's
//   5.5% credit fee) = $4.13 ($4.02 on an international card, +1.5%).
// The app's meter denominator (SubscriptionManager.monthlyCredit) must match.
const MONTHLY_CREDIT = Number(process.env.AI_MONTHLY_CREDIT || 2.2);

module.exports = { MONTHLY_CREDIT };
