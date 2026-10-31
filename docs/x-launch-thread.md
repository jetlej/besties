# Besties launch thread for X (@lej_dev). FINAL DRAFT, nothing posted

Oct 28, 2026. Written to the CMO brief plus the CMO's final thread rules:

- Tweet 1 is about 200 characters: one human moment, "a time machine for iMessage and WhatsApp", ends with 🧵, carries the video, no "1/", link or @mention.
- One beat per tweet, each readable on its own. Besties is named in tweet 2, and no tweet starts with "And" or "So".
- WhatsApp gets its own tweet (6). The link sits in the body of tweet 7, next to "it's free", so it has context. There's no link in tweet 1 and no link self-reply.
- Tweet 9 is the follow ask with the handle and a reason. Tweet 10 pays off tweet 1 and asks for a repost of it.
- One main ask per tweet: replies (8), follow (9), repost (10), download (7). The donation line in 7 is an aside, not a second ask.

Lengths are counted the way X counts them (emoji = 2, link = 23), and all are ≤ 280.

---

**1** (demo video) · 200
```
I wanted to read the first text I ever sent my best friend and cofounder. It was about a week of scrolling away, with no way to jump back.

Instead, I built a time machine for iMessage and WhatsApp 🧵
```
Video: open a conversation, drag the slider back years, and land on the first message (names and text blurred).

**2** · 261
```
It's called Besties. Drag a slider to any day in any conversation and you're right there, reading exactly what you both said.

Your very first texts with your partner or best friend are one drag away. It's the closest thing I've found to an actual time machine.
```

**3** (Time Machine screenshot, names blurred) · 263
```
Who were you texting most in May 2014? 👀

Besties ranks the people you've talked to most in any month or year of your life. It's a fascinating way to remember people who were once a huge part of your life, and to reread conversations you'd never remember having.
```

**4** (Reconnect screenshot, names blurred) · 272
```
I started Besties in March to find one text. It's been my passion project ever since, and the newest features are about the people you drifted from.

Reconnect finds friends you used to text all the time and then just stopped, so you can say hi before it gets any weirder.
```

**5** ⚠️ only once AI search ships; otherwise use 5b · 274
```
Besties also has AI search over every message in your history, and you don't need to remember a single keyword.

Ask it for "every restaurant anyone has ever recommended me" or "the name of that girl whose number I got outside that bar" and it finds them.

Pretty magical 🤓
```

**6** · 231
```
Oh, and for those of you who love WhatsApp, Besties works there too.

If WhatsApp is on your Mac, it reads those chats as well. A friend you text on both shows up as one person, with one conversation, instead of two half-histories.
```

**7** ⚠️ needs the free model live and a donation option; otherwise use 7b · 254
```
Besties is completely free, every feature. Bring your own AI key, or if you're not technical, $4/mo gets you the app's AI credits instead.

There's a way to donate too, if you so please.

It's a Mac app, and you can download it at besties.gg
```

**8** ⚠️ make sure the bots are running · 222
```
What should Besties do next? Reply with your feature requests.

My bots read the replies and open a PR right away for the cool ones, and whatever gets the most likes gets built first. Small or weird, every idea is welcome.
```

**9** · 218
```
Besties is the first of many side projects I'll be releasing from this account, and every one of them will be as novel as this one, or I won't ship it.

Follow @lej_dev if you want to see them. The next app drops here.
```

**10** ⚠️ fill in the real text and date · 255
```
The first text I ever sent my best friend and cofounder? "[the exact text]", on [date].

It took one drag of a slider instead of a week of scrolling.

If you know someone who'd love to find their first text, a repost of the first tweet would mean a lot 👌
```

---

## Swap-ins

**5b**: use if AI search hasn't shipped. This describes the AI that exists in the free-app branch. · 271
```
Besties also has AI, if you want it. Open anyone's page, tap ✨, and it'll summarize a whole month of your conversations, or help you draft a hello to someone you haven't talked to in years.

It only runs when you tap it, and it can even run on a model on your own Mac 🤓
```

**7b**: use if there's no donation option at launch. · 239
```
Besties is completely free, every feature. Bring your own AI key, or if you're not technical, $4/mo gets you the app's AI credits instead. That's the whole business model.

It's a Mac app, and you can download it at besties.gg
```

---

## Notes: check before posting

Checked against `origin/main` (fde364e) and the unmerged free-app branch `conductor/besties-free-full-app-byok-or-paid-key` (PR #3, now at 67e0159).

1. **The free model isn't live yet.** besties.gg still sells the app for $11, and tweet 7 says it's free. Merge PR #3, release 1.3 and deploy the site before posting. $4/mo is `AI_PRICE` in that branch's `site/build.sh`; confirm it matches the Stripe price.
2. **AI search over every message doesn't exist in the app yet.** The app has keyword search. The branch's ✨ AI summarizes a month and drafts a hello, and its new MCP server lets outside AI apps call `search_messages`, but that's not the in-app "ask anything" search tweet 5 describes. Post 5b instead, or ship search first.
3. **There's no donation option** in the app or on the site. Add one (a Stripe payment link is enough), or post 7b.
4. **The bots-open-PRs claim (tweet 8)** can't be verified from the repo. Launch-day replies will test it.
5. **Tweet 10 needs the real first text and date.** Look them up in the app, and check with your cofounder that they're OK with it being public. If not, use "It was [a one-line description, e.g. 'about pizza']" instead of the quote.
6. **"I started Besties in March" (tweet 4)** is the first git commit, Mar 5, 2026 (see the source table in `x-launch-tweets.md`).
7. **WhatsApp (tweet 6)** only works if the WhatsApp desktop app is installed on the Mac, because Besties reads its local database. People who are on both get merged into one conversation (`mergeKey` in `ContentView.swift`, the merged reader in `ConversationReaderView.swift`).
8. **Privacy is deliberately left out of the thread**, per the brief. If someone asks in the replies, this is accurate for the branch: your history is read on your Mac, and AI only runs when you tap ✨. It then sends that slice of one conversation to the provider you chose: with your own key, straight to that provider; with Besties AI, through besties.gg (which doesn't store message text) and OpenRouter, limited to zero-data-retention providers; with a local model (Ollama or LM Studio), nowhere off the Mac. The site itself does run servers. Don't say "nothing leaves your Mac", "no server" or "open source" (the repo has no LICENSE; say "the code's on GitHub").
9. **Emoji:** 🧵 (required by the rules), plus 👀, 🤓 and 👌, each used once.
