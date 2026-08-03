# Auto-update plan (Sparkle)

Add in-app automatic updates to Besties so buyers get new versions without re-downloading from besties.gg.

**Recommendation: Sparkle 2** (via Swift Package Manager). It is the standard for Developer-ID Mac apps outside the App Store: battle-tested, EdDSA-signed updates, works with our notarized builds, no server code needed — just static files on Vercel.

**Total effort: ~half a day** (1–2h app integration, 1–2h release pipeline, 1h deploy + end-to-end test).

---

## Current state (what the plan builds on)

- No SPM dependencies in the project yet; Sparkle is the first.
- App is **not sandboxed** (`com.apple.security.app-sandbox = false`) — this is the easy path for Sparkle; no XPC service exclusions or extra entitlements needed.
- Version is hardcoded: `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`. Sparkle compares `CFBundleVersion`, so versions must actually be bumped per release.
- `release.sh` builds, signs (Developer ID, runtime hardened), notarizes, staples, and produces `Besties.zip`. The DMG is built separately.
- Site deploys from this machine via `vercel deploy` (never Git); `site/dl/` is gitignored because the repo is public. Update files follow the same pattern.

## Architecture

```
App (Sparkle SPUStandardUpdaterController)
  └─ polls https://besties.gg/u-<hex>/appcast.xml   (unguessable dir, baked into Info.plist)
       └─ appcast entry points at  https://besties.gg/u-<hex>/Besties-1.1.zip
            └─ EdDSA-signed; Sparkle verifies signature + Apple code signature, swaps the app, relaunches
```

- **First install stays the DMG** behind the Stripe check — unchanged.
- **Updates are ZIPs** served from a new `site/updates/` dir (deployed at `/u-<hex>/`). ZIP, not DMG: it's Sparkle's default, supports delta updates later, and skips DMG staging per release.
- No license system exists in the app, so the appcast URL is protection-by-obscurity, same threat model as today's secret DMG path. Anyone who extracts the URL from the binary can fetch updates; acceptable for now. (Real fix later = license keys, out of scope.)

## Steps

### 1. One-time key setup (5 min)
1. Add Sparkle SPM package to the Xcode project (`https://github.com/sparkle-project/Sparkle`, from: 2.0.0).
2. Run Sparkle's `generate_keys` (in the SPM artifacts under `~/Library/Developer/Xcode/DerivedData/.../Sparkle/bin/`, or `brew install --cask sparkle` for the tools). It stores the **private EdDSA key in the login Keychain** and prints the public key.
3. **Back up the private key** (`generate_keys -x private-key-file`) somewhere safe (1Password). Losing it means shipped apps can never update again.

### 2. App integration (~1–2h)
1. The project uses a generated Info.plist, and Sparkle needs two custom keys. Add an `Info.plist` file to the target (Xcode merges it with the generated one) containing:
   - `SUFeedURL` = `https://besties.gg/u-<hex>/appcast.xml` (generate the hex once: `openssl rand -hex 8`)
   - `SUPublicEDKey` = public key from step 1
2. In `BestiesApp.swift`: create one `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` and add a `CommandGroup(after: .appInfo)` menu item "Check for Updates…" calling `updaterController.checkForUpdates(nil)` (disabled state driven by `updater.canCheckForUpdates`).
3. Defaults are right for us: automatic background checks daily, user prompted before install. `SUEnableAutomaticChecks` prompt appears on second launch — leave it.
4. Verify: build Release locally, confirm the Sparkle.framework is embedded and signed, `codesign -dv --verbose` shows no issues, app launches and the menu item exists.

### 3. Release pipeline (`release.sh`) (~1–2h)
1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` per release — add a version argument to `release.sh` (`./release.sh 1.1 [profile]`) that sets both via `xcodebuild ... MARKETING_VERSION=$V CURRENT_PROJECT_VERSION=$N` or `agvtool`.
2. Sparkle's XPC services inside the framework must survive our re-sign step. Re-sign **deep-first**: sign the nested Sparkle components (`Autoupdate`, `Updater.app`, XPC services) before the outer app, or use `codesign --force --deep` only if verification passes notarization (Sparkle's docs recommend explicit nested signing; test once — if the Xcode-produced signatures are already valid, only the outer re-sign is needed).
3. After stapling, copy the zip to `site/updates/Besties-<version>.zip`, then run Sparkle's `generate_appcast site/updates/` — it EdDSA-signs every zip (private key from Keychain) and writes `appcast.xml` with version numbers read from the zips. Keep the previous 1–2 zips in the dir so `generate_appcast` can emit **delta updates** for free.
4. Add `site/updates/` to `.gitignore` (repo is public; same rule as `site/dl/`).
5. Add release notes: `generate_appcast` picks up `Besties-<version>.html` files alongside the zips, or embed `<description>` — start with a one-line HTML file per release.

### 4. Site/deploy wiring (~30 min)
1. Map `site/updates/` → `/u-<hex>/` in the deploy: either name the dir `site/u-<hex>/` directly (simplest, matches how `dl/` works) or add a Vercel rewrite. **Simplest: just name the dir `site/u-<hex>/`.**
2. Confirm `build.sh` doesn't touch or delete the dir, and the appcast URL serves with `Content-Type: application/xml` (Vercel does this by default for `.xml`).
3. Deploy: `cd site && ./build.sh && vercel deploy --prod --yes` — unchanged.

### 5. End-to-end test (~1h)
1. Build 1.1 with the pipeline, deploy the appcast.
2. Install the current 1.0 DMG into /Applications, launch, "Check for Updates…" → should offer 1.1, install, relaunch.
3. Verify Gatekeeper is happy post-update (`spctl -a -vvv /Applications/Besties.app`) and Full Disk Access survives the swap (it should — FDA is keyed to the bundle id, and Sparkle replaces the bundle in place).
4. Also test the background/automatic check path by setting the check interval low temporarily, then restore.

## Gotchas / decisions made

- **FDA persistence**: TCC grants (Full Disk Access, Contacts) are tied to bundle id + code signing identity, both unchanged across updates — grants persist. Worth confirming in the e2e test since the whole app depends on FDA.
- **First release with Sparkle can't auto-update itself in**: everyone on today's 1.0 must re-download once (or be emailed the new DMG). All buyers so far came through Stripe; the thanks-page link re-serves the latest DMG for any paid session.
- **DMG for updates**: rejected — Sparkle supports it but ZIP is the default, enables deltas, and avoids re-staging Finder layout per release.
- **Anonymous system-profile reporting**: off (Sparkle default). No new privacy surface.
- **Sandboxing**: if the app ever gets sandboxed, Sparkle needs XPC service tweaks — revisit then.
- **Key custody**: the EdDSA private key lives only in this Mac's Keychain + the 1Password backup. `generate_appcast` must run on this machine (fine — deploys already must).

## Out of scope

- License keys / real update authorization
- Channels (beta), phased rollout
- Windows/website changes beyond the updates dir
