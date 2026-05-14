# Releasing Niacin

Niacin ships two distinct builds from the same target:

| Build              | Configuration | Channel                              | Sandbox | Update mechanism                  |
| ------------------ | ------------- | ------------------------------------ | ------- | --------------------------------- |
| **Niacin Enterprise** | `Release`     | Direct download (.dmg / .pkg) via GitHub Releases | Off     | None — IT pushes via MDM         |
| **Niacin** (MAS)     | `Release-MAS` | Mac App Store                        | On      | Automatic, via the App Store     |

Pick the relevant section below.

---

## Enterprise build

The Enterprise build is for IT-managed fleets. No auto-update, no sandbox, full process-watcher (Tier 3) detection. The `scripts/release.sh` runbook produces signed + notarized `.dmg` and `.pkg` artifacts ready to attach to a GitHub Release.

### One-time setup

Re-run after macOS reinstalls or DerivedData wipes:

1. **Developer ID certs in Keychain.** `security find-identity -v | grep "Developer ID"` should show both `Developer ID Application: …` and `Developer ID Installer: …`. Add via Xcode → Settings → Accounts → Manage Certificates.
2. **Notarization profile.** `xcrun notarytool store-credentials niacin-notary --apple-id YOUR_APPLE_ID --team-id 346JJCHZP7` — prompts for an app-specific password (generate at appleid.apple.com → Sign-In & Security → App-Specific Passwords).

### Per-release workflow

1. **Bump version.** Edit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `niacin.xcodeproj/project.pbxproj` (each appears six times — search-and-replace both numbers). Commit:
   ```
   git commit -am "Bump version to X.Y (build N)"
   ```

2. **Build, sign, notarize, package.** From the repo root:
   ```
   ./scripts/release.sh X.Y
   ```
   Takes 3–15 minutes — two notarization rounds (`.app`, `.dmg`, `.pkg`). The script verifies the version arg matches `MARKETING_VERSION`, so it'll bail loudly if you forgot step 1.

3. **Tag and publish to GitHub.** The script prints the exact commands; copy-paste:
   ```
   git tag -a vX.Y -m "Niacin Enterprise X.Y"
   git push origin vX.Y
   gh release create vX.Y \
       --title "Niacin Enterprise X.Y" \
       --generate-notes \
       build/release/artifacts/niacin-X.Y.dmg \
       build/release/artifacts/niacin-X.Y.pkg \
       build/release/artifacts/SHA256SUMS
   ```

### Failure modes

| Symptom | Likely cause |
|---|---|
| Notarization rejected on `.app` | `xcrun notarytool log <SUBMISSION_ID> --keychain-profile niacin-notary` for the actual reason — usually a missing Hardened Runtime flag or a bad entitlement. |
| `pkgbuild` complains about identifier | The `.pkg` identifier needs to be unique per release — the script derives it from `APP_BUNDLE_ID`. |
| Gatekeeper rejects the stapled artifact | The `.app` was modified after stapling. Re-archive from scratch. |

---

## Mac App Store build

The MAS build is for individual users discovering Niacin via the App Store. Sandboxed, no process-watcher, AI runtime detection via Tier 2 probes only, plus the MCP server for agent-driven keep-awake. Distribution is through App Store Connect — there is no command-line release script.

### One-time setup

1. **App Store Connect record** for bundle ID `com.oldsalt.niacin.mas` (separate from the Enterprise `com.oldsalt.niacin`). Set the App Information → Subtitle without using Apple trademarks: e.g. **"Keep your computer awake."** (≤30 chars). Do **not** use "Mac" or "macOS" in the subtitle — it triggers 5.2.5 IP rejections.
2. **Apple Distribution cert** in Keychain — Xcode → Settings → Accounts → Manage Certificates → +.
3. **Provisioning profile** auto-managed by Xcode (target signing → "Automatically manage signing", team 346JJCHZP7).

### Per-release workflow

1. **Bump version** (same as Enterprise — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`).
2. **Archive in Xcode.** Product → Scheme → Edit Scheme → Archive → choose **Release-MAS** configuration. Then Product → Archive.
3. **Distribute App** from the Organizer window:
   - Distribution method: App Store Connect
   - Upload (not Export) — Xcode validates the signature, sandbox entitlements, and uploads to App Store Connect.
4. In App Store Connect, attach the new build to a version, fill in release notes, submit for review.

### Common review snags

- **5.2.5 (Apple trademarks)** — anything in the subtitle/keywords/screenshots that uses "Mac", "macOS", "App Store", "AirDrop", etc. as a product modifier. Use generic terms.
- **2.5.1 (private APIs)** — usually a false positive from a transitive symbol; appeal with a reasoned explanation.
- **`network.server` entitlement scrutiny** — first MAS submission of v2.1 may prompt the reviewer to ask "why does a keep-awake utility need a server?" Reply in the Resolution Center: "Niacin runs a localhost-only MCP endpoint (bound to 127.0.0.1) so AI agents can request keep-awake assertions via the Model Context Protocol. All requests require a bearer token generated by the user in Settings. No network traffic leaves the device."

### Coexistence with the Enterprise build

The two builds use different bundle IDs (`com.oldsalt.niacin` vs `com.oldsalt.niacin.mas`) so they can be installed side-by-side on a developer's machine without conflict. Each has its own UserDefaults / Keychain entries / managed-prefs domain.

If a user installs both, both will hold IOPMAssertions independently. Either build alone is enough to keep the system awake.
