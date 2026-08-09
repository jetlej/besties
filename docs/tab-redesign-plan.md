# Chunky Tab Bar — Plan

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
