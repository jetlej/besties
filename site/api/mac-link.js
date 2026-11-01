// "Email me the Mac link" — phone visitors can't install a Mac app, so they
// leave an address and get the download link in their inbox for later.
// Rate limits keep the form from being used to mail strangers: per IP, and
// at most one email per address per day. Every address is kept in the
// `mac-link:emails` sorted set (score = signup time) for counting only. Only
// people who tick "email me about new stuff" land in `mac-link:optin` — that
// set is the launch/updates list; never mail the first one beyond the link.
const kv = require("./_lib/kv");
const email = require("./_lib/email");
const APP_NAME = require("./_lib/app-name");

module.exports = async (req, res) => {
  if (req.method !== "POST") { res.status(405).end(); return; }
  const body = req.body || {};
  // Honeypot: a field people never see, so only bots fill it in.
  if (body.website) { res.status(200).json({ ok: true }); return; }

  const to = email.parseEmail(body.email);
  const optIn = body.updates === true;
  if (!to) { res.status(400).json({ error: "That email doesn't look quite right." }); return; }
  if (!kv.configured || !email.configured) {
    res.status(503).json({ error: "Email isn't set up yet. Visit besties.gg on your Mac instead." });
    return;
  }

  if (!(await kv.allow(`rl:mac-link:${email.clientIP(req)}`, 5, 3600))) {
    res.status(429).json({ error: "Too many tries. Give it an hour." });
    return;
  }

  const sentKey = `mac-link:sent:${to}`;
  const [fresh] = await kv.pipeline([["SET", sentKey, "1", "EX", 86400, "NX"]]);
  if (fresh) {
    try {
      await email.sendEmail({
        to,
        subject: `${APP_NAME} for Mac: your download link`,
        text: [
          `Here's ${APP_NAME}, as promised. Open this on your Mac:`,
          "",
          `${email.SITE_URL}/thanks.html?src=email`,
          "",
          "It's free, and everything runs on your Mac. Open the download, drag",
          `${APP_NAME} into Applications, and it walks you through a 20-second setup.`,
          "",
          "P.S. Go text your mom.",
        ].join("\n"),
      });
    } catch (error) {
      await kv.pipeline([["DEL", sentKey]]);   // let them try again
      console.error("mac-link send failed:", error.message);
      res.status(502).json({ error: "We couldn't send that just now. Try again in a minute." });
      return;
    }
    await kv.pipeline([["ZADD", "mac-link:emails", Date.now(), to]]);
  }
  // Recorded even on a repeat signup, so ticking the box later still counts.
  if (optIn) await kv.pipeline([["ZADD", "mac-link:optin", Date.now(), to]]);
  // Same answer whether or not we just mailed them, so the form can't be
  // used to probe who has signed up.
  res.status(200).json({ ok: true });
};
