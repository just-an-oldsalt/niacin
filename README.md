# ☕ Niacin

**[niacin.dort.zone](https://niacin.dort.zone/) · A macOS menu bar utility that keeps your Mac awake — built for enterprise.**

Niacin prevents your Mac from sleeping on demand, with fine-grained control over what stays awake: the system, the display, or both. Every setting can be locked and enforced by IT via a JAMF (or any MDM) managed preferences plist.

---

## Features

- **Menu bar first** — lives in your menu bar, no Dock icon, no clutter
- **Flexible sleep control** — choose between full awake, system-only awake, or lock prevention per activation
- **Timed activations** — activate for 5 minutes up to indefinitely, or set a hard cap via policy
- **Two independent modes** configurable from the menu:
  - `Allow screen to sleep` — system stays awake, display can dim and lock per company policy
  - `Prevent device from locking` — keeps display on, no screensaver, no lock screen
- **Enterprise-ready** — every setting manageable via a single MDM plist
- **Lock indicators** — settings controlled by IT show a 🔒 icon; users can't override them
- **Managed policy section** — settings window surfaces active IT constraints clearly

---

## How it works

Niacin wraps macOS's built-in `caffeinate` command:

| Mode | Flag | Effect |
|---|---|---|
| Full awake | `-di` | Prevents display sleep and system idle sleep |
| System awake only | `-i` | Prevents system sleep; display can sleep and lock |
| Timed activation | `-t N` | Automatically deactivates after N seconds |

No background daemons, no kernel extensions — just a thin Swift wrapper around a tool Apple ships on every Mac.

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
| `disableAutoUpdate` | Bool | `false` | Disable Sparkle auto-update entirely. When `true`: no background checks, the in-app "Check for Updates…" UI is hidden, the Settings toggle is locked. Most managed orgs push updates via JAMF and want to suppress self-updates |

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

    <!-- IT pushes updates via JAMF; users cannot self-update -->
    <key>disableAutoUpdate</key>
    <true/>

</dict>
</plist>
```

### Auto-update lockdown only

If you only need to disable Sparkle's self-update mechanism (because IT pushes builds via JAMF / Munki / Intune) and want to leave every other setting under user control:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>disableAutoUpdate</key>
    <true/>
</dict>
</plist>
```

When this key is set, Niacin will:

- Skip background update checks entirely
- Hide the "Check for Updates…" item from the menu bar menu
- Lock the "Automatically check for updates" toggle in Settings (with an "Auto-updates disabled by policy" indicator in the Managed-by-Organisation section)
- React to the policy live via the file watcher — flipping the key on or off in the deployed plist takes effect within ~200 ms without restarting the app

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
