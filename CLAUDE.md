# Besties — project rules

Mac app (SwiftUI) that reads local iMessage/WhatsApp history + marketing site.
Product name is **Besties** (site: https://besties.gg). Bundle id `com.besties.app` — never change it (Full Disk Access is keyed to it).

## Deploying the website

- Deploy with the `vercel` CLI (v55+, logged in as `jetlej`, team `lej`, project `besties`). The only install is `/opt/homebrew/bin/vercel` — duplicate stale copies were removed 2026-07-14. If a "logged out"/token error ever appears, check `which -a vercel` for a stale shadow copy before re-authenticating.
- Site source lives in `site/src/*.html` templates + `site/build.sh` (which holds `APP_NAME` — the single place the product name is defined). **Never edit `site/index.html` or `site/thanks.html` directly**; they are generated.
- Deploy = `cd site && ./build.sh && /opt/homebrew/bin/vercel deploy --prod --yes`
- **Do NOT connect the Vercel project to Git / auto-deploy.** Deploys must come from this machine: `site/dl/` (gitignored — the repo is public) holds the paid, notarized `Besties-<hex>.dmg` that buyers download. A Git-based deploy would ship without it and break all download links.

## Purchase / download flow

- Stripe Payment Link (live) on the Buy buttons → after payment Stripe redirects to `besties.gg/thanks.html?session_id=…` → `site/api/download.js` verifies the session (`paid` or `no_payment_required` for the 100%-off `BESTIE` friends code) → 302 to the DMG at a secret path.
- Vercel production env vars: `STRIPE_SECRET_KEY` (live), `DOWNLOAD_PATH` (current secret DMG path). When shipping a new DMG: put it at `site/dl/Besties-$(openssl rand -hex 8).dmg` (delete the old one), update `DOWNLOAD_PATH` via `vercel env rm/add`, redeploy.
- Stripe keys are never committed; ask the user if a key is needed.

## Releasing a new app version

1. Write `docs/release-notes/<version>.html` first — an HTML fragment (no doctype/body) shown in Sparkle's update prompt. `release.sh` warns and continues without it, but then the update ships with an empty "what's new" pane.
2. `./release.sh <major.minor[.patch]> [profile]` (e.g. `./release.sh 1.3`) — version needs ≥2 components, each ≤ 99 (build number = major·10000 + minor·100 + patch; Sparkle compares it, so it must always increase — the static versions in the pbxproj are overridden at build time). The script: builds Release, deep-signs Sparkle's nested helpers then the app (Developer ID, team 34HCA7L7PV, source entitlements — never the build .xcent), notarizes via keychain profile `SPEED_NOTARY`, staples, produces `Besties.zip` at repo root, stages the zip + notes into `site/u-a0941b9884e8fcb0/` (gitignored) and regenerates `appcast.xml` there — EdDSA-signed with the private key in the login Keychain (backup in 1Password; if that key is lost, shipped apps can never update again, so releases must run on this machine). Delta updates are generated automatically; `--auto-prune-update-files` cleans out superseded zips.
3. Deploy the site (see above) — that publishes the update. Existing users get it via the app's "Check for Updates…" menu item or Sparkle's daily background check.
4. New-buyer DMG — only needed when fresh installs should start on the new version (existing users auto-update regardless): mount the current `site/dl/*.dmg` and copy its `.DS_Store` + `.background/` into a staging dir (they carry the Finder layout and the tan "Drag to install" art — no osascript needed, and there is no `.VolumeIcon.icns`), add an `/Applications` symlink + the new stapled `Besties.app` unzipped from `Besties.zip`, then `hdiutil create -volname Besties -fs "HFS+" -srcfolder <stage> -format UDZO`, codesign the DMG, notarize + staple the DMG itself, and follow the `DOWNLOAD_PATH` rotation in "Purchase / download flow".

- Sparkle config lives in `Besties/Besties/Info.plist` (`SUFeedURL`, `SUPublicEDKey` — merged into the generated Info.plist at build). Sparkle is pinned via the committed `Package.resolved`.
- `Besties.zip` / `Besties.dmg` at repo root are build artifacts — never commit them.

## Design

- Follow the `scannable-design` skill for anything user-facing.
- Brand tokens (site and app must stay identical): paper `#FDF8EE`, ink `#211E1A`, sun `#FFC53D`, bubble tan `#EFEAE0`, blue `#0A7CFF`. App colors live in `BestiesApp.swift`; the app reads its display name from the bundle (`appName`), so renames happen only via `PRODUCT_NAME` + `site/build.sh`.
