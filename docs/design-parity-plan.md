# App ↔ Website Design Parity — Plan

Goal: the site's CSS "app recreation" windows must match the app as it looks
after today's redesign. Rule from the design skill: mockups are honest — real
UI, real palette. Right now the site shows a UI that no longer exists.

## What changed in the app today (the source of truth)

1. **Tab bar**: custom full-width bar on a flat gray track (6% ink), sun pill
   on the active tab, icon + title + one-line description per tab
   ("Your lifetime leaderboard" · "Rewind month by month" · "Who's worth a
   text" · "Find any message by keyword"). New order: All Time · Time
   Machine · Reconnect · Search. Old segmented picker is gone.
2. **Search tab is new** — full-content search over 1M+ messages with
   person/time/sender/source/attachment filters, snippets, and jump-to-
   message. The site neither shows nor mentions it.
3. **Podium removed** from Time Machine; hierarchy moved into the
   leaderboard — top-3 rows have gold/silver/bronze medals and larger
   avatars/names (46/40/34pt), strict table-aligned columns for everything.
4. **Filter + chrome**: "Filter people…" (filter icon, not magnifier) sits
   right-aligned directly above each list; Reconnect's "Last Contact:"
   picker is inline-left of it; helper texts under the tabs are gone; the
   settings gear is a bare icon in the title bar with the title centered.

## Site surfaces to update (`site/src/landing.html` — one shared CSS kit)

1. **Shared recreation kit**: add a `.tabbar` component (gray track, sun
   pill, icon + title + description) to the kit all windows reuse; retire
   any segmented-control styling. This is the one-place fix that most
   windows inherit.
2. **Hero demo** (`#scrTM`): remove `tmPodium` and its animation step; give
   the leaderboard the top-3 medal + size treatment; check the demo cursor
   choreography still lands on real elements.
3. **Tab tour section**: reorder to match, and add a fourth stop for
   Search — a window showing the big query field, filter chips, and
   highlighted-snippet results. This is also the marketing gap: search is
   now a headline feature ("find any message in milliseconds"), worth a
   hero-copy mention.
4. **Use-case slides + Reconnect window**: medals/sizing on any leaderboard
   rows; Reconnect window gets the inline "Last Contact:" + filter row;
   remove helper-text lines from any window that shows them.
5. **Window chrome in mocks**: centered title, bare gear top-right,
   traffic lights — match the real title bar.

## App-side consistency sweep (small)

- Onboarding + WhatsApp prompt screens: no references to renamed/moved
  UI (quick read-through).
- Delete the now-dead `PodiumView` + `monthTopFive` once the podium's
  removal is final (they're unreferenced code today).
- `docs/tab-redesign-plan.md`: mark done; note the final decisions
  (flat gray 1a, full-width + descriptions, top-3-only hierarchy).

## Process + verification

1. Commit the app redesign to main first (it's all uncommitted — the site
   work should reference a fixed target).
2. Edit `site/src/landing.html`, then `cd site && ./build.sh`; preview via
   the existing `site` launch config and compare side-by-side against the
   running app — same tab order, same medal colors, same track gray.
3. Deploy per CLAUDE.md: `./build.sh && vercel deploy --prod --yes` from
   this machine (never Git-connected — `site/dl/` carries the paid DMG).

Estimate: ~half a day, almost all of it in landing.html. No release.sh or
DMG implications — site-only deploy.
