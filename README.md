# ☕ Niacin

**[niacin.dort.zone](https://niacin.dort.zone/) · A macOS menu bar utility that keeps your computer awake — for the enterprise, and for AI agents.**

Niacin prevents your computer from sleeping on demand, with fine-grained control over what stays awake: the system, the display, or both. Every setting can be locked and enforced by IT via a JAMF (or any MDM) managed preferences plist. AI agents that speak the Model Context Protocol can drive Niacin directly via a localhost-only MCP endpoint.

Niacin ships in two flavours from the same codebase:

- **Niacin Enterprise** (this repo's GitHub Releases) — for IT-managed fleets. Distributed as `.dmg` / `.pkg`, no sandbox, no auto-update (IT pushes via MDM). Adds the IT-only process-watcher signals (`forceActiveDuringDeploys`, `forceActiveDuringApps`) on top of the shared MCP server.
- **Niacin** (Mac App Store) — for individual users. Sandboxed, App-Store-updated. AI integration is handled exclusively via the MCP server — there is no inference of AI activity from process names or CPU; agents declare keep-awake intent directly.

Both builds share the MCP server.

---

## Features

- **Menu bar first** — lives in your menu bar, no Dock icon, no clutter
- **Flexible sleep control** — choose between full awake, system-only awake, or lock prevention per activation
- **Timed activations** — activate for 5 minutes up to indefinitely, or set a hard cap via policy
- **AI-agent native** — local MCP server lets Claude Desktop, Claude Code, Cursor, and other MCP clients request keep-awake assertions directly via the `keep_awake` tool, with bearer-token auth
- **Enterprise-ready** — every setting manageable via a single MDM plist
- **Lock indicators** — settings controlled by IT show a 🔒 icon; users can't override them
- **Managed policy section** — settings window surfaces active IT constraints clearly

---

## How it works

Niacin holds IOKit power assertions (`IOPMAssertionCreateWithName`) directly — no spawned `caffeinate` children, no kernel extensions, no background daemons. Assertions release automatically if the process dies, so a crash or forced quit can't leak a stuck "stay awake" state.

| Mode | Assertion type | Effect |
|---|---|---|
| Full awake | `PreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep` | System and display stay on |
| System awake only | `PreventUserIdleSystemSleep` | System stays awake; display can sleep and lock |
| Timed activation | (above, plus an internal timer) | Niacin releases the assertion at the deadline |

Force-active assertions (driven by ProcessWatcher / probes / MCP) are held separately from user-session assertions, so a user-initiated session can end without dropping a deploy-in-progress hold.

---

## Requirements

- macOS 14 Sonoma or later
- No additional dependencies

---

## Installation

### Build from source

1. Clone the repo
2. Open `niacin.xcodeproj` in Xcode
3. Set your development team in **Signing & Capabilities**
4. Build and run (`⌘R`)

> **Note:** To suppress the Dock icon, add `Application is agent (UIElement)` = `YES` to the target's Info.plist properties in Xcode.

---

## MDM / JAMF Configuration

Niacin reads managed preferences automatically from:

```
/Library/Managed Preferences/com.oldsalt.niacin.plist
```

Any key present in the managed domain overrides the user's preference and locks the corresponding UI control. Keys that are absent remain fully user-controlled.

### All managed keys

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master kill switch — set `false` to disable the app entirely |
| `activateOnLaunch` | Bool | `false` | Force activation every time the app launches |
| `allowIndefinite` | Bool | `true` | Permit indefinite (no timeout) activations |
| `allowUserToDisable` | Bool | `true` | Whether the user can manually deactivate |
| `disableQuit` | Bool | `false` | Remove Quit from the menu bar menu |
| `allowDisplaySleep` | Bool | *(user)* | Lock the "Allow screen to sleep" toggle |
| `preventDeviceLock` | Bool | *(user)* | Lock the "Prevent device from locking" toggle |
| `deactivateOnUserSwitch` | Bool | *(user)* | Deactivate automatically on fast user switch |
| `maxDurationSeconds` | Integer | *(none)* | Hard cap on any single activation (seconds) |
| `allowedDurations` | Array of Integer | *(defaults)* | Override the available duration list entirely |
| `forceActiveDuringDeploys` | Array of String | *(empty)* | (Enterprise only.) Process-name patterns that, when matched against a running process, force Niacin awake silently. Designed for IT-deploy daemons (`jamf`, `installd`, `softwareupdated`, `munki`, `IntuneMdmAgent`, `mdmclient`, `Installer`) — the device won't sleep mid-deploy even if the user is away. Polled every 5 seconds. Names are case-insensitive substring matches against `kinfo_proc.p_comm`, kernel-limited to 16 chars. The MAS build has no process-watcher; this key is ignored there. |
| `forceActiveDuringApps` | Array of String | *(empty)* | (Enterprise only.) Same shape as `forceActiveDuringDeploys` but for general apps (`zoom.us`, `OBS`, `obs-studio`, etc.). Force-activates while any matching process is running. |
| `mcpServerEnabled` | Bool | `false` | Enable the local MCP (Model Context Protocol) server. When `true`: Niacin binds an HTTP listener on `127.0.0.1` (port 11473 by default) so paired AI agents — Claude Desktop, Claude Code, Cursor — can call the `keep_awake`, `release_awake`, and `status` tools via bearer-token-authenticated JSON-RPC. The token is user-generated in Settings and stored in Keychain. No external traffic. |

### Example plist

A typical enterprise deployment that keeps the system awake but enforces screen lock policy, with a maximum session of 4 hours:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

    <!-- App is enabled for use -->
    <key>enabled</key>
    <true/>

    <!-- Users can turn it off, but it activates automatically on launch -->
    <key>activateOnLaunch</key>
    <true/>
    <key>allowUserToDisable</key>
    <true/>

    <!-- Screen must be able to sleep — honours company lock screen policy -->
    <key>allowDisplaySleep</key>
    <true/>

    <!-- Device lock prevention is not permitted -->
    <key>preventDeviceLock</key>
    <false/>

    <!-- Always deactivate when the user switches account -->
    <key>deactivateOnUserSwitch</key>
    <true/>

    <!-- Maximum single activation: 4 hours -->
    <key>maxDurationSeconds</key>
    <integer>14400</integer>

    <!-- Available durations: 15 min, 30 min, 1 hr, 2 hr, 4 hr -->
    <key>allowedDurations</key>
    <array>
        <integer>900</integer>
        <integer>1800</integer>
        <integer>3600</integer>
        <integer>7200</integer>
        <integer>14400</integer>
    </array>

    <!-- Indefinite activation not permitted -->
    <key>allowIndefinite</key>
    <false/>

</dict>
</plist>
```

### Kiosk / display mode example

Lock a device fully awake with no user control:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>enabled</key>
    <true/>
    <key>activateOnLaunch</key>
    <true/>
    <key>allowUserToDisable</key>
    <false/>
    <key>disableQuit</key>
    <true/>
    <key>allowDisplaySleep</key>
    <false/>
    <key>preventDeviceLock</key>
    <true/>
    <key>allowIndefinite</key>
    <true/>
    <key>allowedDurations</key>
    <array>
        <integer>0</integer>
    </array>
</dict>
</plist>
```

### Deploying with JAMF

1. In JAMF Pro, navigate to **Computers → Configuration Profiles**
2. Add a new profile and select **Application & Custom Settings**
3. Set the preference domain to `com.oldsalt.niacin`
4. Upload your plist or enter the keys manually
5. Scope the profile to your target computers or groups

macOS will write the plist to `/Library/Managed Preferences/` and Niacin will pick it up on next launch without any restart required for most keys.

---

## For IT admins

If your job is to keep a fleet of Macs awake during overnight deploys, the Enterprise build provides three force-activation signals that hold IOKit assertions independently of any user session:

- **`forceActiveDuringDeploys`** — Niacin silently keeps the device awake while any of your configured deploy daemons are running (`jamf`, `installd`, `softwareupdated`, `munki`, `IntuneMdmAgent`, `mdmclient`, `Installer`). No menu bar flicker, no user prompt — the user wakes up to a finished deploy instead of a half-applied update. (Enterprise only — the MAS build's sandbox can't enumerate other processes.)
- **`forceActiveDuringApps`** — same shape for any user-facing app where sleep-during-use is unacceptable (Zoom, Teams, OBS, custom internal tools). (Enterprise only.)
- **`mcpServerEnabled`** — exposes a localhost MCP endpoint so AI agents can request keep-awake assertions explicitly. More accurate than any heuristic: the agent declares intent rather than the watcher inferring it from CPU/process state.

macOS composes the assertions, so a deploy continues even after the user has manually deactivated for the night.

### Sample Configuration Profile

A ready-to-customise `.mobileconfig` is in [`examples/niacin.mobileconfig`](examples/niacin.mobileconfig). It includes all the force-active keys plus the standard enterprise lockdown (`maxDurationSeconds`, `allowIndefinite=false`, etc.). Before pushing:

1. Replace the three `PayloadUUID` values with fresh ones from `uuidgen`
2. Replace `YOUR-ORG` in `PayloadOrganization` with your org name
3. Sign the profile with your MDM's signing certificate (`security cms -S` or via JAMF/Kandji/Mosyle's signing UI)
4. Upload to your MDM and scope to the appropriate computer group

### Auditing

Every force-active event is logged to the unified log under `subsystem=="com.oldsalt.niacin" category=="audit"`. From a managed device:

```sh
sudo log show --predicate 'subsystem=="com.oldsalt.niacin" AND category=="audit"' --info --last 24h
```

Expect lines like `force-active begin: reason=deploy matches=["jamf"]` and `force-active end: reason=deploy`. SIEM agents can ingest the unified log directly (CrowdStrike Falcon, Splunk, etc.) — see [Retention and SIEM integration](#retention-and-siem-integration).

### Live policy reload

Profile pushes take effect within ~200 ms without restarting the app — Niacin watches `/Library/Managed Preferences/` via kqueue. You don't need a `launchctl kickstart` or a logout cycle to apply a JAMF profile push.

---

## Automation

Niacin registers a `niacin://` URL scheme. Any tool that can `open` a URL (the shell, Shortcuts, Calendar reminders, Stream Deck, webhooks, Hammerspoon) can drive activation and deactivation without scripting against the menu UI.

### URL scheme

```sh
# Activate indefinitely
open "niacin://activate"

# Activate for 30 minutes (1800 seconds)
open "niacin://activate?duration=1800"

# Activate indefinitely (explicit)
open "niacin://activate?duration=indefinite"

# Deactivate the current session
open "niacin://deactivate"
```

URL-driven activations honour every managed-preferences guard (`enabled`, `allowIndefinite`, `maxDurationSeconds`, etc.) — IT-managed installs can lock down what URL-scheme callers are allowed to do, same as the menu UI.

### `niacin run -- <command>`

Convenience wrapper that activates Niacin for the duration of a command and deactivates when it exits — clean, errored, or Ctrl+C'd:

```sh
niacin run -- make build
niacin run -- xcodebuild test -scheme MyApp
niacin run -- bash -c 'sleep 3600 && say "done"'
```

Install the wrapper into your `$PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/just-an-oldsalt/niacin/main/scripts/niacin -o /usr/local/bin/niacin
chmod +x /usr/local/bin/niacin
```

The wrapper currently only supports the `run` subcommand. A full Swift CLI (`niacin status`, `niacin activate 30m`, `niacin watch <pid>`) is planned for v2.1; the `run` shape will stay stable so existing scripts continue to work.

---

## Logging & Diagnostics

Niacin logs all state-changing events and diagnostic information to macOS's unified logging system via Swift's `os.Logger` under the subsystem `com.oldsalt.niacin`. IT admins can extract, filter, and analyze these logs for troubleshooting, compliance audits, and fleet monitoring.

### Quick extraction

To dump the last hour of Niacin logs for a support ticket:

```
log show --predicate 'subsystem == "com.oldsalt.niacin"' --info --last 1h
```

Include `--debug` to also capture debug-level tracing (normally suppressed):

```
log show --predicate 'subsystem == "com.oldsalt.niacin"' --info --debug --last 1h
```

### Live tailing

For active troubleshooting, watch logs in real time:

```
log stream --predicate 'subsystem == "com.oldsalt.niacin"' --info
```

### Filter by category

Each log message belongs to a category. To view only policy events over the last 24 hours:

```
log show --predicate 'subsystem == "com.oldsalt.niacin" && category == "policy"' --info --last 24h
```

### Fleet collection and archival

Use `log collect` to capture a timestamped archive that can be transferred for central analysis:

```
log collect --last 7d --output /tmp/niacin-diag.logarchive
```

Then open the archive on another machine with:

```
log show --archive /tmp/niacin-diag.logarchive --predicate 'subsystem == "com.oldsalt.niacin"'
```

### Log categories

| Category | Contains | Useful for |
|---|---|---|
| `policy` | activate/deactivate events, policy enforcement decisions, policy-blocked actions, session termination reasons | audit trail, verifying policy enforcement |
| `policy-watcher` | file system events on managed plist paths, live-reload notifications | confirming policy pushes are reaching the device |
| `managed-prefs` | managed-preference key reads, parse errors | diagnosing malformed .mobileconfig or unexpected key values |
| `sleep-preventer` | IOKit assertion lifecycle (acquired/released), IOReturn error codes | confirming sleep-prevention engine is operational |

### Retention and SIEM integration

macOS retains unified log output for approximately 7 days by default. For longer retention, use `log collect` to create persistent archives, or configure a SIEM agent (CrowdStrike Falcon, Splunk, etc.) to ingest the unified log directly. SIEM forwarding is not managed by Niacin itself.

---

## Updates

**Niacin Enterprise** has no self-update. IT pushes new versions via MDM as `.pkg` files. The build does not phone home for update checks.

**Niacin** (Mac App Store) updates through the App Store's standard mechanism. No code in Niacin contacts an update server.

---

## AI agent integration (MCP)

Enable the MCP server in **Settings → AI Agent Integration**. Niacin will:

1. Bind a localhost-only HTTP listener (default port `11473`, falls back through `11479` if the default is taken).
2. Generate a bearer token shown once after creation, then stored in Keychain.
3. Surface a **Copy Config Snippet** button that produces a paste-ready JSON block for MCP clients.

The snippet has the shape MCP-over-HTTP clients expect:

```json
{
  "mcpServers": {
    "niacin": {
      "url": "http://127.0.0.1:11473",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

### Exposed tools

| Tool | Arguments | Effect |
|---|---|---|
| `keep_awake` | `duration_seconds?` (int), `reason` (string), `allow_display_sleep?` (bool), `client?` (string) | Holds a power assertion. Returns `session_id` and `expires_at`. |
| `release_awake` | `session_id?` (string) | Releases one session, or all MCP-owned sessions if omitted. |
| `status` | — | Reports current keep-awake state and the labels of all sources holding assertions. |

Every call is logged under `subsystem="com.oldsalt.niacin" category="audit"` with the calling client's self-reported name (when supplied) and the reason text. Sessions self-release at their declared duration via a wall-clock task that survives system sleep.

---

## Settings window

The settings window reflects the current policy state:

- Toggles under IT control show a **lock icon** and cannot be changed
- The **Managed by Organisation** section appears automatically when any policy is active, listing all enforced constraints

---

## Acknowledgements

Inspired by [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) by Marcel Dierkes.

---

## License

MIT
