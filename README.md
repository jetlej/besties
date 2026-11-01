# 💬 Besties

A little macOS app that reads your iMessage history and turns it into a time machine for your relationships 💛

Ever had a friend you used to talk to all the time, and then life happened? Besties finds those conversations, shows you who matters, and lets you jump straight back into any moment you shared.

## What it does

Three tabs, plus a person page you can open from anywhere:

- **Reconnect** — scores your dormant conversations and shows you who's most worth a text right now, with an adjustable "last contact" window ✨
- **All Time** — a dashboard of your whole message life: totals, share you sent, people messaged, busiest year/month, night-owl share, trend charts, and a leaderboard of your top people 👯
- **Time Machine** — scrub through the months with a slider and watch your top people rise and fall on a live podium and leaderboard 🕰️

### The person page 🔍

Click **any avatar or name** anywhere in the app to open that person's page:

- **Relationship KPIs** — total messages, the share you sent, how long you've been talking, and your busiest day / month / year together
- Tap a busiest-day/month/year card to **jump the conversation straight to that moment**
- **The conversation reader** — the real magic: a scrubber spanning your entire history with that person, so you can slide to any date and read exactly what you were saying, with smooth infinite scroll in both directions. Something iMessage itself can't do.

Messages across all of a person's numbers and emails (SMS + iMessage) are merged into one thread.

### Besties AI ✨

The AI tab answers anything about your history, writes your Wrapped (and one for any friendship), and drafts messages to people you've drifted from. It's the paid part of Besties: $7/mo or $69/yr, with AI credit every month. The app talks straight to the model through OpenRouter with a per-subscriber key; our servers never see your messages (see [`docs/ai-subscription-plan.md`](docs/ai-subscription-plan.md)).

### Use Besties from other AI apps (MCP) 🔌

Settings → AI Apps turns Besties into a read-only [MCP](https://modelcontextprotocol.io) server on `127.0.0.1`, so an AI app on your Mac can answer questions about your history. With LM Studio and a local model, nothing leaves your Mac. Off by default; apps need the token shown in Settings, and it only runs while Besties is open.

## Privacy

Everything runs **locally**. There's no account and no analytics, and your history stays on your Mac. The only network traffic is update checks and, if you subscribe, Besties AI: what a question needs goes straight from your Mac to the AI model, never through our servers. Prefer fully local? Use MCP with a local AI app. Without AI, everything works in Airplane Mode. Besties reads your local `chat.db` via Full Disk Access and your Contacts (to show names), and that's it.

## Run it

1. Open `Besties/Besties.xcodeproj` in Xcode
2. Select your team under Signing & Capabilities
3. Build & Run
4. Grant Full Disk Access when prompted

## Share it

Run `./release.sh 1.1` to build a signed + notarized `Besties.zip` you can send to anyone — it installs with no security warning. It also stages that version for Sparkle auto-updates. (Reuses the existing notary credential; override the keychain profile with `./release.sh 1.1 <profile>`.)

---

*made with love and a mass quantity of mass-produced ai*
