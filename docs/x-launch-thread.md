# Besties launch thread for X (@lej_dev). FINAL DRAFT, nothing posted

Oct 27, 2026. Written to the CMO brief plus the CMO's final thread rules:

- Tweet 1 is about 200 characters: one human moment, "a time machine for iMessage and WhatsApp", ends with 🧵, carries the video, no number, link or @mention.
- One beat per tweet, each readable on its own. Besties is named in tweet 2, and no tweet starts with "And" or "So".
- The link sits in the body of tweet 7, with context. There's no link in tweet 1 and no link self-reply.
- Tweet 9 is the follow ask with the handle. Tweet 10 pays off tweet 1 and asks for a repost.

Lengths are counted the way X counts them (emoji = 2, link = 23), all ≤ 280.

---

**1** (demo video) · 200
```
I wanted to read the first text I ever sent my best friend and cofounder. It was about a week of scrolling away, with no way to jump back.

Instead, I built a time machine for iMessage and WhatsApp 🧵
```
Video: open a conversation, drag the slider back years, and land on the first message (names and text blurred).

**2** · 264
```
It's called Besties. You drag a slider to any day in any conversation and you're just there, reading exactly what you both said.

Your very first texts with your partner or best friend are one drag away. It's the closest thing I've found to an actual time machine.
```

**3** (Time Machine screenshot, names blurred) · 263
```
Who were you texting most in May 2014? 👀

Besties ranks the people you talked to most in any month of your life. It's a strange, lovely way to remember people who were a huge part of your life for a while, and to reread conversations you'd never remember having.
```

**4** (Reconnect screenshot, names blurred) · 258
```
Besties has been my passion project ever since, and the newer features are about people you drifted from.

A Reconnect tab finds the friends you used to text all the time and then just stopped, so you can say hi before it gets any weirder than it already is.
```

**5** ⚠️ only once AI search ships; otherwise use 5b · 244
```
The newest feature is AI search across every message, no keywords required.

Ask Besties for "every restaurant anyone has ever recommended me" or "the name of that girl whose number I got outside that bar" and it finds them.

Pretty magical. 🤓
```

**6** ⚠️ needs a donation option; otherwise use 6b · 244
```
Besties is completely free, every feature.

The AI runs on your own Anthropic or OpenAI key. If you're not technical and don't want to deal with keys, $4/mo gets you the app's AI credits instead.

There's also a way to donate, if you so please.
```

**7** · 230
```
Oh, and for those of you who love WhatsApp, Besties works there too. If WhatsApp is on your Mac, your chats get merged into the same timeline as your texts.

Besties is a Mac app, and you can download it at besties.gg
```

**8** ⚠️ make sure the bots are running · 222
```
What should Besties do next? Reply with your feature requests.

My bots read the replies and open a PR right away for the cool ones, and I'll build whatever gets the most likes first. Small or weird, every idea is welcome.
```
**9** · 200
```
Besties is the first of many side projects I'll be releasing, and every one of them will be as specific and a little odd as this one.

Follow @lej_dev if you want to see them. The next app drops here.
```

**10** · 255
```
The first text I ever sent my best friend and cofounder? "[the exact text]", on [date].

It took one drag of a slider instead of a week of scrolling.

If you know someone who'd love to find their first text, a repost of the first tweet would mean a lot 👌
```

---

## Swap-ins

**5b**: use if AI search hasn't shipped. This is the AI that exists in the free-app branch. · 240
```
The newest feature is AI, if you want it. Open anyone's page in Besties, tap ✨, and it'll summarize a whole month of your conversations, or help you draft a hello to someone you haven't talked to in years.

It only runs when you tap it. 🤓
```

**6b**: use if there's no donation option at launch. · 229
```
Besties is completely free, every feature.

The AI runs on your own Anthropic or OpenAI key. If you're not technical and don't want to deal with keys, $4/mo gets you the app's AI credits instead.

That's the whole business model.
```

---

## Notes: check before posting

Checked against `origin/main` and the unmerged branch `conductor/besties-free-full-app-byok-or-paid-key` (commit 3292eff). Nothing changed between Oct 26 and Oct 27.

1. **The free model isn't live yet.** besties.gg still sells the app for $11, and tweets 6 and 7 assume it's free. Merge the branch, release 1.3 and deploy the site before posting. $4/mo is `AI_PRICE` in that branch's `site/build.sh`; confirm it matches the Stripe price.
2. **AI search over every message doesn't exist yet.** The app has keyword search, and the branch's AI does "summarize a month" and "draft a hello". Post 5b instead of 5, or ship search first.
3. **There's no donation option** in the app or on the site. Add one (a Stripe payment link is enough), or post 6b.
4. **The bots-open-PRs claim (tweet 8)** can't be verified from the repo. Launch-day replies will test it.
5. **Tweet 10 needs the real first text and date.** Look them up in the app, and check with your cofounder that they're OK with it being public. If not, use "It was [a one-line description, e.g. 'about pizza']" instead of the quote.
6. **Privacy is deliberately left out**, per the brief. If someone asks in the replies, this is accurate for the branch: your history is read on your Mac, and AI only runs when you tap ✨, sending that slice of one conversation to the provider you chose (with your own key, straight to Anthropic or OpenAI; with Besties AI, through besties.gg, which doesn't store message text). Don't say "nothing leaves your Mac".
7. **WhatsApp** only works if the WhatsApp desktop app is installed on the Mac, because Besties reads its local database. Tweet 7 says "if WhatsApp is on your Mac" for that reason.
8. **Emoji:** 🧵 (required by the rules), plus 👀, 🤓 and 👌, each used once.
