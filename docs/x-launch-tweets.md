# Besties launch tweets for X (@lej_dev), raw voice. DRAFTS, nothing posted

Oct 26, 2026. Second pass. The first drafts read like marketing; these are meant to sound like a founder being straight about a small app.

**Rules for this pass:** lowercase, one thought per line, real numbers as the hook, no hype words, no slogans, and no "try it"/"link below" asks. Each link goes in the first reply as a bare `besties.gg?utm_source=x&utm_content=tweetN`, never in the tweet body. Every number not in [brackets] is real (sources below). Each tweet is under 280 characters.

---

## The 5

**1. the launch (video)**

```
i launched a mac app in july and didn't tell anyone

it reads your imessage and whatsapp history and shows who you've actually been closest to, year by year

i ran it on [X] years of my own texts

my #1 wasn't who i expected

so this is the launch i guess
```

Media: 20–30s screen recording of the Time Machine tab, scrubbing through the years while the top people reorder (names blurred). Cut before #1 is shown.

**2. the $160 reddit fail (screenshot)**

```
i spent $160 on reddit ads for besties

91 people clicked through

19 of them clicked "compile it yourself", the free option

3 started checkout

1 bought it. for $11

so i'm down $149 and i learned that reddit really likes free
```

Media: the PostHog funnel (pageview → compile_click / checkout_start → purchase_complete), filtered to `utm_source=reddit`.

**3. the honest numbers (screenshot)**

```
besties, the real numbers:

started it in march
selling it since july 13
[N] sales at $11 = $[X]
0 subscribers (there is no subscription)
2 github stars
135 people have ever visited the site
in october: 7

posting them anyway
```

Media: Stripe payments list, or the PostHog visitors chart. Its long flat tail after mid-September is the point.

**4. the busiest day (screenshot)**

```
i've sent [blurred] [X] texts since [year]

besties says our busiest day ever was [date]

i scrolled back to see why

[one honest line about what happened that day]

i had completely forgotten it
```

Media: the person page KPI cards (total messages, busiest day) with the name and avatar blurred. Optionally a second image: the conversation reader jumped to that day, with text blurred.

**5. "why would i give an app my texts" (text, optional code screenshot)**

```
"why would i give an app my texts"

fair. i wouldn't either

besties reads the messages database that's already on your mac

no account, no login

the only time it goes online is to check for updates

the code's on github if you want to check that yourself
```

Media: none, or a screenshot of the GitHub repo file list.

---

## 2 alternates

**A. reconnect (screenshot)**

```
besties has a tab called "reconnect"

it finds people i used to text all the time and then just stopped

mine had [X] people on it

i texted [X] of them last night

[X] wrote back
```

Media: the Reconnect tab with names blurred. Only post this after actually doing it; the numbers have to be real.

**B. free vs $11 (text)**

```
besties costs $11 once

or $0 if you build it yourself from the github repo

20 people have clicked "compile it yourself"

2 have bought it

i think that's telling me something
```

This one sets up the free-model announcement in Note 1 below without promising it. Hold it until the pricing decision is made.

---

## Where the numbers come from

PostHog project "Besties" (533638), tracking from Jul 29, 2026 to today. Localhost test events are excluded. Ad blockers make PostHog undercount, so every figure is a floor.

| Number | Value | Source |
|---|---|---|
| Started | Mar 5, 2026 | first git commit |
| Selling since | Jul 13, 2026 | "Go live: real Stripe payment link" commit |
| Price | $11 once; free to build from source | `site/src/landing.html` |
| Reddit ad spend | $160 | Jordan |
| Reddit visitors | 91 (Aug 16 – Sep 15) | pageviews with `utm_source=reddit` |
| Reddit → "compile it yourself" | 19 | `compile_click` |
| Reddit → checkout started | 3 | `checkout_start` |
| Reddit → bought | 1 | `purchase_complete` |
| All-time site visitors | 135 | unique pageviews on besties.gg |
| Visitors in October | 7 | same, since Oct 1 |
| "compile it yourself" clicks, all-time | 20 | `compile_click` |
| Purchases seen by PostHog | 2 (Aug 18 via Reddit, Aug 31 direct on an iPhone) | `purchase_complete` |
| GitHub | 2 stars, 0 forks | `gh repo view` |
| Subscribers | 0. No subscription exists | the app has no billing or AI code |

**Not available from here:**
- **Revenue and total sales:** need Stripe. PostHog saw 2 purchases, which would be $22 before fees. Some sales may have used the 100%-off `BESTIE` code, and ad blockers hide others, so take the real count from Stripe.
- **Installs:** the app has no telemetry. Sparkle's update checks to `besties.gg` would show active installs in Vercel request logs, but the token on this machine can't see the `lej` team.

## Checks before posting

1. **The Reddit sale in tweet 2:** the purchase came 15 seconds after checkout started. That fits Apple Pay, but it could also be a friend using `BESTIE`. Confirm in Stripe that it was a paid $11. If it was the free code, change the tweet to "0 bought it" and "down $160", which is a better tweet anyway.
2. **The iPhone purchase on Aug 31:** someone bought a Mac app on a phone, or it was you testing. If it was a stranger, that's a good post for later about the phone-visitor problem.
3. **Tweet 4 and alternate A** need your own data. Run the app and fill them in. Don't estimate.

## Claims these drafts avoid, and why

- **"nothing leaves your mac" / "no network calls":** not true since Sparkle shipped (Aug 4). The app checks `besties.gg` for updates. Tweet 5 says exactly that: the only time it goes online is the update check. That matches the code; the other URLs in the app are local deep links into Messages, WhatsApp and System Settings.
- **"no server":** the app has none, but the site does (Vercel functions for downloads, updates and the Reddit relay). Tweet 5 doesn't say it.
- **"open source":** the repo is public but has no LICENSE file, so legally it's source-available. Say "the code's on github". The landing page's audit prompt calls it "open-source" and the README says "no network calls at all"; both should be fixed, but that's separate from this PR.

## Notes vs. the strategy doc

1. **The free + bring-your-own-key / subscription model doesn't exist in the code yet.** Besties has no AI features and no billing; today it's $11 once, or free to build. These drafts describe the app as it is now. When the new model ships, alternate B makes a natural lead-in, and the old "free model" draft can be rewritten in this voice.
2. **The phone visitor problem shows up in the data:** 15 of 135 visitors were on iOS, and 28 were on Windows, who can't use a Mac app either. The "email me the Mac link" box is still worth adding before tweet 1.
3. **Suggested order:** 1 (launch) → 5 (privacy, to answer the replies tweet 1 will get) → 2 (Reddit) → 4 (personal) → 3 (numbers, on a Friday).

---

# X bios for @lej_dev

Current profile: display name "lej", bio "building things", location NYC, no link, 5,772 followers.

**Setup for all five:** put `besties.gg` in the **website** field. X shows location next to the link, so a location ending in "→" points at it. Bios are lowercase and raw like the tweets. Lengths use X's count (emoji = 2) against the 160 limit; location is capped at 30.

**A. thesis first**
```
anyone can clone an app with ai now. so mine are free, and you only pay for extras that actually help you. making besties.gg
```
Location: `nyc → the app`

**B. marc lou-style list**
```
💬 besties.gg: a mac app that reads your texts and shows who matters. $[X]/mo
📉 $160 on reddit ads → 1 sale
🔜 next app, whenever
```
Location: `My apps →`

`$[X]/mo` is subscription revenue. Until there is some, use a real number that already exists, e.g. `135 visitors so far`.

**C. self-deprecating**
```
building things. lately a mac app that reads your texts. spent $160 on reddit ads and sold one copy
```
Location: `nyc`

**D. building in public**
```
building free apps in public, paid for by optional extras. sharing every number, including the $160 of reddit ads that flopped
```
Location: `watch it grow →`

**E. short identity line**
```
building things, sharing the numbers
```
Location: `nyc`

**Notes**
- **A, D and B's `$/mo` depend on the free + bring-your-own-AI-key / subscription model being live.** As of today `origin/main` still has no AI or billing code, and besties.gg sells the app for $11 once. Until the new version ships, use C or E, or switch D to "apps" instead of "free apps".
- **"sold one copy" (C) and "1 sale" (B) refer to the Reddit ads specifically** (PostHog: 1 purchase from Reddit). Stripe hasn't confirmed that sale was a paid $11 rather than the `BESTIE` friends code, so check that first. If it was free, use "sold zero copies" / "0 sales".
- Neither bio claims anything about data staying on the Mac.
