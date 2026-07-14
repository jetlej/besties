# Besties — project rules

Mac app (SwiftUI) that reads local iMessage/WhatsApp history + marketing site.
Product name is **Besties** (site: https://besties.gg). Bundle id `com.besties.app` — never change it (Full Disk Access is keyed to it).

## Deploying the website

- **Always use `/opt/homebrew/bin/vercel`** (v55+, logged in as `jetlej`, team `lej`, project `besties`). Other vercel binaries on PATH (e.g. nvm's node16 one) are stale and fail with token errors — do not use `vercel` bare, do not run `vercel login` when a "logged out" error appears; it's the wrong binary.
- Site source lives in `site/src/*.html` templates + `site/build.sh` (which holds `APP_NAME` — the single place the product name is defined). **Never edit `site/index.html` or `site/thanks.html` directly**; they are generated.
- Deploy = `cd site && ./build.sh && /opt/homebrew/bin/vercel deploy --prod --yes`
- **Do NOT connect the Vercel project to Git / auto-deploy.** Deploys must come from this machine: `site/dl/` (gitignored — the repo is public) holds the paid, notarized `Besties-<hex>.dmg` that buyers download. A Git-based deploy would ship without it and break all download links.

## Purchase / download flow

- Stripe Payment Link (live) on the Buy buttons → after payment Stripe redirects to `besties.gg/thanks.html?session_id=…` → `site/api/download.js` verifies the session (`paid` or `no_payment_required` for the 100%-off `BESTIE` friends code) → 302 to the DMG at a secret path.
- Vercel production env vars: `STRIPE_SECRET_KEY` (live), `DOWNLOAD_PATH` (current secret DMG path). When shipping a new DMG: put it at `site/dl/Besties-$(openssl rand -hex 8).dmg` (delete the old one), update `DOWNLOAD_PATH` via `vercel env rm/add`, redeploy.
- Stripe keys are never committed; ask the user if a key is needed.

## Releasing the app

- `./release.sh` — builds Release, signs (Developer ID, team 34HCA7L7PV, source entitlements — never the build .xcent), notarizes via keychain profile `SPEED_NOTARY`, staples, produces `Besties.zip` at repo root.
- DMG: stage stapled `Besties.app` + `/Applications` symlink, add `.background/bg.png` + `.VolumeIcon.icns`, set Finder layout via osascript, convert UDZO, codesign, notarize + staple the DMG itself. (Past scripts/assets live in the session scratchpad; the bg is the tan "Drag to install" art.)
- `Besties.zip` / `Besties.dmg` at repo root are build artifacts — never commit them.

## Design

- Follow the `scannable-design` skill for anything user-facing.
- Brand tokens (site and app must stay identical): paper `#FDF8EE`, ink `#211E1A`, sun `#FFC53D`, bubble tan `#EFEAE0`, blue `#0A7CFF`. App colors live in `BestiesApp.swift`; the app reads its display name from the bundle (`appName`), so renames happen only via `PRODUCT_NAME` + `site/build.sh`.
