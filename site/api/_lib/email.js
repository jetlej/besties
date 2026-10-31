// Transactional email through Resend's REST API (RESEND_API_KEY). The
// sending domain in EMAIL_FROM must be verified in Resend.
const APP_NAME = require("./app-name");

const SITE_URL = process.env.SITE_URL || "https://besties.gg";
const configured = Boolean(process.env.RESEND_API_KEY);

async function sendEmail({ to, subject, text }) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: process.env.EMAIL_FROM || `${APP_NAME} <hi@besties.gg>`,
      to: [to],
      subject,
      text,
    }),
  });
  if (!r.ok) throw new Error(`Resend request failed: ${r.status}`);
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Normalized address, or null if it doesn't look like one.
function parseEmail(value) {
  const email = String(value || "").trim().toLowerCase();
  return email.length <= 254 && EMAIL_PATTERN.test(email) ? email : null;
}

function clientIP(req) {
  return String(req.headers["x-forwarded-for"] || "").split(",")[0].trim() || "unknown";
}

module.exports = { configured, sendEmail, parseEmail, clientIP, SITE_URL };
