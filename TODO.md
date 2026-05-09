# niacin — TODO

A working list. Roughly grouped; order within each group is rough priority.

---

## Priorities (Richard)

### 1. Language support (localization)
All user-facing strings are English literals in Swift source. Need to:
- Wrap strings in `String(localized:)` / `LocalizedStringKey` (mostly already SwiftUI-friendly)
- Add `Localizable.xcstrings` (Xcode 15+ string catalog) and pull strings from `MenuBarView`, `SettingsView`, `ActivationDuration.displayTitle`, the policy rows, and `"Quit Niacin"`
- Pluralization for durations ("1 minute" vs "5 minutes") via `.stringsdict` rules in the catalog
- First targets to consider: en, fr, de, es, it, ja, zh-Hans (priorities depend on deployment regions)
- Note: duration formatting should ideally go through `Duration.UnitsFormatStyle` so the locale handles it for us

### 2. Better menu bar icon
Currently `cup.and.saucer` / `cup.and.saucer.fill` SF Symbols. Options:
- Custom template PNG/PDF in the asset catalogue (monochrome, auto-tints to menu bar colour)
- A pill / vitamin-capsule glyph would lean into the "niacin = vitamin B3" name
- Active state: solid fill or subtle pulse animation; inactive: outlined
- Optional: small countdown badge or timer ring while a timed session is running
- Make sure the asset is a true template image (`isTemplate = true`) so dark/light menu bars both render correctly

### 3. Capitalize "Niacin" everywhere user-facing
Audit found mixed casing. Decide on **Niacin** as the canonical proper-noun spelling, then:
- `README.md` heading and prose (currently lowercase "niacin" throughout)
- `Info.plist` `CFBundleDisplayName` / `CFBundleName` (verify in Xcode build settings — currently the target/product name is `niacin`)
- About-window app name (driven by bundle display name)
- Comments and doc-strings in source (cosmetic but consistent)
- Leave lowercase only where it is a real identifier: bundle ID `com.oldsalt.niacin`, file paths, the Swift module/product name (renaming the product is a bigger surgery — keep separate)

---

## Functional
- **Auto-update** — Sparkle 2 is the de-facto standard for macOS menu bar apps
  - Host an `appcast.xml` (GitHub Releases works fine as the backing store via a generated feed)
  - Generate an EdDSA key pair; ship the public key in `Info.plist`, keep the private key off-repo
  - Add an "Automatically check for updates" toggle in Settings, plus a "Check now" button
  - **MDM-lockable**: most managed orgs will want updates pushed via JAMF, not self-updates — add a `disableAutoUpdate` managed key (defaults to on for unmanaged installs, off-able by IT)
  - Notarize each release; Sparkle requires signed + notarized updates to apply silently
- **Global hotkey to toggle** — quick activation without opening the menu (configurable, MDM-lockable)
- **Custom user durations** — let users add their own preset alongside the defaults (still subject to `maxDurationSeconds`)
- **Auto-deactivate on battery / low battery** — common request for laptop users; trivial via `IOPSCopyPowerSourcesInfo`
- **Activate while specific apps are running** — e.g., Zoom, Teams, OBS; uses `NSWorkspace.runningApplications`
- **Schedule windows** — "always awake 09:00–17:00 on weekdays". Useful for kiosks, also MDM-controllable
- **Extend / snooze a running session** — add 15 min without deactivating first
- **Notify on auto-deactivate** — optional `UserNotification` so people aren't surprised when caffeinate ends

## Enterprise / MDM
- **Ship a sample `.mobileconfig`** alongside the example plists in the README, ready to upload to JAMF
- **Document signing & notarization** — current README doesn't cover distribution; add a section for org deployment
- **Signed-release CI workflow** — tag-triggered job that builds Release config, signs with a Developer ID Application cert, notarizes via `xcrun notarytool submit --wait`, staples with `xcrun stapler staple`, then zips with `ditto -c -k --keepParent` and uploads to the GitHub Release. Required secrets: `DEVELOPER_ID_P12` + `DEVELOPER_ID_P12_PASSWORD` for signing, and an App Store Connect API key (`APP_STORE_CONNECT_KEY_ID` / `ISSUER_ID` / `API_KEY`) for notarization. Do NOT publish unsigned builds — Gatekeeper blocks them and trains users to bypass security warnings.

## Polish & UX
- **First-launch onboarding sheet** — short explainer for non-IT users; suppressed when `activateOnLaunch` is managed
- **VoiceOver labels** on menu items and the menu bar icon — currently nothing read out for assistive tech
- **Settings window resizability / layout pass** — the fixed `width: 380, height: 340` is tight once we add localization (German strings will overflow)

## Code health
- **Crash log forwarding** — at minimum, document where `os.Logger` output lands so IT can collect it
- **Swift 6 strict-concurrency cleanup** — `PolicyWatcher.swift:31` warns that `self.onChange = onChange` loses the `@MainActor` annotation when crossing the `queue.async` boundary. Cosmetic warning today (build/notarize succeed) but will be a hard error when the project flips to Swift 6 language mode. Fix: annotate the `onChange` storage and the `start(onChange:)` parameter as `@Sendable @MainActor` so the types match exactly across the dispatch boundary.
