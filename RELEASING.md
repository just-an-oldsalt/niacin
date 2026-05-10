# Releasing Niacin

End-to-end runbook for cutting a new signed, notarized release with Sparkle auto-update support.

## One-time setup

You need this once per machine. Re-run if you reinstall macOS or wipe DerivedData.

1. **Developer ID certs in Keychain.** `security find-identity -v | grep "Developer ID"` should show both `Developer ID Application: …` and `Developer ID Installer: …`. Add via Xcode → Settings → Accounts → Manage Certificates.
2. **Notarization profile.** `xcrun notarytool store-credentials niacin-notary --apple-id YOUR_APPLE_ID --team-id 346JJCHZP7` — prompts for an app-specific password (generate at appleid.apple.com → Sign-In & Security → App-Specific Passwords).
3. **Sparkle EdDSA private key.** Already in your login Keychain from when Sparkle was added. The public counterpart is baked into the project as `INFOPLIST_KEY_SUPublicEDKey`. To re-derive: build the project, then run `find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*Sparkle*' -exec {} \;`. Don't regenerate unless you intend to invalidate every shipped copy.

## Per-release workflow

1. **Bump version.** Edit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `niacin.xcodeproj/project.pbxproj` (both appear six times — use search-and-replace for both numbers). Commit:
   ```
   git commit -am "Bump version to X.Y (build N)"
   ```

2. **Build, sign, notarize, package.** From the repo root:
   ```
   ./scripts/release.sh X.Y
   ```
   Takes 5–25 minutes — three notarization rounds (`.app`, `.dmg`, `.pkg`) and a Sparkle `.zip` build. The script verifies the version arg matches `MARKETING_VERSION`, so it'll bail loudly if you forgot step 1.

3. **Update the appcast.** The script's final summary prints an `<item>` block ready to paste. Open `appcast.xml`, paste it as the **first** `<item>` inside `<channel>` (newest at top), commit:
   ```
   git commit -am "appcast: vX.Y"
   ```

4. **Upload appcast to niacin.dort.zone.** Replace the old `appcast.xml` on the site. Sparkle clients poll this URL for updates:
   ```
   scp appcast.xml niacin.dort.zone:/path/to/site/appcast.xml
   ```
   (Adjust path to wherever the site is hosted. Cache headers should not be longer than ~1 hour or new releases won't propagate.)

5. **Tag and publish to GitHub.** The script prints the exact commands; copy-paste:
   ```
   git tag -a vX.Y -m "Niacin X.Y"
   git push origin vX.Y
   gh release create vX.Y \
       --title "Niacin X.Y" \
       --generate-notes \
       build/release/artifacts/niacin-X.Y.dmg \
       build/release/artifacts/niacin-X.Y.pkg \
       build/release/artifacts/niacin-X.Y.zip \
       build/release/artifacts/SHA256SUMS
   ```

6. **Verify.** On a Mac running the previous version, open Niacin → menu → "Check for Updates…". Sparkle should detect the new version, download the `.zip`, verify the EdDSA signature, prompt to install, and relaunch.

## Failure modes

| Symptom | Likely cause |
|---|---|
| Sparkle reports "no update available" but the version is higher in appcast | Cache header on `appcast.xml` is too long, OR Sparkle is hitting the wrong URL — check `defaults read com.oldsalt.niacin SUFeedURL` |
| Sparkle reports "signature mismatch" | EdDSA private key on this machine differs from the one whose public key is in `Info.plist`. Either regenerate everything (and invalidate prior installs) or restore the original private key from a backup. |
| `sign_update` not found in the release script | Build the project once in Xcode after a clean / DerivedData wipe so SPM resolves Sparkle. |
| Notarization rejected on `.app` | `xcrun notarytool log <SUBMISSION_ID> --keychain-profile niacin-notary` for the actual reason — usually a missing Hardened Runtime flag or a bad entitlement. |
| `.pkg` won't auto-update existing v1.x installs | Existing v1.x has no Sparkle in it; users on v1.x must update manually once. From v1.3 onward (the first Sparkle release), updates are automatic. |
