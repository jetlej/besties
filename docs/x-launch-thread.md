# Besties launch thread for X (@lej_dev). DRAFT, nothing posted

Oct 27, 2026. Written to the CMO brief: 8–10 tweets, each close to 280 characters, warm storytelling, plain sentence case, light dry humor, rare emoji (👌 👀 🤓). Tweet 1 carries the demo video; the link comes in tweet 10. Lengths are counted the way X counts them (emoji = 2, link = 23).

---

**1/** (demo video)
```
I built a time machine for iMessage and WhatsApp.

It started with one question: what was the first text I ever sent my best friend and cofounder?

The answer was about a week of nonstop scrolling away, and Messages has no way to jump back in time. So I built one.
```
Media: the demo video. Open a conversation, drag the slider back years, and land on the first message (names blurred).

**2/**
```
If you've ever tried this, you know the drill. Swipe up. Wait for it to load a few more weeks. Swipe up again. Lose your place. Give up.

In Besties you drag a slider to any day of any conversation and you're there, reading exactly what you both said, scrolling either way.
```

**3/**
```
The first thing I'd tell anyone to try: find your very first texts with your partner or best friend.

Mine was [what the first text said, and roughly when]. I had zero memory of it.

Then you start wondering who you were even talking to in May 2014. 👀
```

**4/** (Time Machine screenshot, names blurred)
```
That's what the Time Machine is for. Pick any month of your life and see the people you were texting most, ranked.

Scrubbing through the years turns out to be a strange, lovely way to remember people who were a huge part of your life for a while, and then quietly weren't.
```

**5/**
```
Tap anyone and you get your whole history together: how long you've been talking, your busiest day, month and year, and a reader that jumps right to them.

You'll land in conversations you'd swear you never had. It's the closest thing I've found to an actual time machine.
```

**6/** (Reconnect screenshot, names blurred)
```
It's been my passion project ever since, and the newer features are about the people you drift away from.

There's a Reconnect tab that finds the people you used to text all the time and then just stopped, so you can say hi before it gets any weirder than it already is.
```

**7/** ⚠️ Only post once AI search ships; see Notes. Swap-in 7b below describes what exists today.
```
The newest addition is full AI search across every message you've ever sent. No keywords to remember.

Ask it for "every restaurant anyone has ever recommended me" or "the name of that girl whose number I got outside that bar" and it just finds them.

Pretty magical. 🤓
```

**8/** ⚠️ Donations don't exist yet; see Notes.
```
It's completely free. Every feature.

The AI runs on your own Anthropic or OpenAI key. If you're not technical and don't want to deal with keys, you can subscribe for $4/mo and use the app's AI credits instead.

And there's a way to donate, if you so please.
```

**9/**
```
Oh, and for those of you who love WhatsApp, it works there too. Your WhatsApp chats get merged into the same timeline as your texts.

Want something added? Reply with it. My bots read the replies and open a PR right away for the good ones, and the most-liked ideas go first.
```

**10/**
```
It's a Mac app, free at besties.gg

This is the first of many side projects I'll be releasing from this account, and the rest are just as odd and specific as this one. If you want to see what comes next, follow along. 👌
```

---

## Swap-ins

**7b/** Use instead of 7/ if AI search hasn't shipped by launch. This is the AI that exists in the free-app branch.
```
The newest addition is AI, if you want it. Open anyone's page, tap ✨, and it'll summarize a whole month of your conversations, or help you draft a hello to someone you haven't talked to in years.

It only runs when you tap it. Search across everything is coming next. 🤓
```

**8b/** Use instead of 8/ if there's no donation option at launch.
```
It's completely free. Every feature.

The AI runs on your own Anthropic or OpenAI key. If you're not technical and don't want to deal with keys, you can subscribe for $4/mo and use the app's AI credits instead.

That's the whole business model. 👌
```
(If you use 8b, change the 👌 in tweet 10 so the emoji doesn't repeat.)

---

## Notes: check before posting

Checked against `origin/main` and the unmerged branch `conductor/besties-free-full-app-byok-or-paid-key` (commit 3292eff, Oct 26).

1. **The free model isn't live.** besties.gg still sells the app for $11 (`origin/main`). Tweets 8 and 10 say "free", so the branch (app 1.3, site, Stripe `STRIPE_AI_PRICE_ID`, KV, Resend env vars) has to be merged, released and deployed first. $4/mo is `AI_PRICE` in that branch's `site/build.sh`; confirm it matches the Stripe price.
2. **AI search over all messages doesn't exist yet.** The app has keyword search across iMessage and WhatsApp (on main). The branch's AI features are "summarize a month" and "draft a hello" on a person's page. Tweet 7 describes a feature that hasn't been built. Post 7b instead, or ship the feature first.
3. **There's no donation option** in the app or on the site. Add one (a Stripe payment link is enough), or use 8b.
4. **"My bots open a PR right away" (tweet 9)** is your workflow, and I can't verify it from the repo. Make sure it's actually running before launch day, since the replies will test it.
5. **Tweet 3 needs your real first text.** Don't fill it in from memory; open the app and look it up.
6. **Privacy is deliberately left out**, per the brief. If someone asks in the replies, this is accurate for the branch: your history is read on your Mac, and AI only runs when you tap ✨, sending that slice of one conversation to the provider you chose (with your key, straight to Anthropic or OpenAI; with Besties AI, through besties.gg, which doesn't store message text). Don't say "nothing leaves your Mac".
7. **WhatsApp** only works if the WhatsApp desktop app is installed on the Mac (Besties reads its local database). That's worth knowing for replies from European followers.
8. **Mac-only:** tweet 10 says it's a Mac app so phone readers aren't surprised. The branch's "Email me the Mac link" form handles phone visitors once it's deployed.
