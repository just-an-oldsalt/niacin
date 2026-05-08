# ☕ niacin

**A macOS menu bar utility that keeps your Mac awake — built for enterprise.**

niacin prevents your Mac from sleeping on demand, with fine-grained control over what stays awake: the system, the display, or both. Every setting can be locked and enforced by IT via a JAMF (or any MDM) managed preferences plist.

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

niacin wraps macOS's built-in `caffeinate` command:

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

niacin reads managed preferences automatically from:

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

macOS will write the plist to `/Library/Managed Preferences/` and niacin will pick it up on next launch without any restart required for most keys.

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
