# Chunky Tab Bar — Plan  ·  ✅ SHIPPED

**Status: done.** Built in `Besties/Besties/Views/ContentView.swift` (`TabBar`,
`LeaderboardRow`) + `BestiesApp.swift` (`installTitlebarGear`), and mirrored in
the marketing site's app recreations (`site/src/landing.html`). What actually
shipped is in **Final decisions** at the bottom — where it differs from the
plan below, the bottom wins.

Goal: replace the stock segmented Picker at the top of the main window with a
custom tab bar — bigger, blockier, one icon per tab — and reorder so Time
Machine sits second.

## New order + icons

| # | Tab | SF Symbol | Why |
|---|-----|-----------|-----|
| 1 | All Time | `trophy.fill` | it's the leaderboard |
| 2 | Time Machine | `clock.arrow.circlepath` | the literal rewind glyph |
| 3 | Search | `magnifyingglass` | universal |
| 4 | Reconnect | `bubble.left.and.bubble.right.fill` | it's about restarting conversations |

Alternates if any read wrong on screen: All Time `chart.bar.fill`, Reconnect
`person.2.wave.2.fill` or `heart.fill`. Decide by looking, not in the doc.

## Design spec (brand: paper / ink / sun / bubble tan / blue)

- **TabBar** = one `HStack` of TabButton chips, centered in the header.
- **TabButton**: icon over-or-beside label. Recommendation: icon + label in a
  horizontal pair, `.callout.weight(.semibold)`, ~12pt vertical / ~16pt
  horizontal padding, corner radius ~10 — chunky like the site's buttons, not
  macOS-native.
- **Selected**: sun background, ink text/icon — yellow stays the "you are
  here / clickable" signal. **Unselected**: transparent with secondary
  ink; **hover**: bubble-tan fill + pointer cursor.
- **Motion**: a single sun pill slides between tabs via
  `matchedGeometryEffect` (~0.25s spring). One continuous move, honors
  Reduce Motion (falls back to a plain swap).
- **Keyboard**: ⌘1–⌘4 select tabs (menu items next to the existing ⌘F, which
  keeps working unchanged — it sets `selectedTab = .search` by name, not
  position).

## Layout consequences (the real work)

The current header ZStack centers the Picker and overlays the name-search
field + gear on the trailing side, with `tabsFitCentered` deciding when to
fall back to a left-aligned row. A wider tab bar shifts the numbers:

- 4 chunky tabs ≈ 480–540pt wide. Window minimum is 500pt, so the centered
  layout with a 220pt search field beside it will NOT fit at small sizes far
  more often than today.
- Plan: keep the same two-mode logic but tune it — centered mode when there's
  room; below that, tabs go left, search field shrinks/hides behind its
  existing rules. If it still can't fit at 500pt, drop labels to icon-only
  chips (tooltips carry the names) rather than shrinking type.
- Zero layout shift when switching tabs: the bar's height is fixed; the
  Reconnect/Time Machine helper text below already varies per-tab and stays
  as is.

## Implementation steps

1. `Tab` enum: reorder cases to All Time, Time Machine, Search, Reconnect
   (CaseIterable order drives the bar; nothing else keys off position) and
   give each a `systemImage`.
2. New `TabBarView` in ContentView.swift (small enough to live there; move to
   Views/TabBar.swift only if it grows) with selected/hover/pill states.
3. Swap it in for `tabPicker`, retune `tabsFitCentered` widths, verify the
   narrow-window fallback at 500pt.
4. ⌘1–⌘4 in the `.commands` block next to Find.
5. Eyeball pass at 500pt / 800pt / fullscreen, light theme, Reduce Motion on
   and off; screenshot for the record.

## Estimate

Half a day including the narrow-window fiddling. No data, index, or release
implications — pure ContentView UI.

---

## Final decisions (as shipped)

1. **Flat gray track (option 1a).** The bar is a single track — `Color.ink`
   at 6.5%, corner radius 12, 3pt padding, 2pt between chips — with one
   `matchedGeometryEffect` sun pill (radius 9) sliding to the active tab.
   Hover on an inactive chip = ink at 5.5%. Reduce Motion swaps without the
   spring.
2. **Full width, with descriptions.** Not a centered cluster: the chips are
   `flex: 1` equals across the whole header, each one an icon + title over a
   one-line description — All Time "Your lifetime leaderboard", Time Machine
   "Rewind month by month", Reconnect "Who's worth a text", Search "Find any
   message by keyword". Under 560pt the descriptions drop and the titles
   stay (the plan's icon-only fallback wasn't needed).
3. **Order is All Time · Time Machine · Reconnect · Search** — Search last,
   not third as the plan had it. ⌘1–⌘4 follow `Tab.allCases`, so they track
   the order automatically; ⌘F still jumps to Search by name.
4. **Top-3-only hierarchy, no podium.** `PodiumView` (and `RaceEntry` /
   `monthTopFive`) are deleted. `LeaderboardRow` carries the hierarchy
   instead: gold/silver/bronze gradient medal circles with the rank number
   inside, avatars 46/40/34 vs 28, names 15.5/14.5/13.5 semibold vs 12 — but
   every column is a fixed width, so the whole list still reads as a table.
   Ranks 4+ are unchanged.
5. **Gear moved to the title bar.** Settings is a bare `gearshape` in an
   `NSTitlebarAccessoryViewController` (trailing), which keeps the standard
   title-bar height and the window title centered. Nothing sits in the app
   header but the tab bar.
6. **Filter lives above its list.** The "Filter people…" field
   (`line.3.horizontal.decrease`, not a magnifier) is right-aligned directly
   above each list; on Reconnect the "Last Contact:" label + range picker sit
   inline on its left. The per-tab helper text under the tabs is gone.

The site's app recreations (hero demo, use-case slides, tab tour) were
updated to match all six: tab bar, medals, filter row, titlebar with centered
name + gear, and no podium anywhere.
