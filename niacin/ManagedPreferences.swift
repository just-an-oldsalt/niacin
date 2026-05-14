import Foundation
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "managed-prefs")

// Reads MDM-managed preferences deployed by JAMF or any MDM solution.
// JAMF deploys the plist to: /Library/Managed Preferences/com.oldsalt.niacin.plist
//
// We read the managed plists directly from disk rather than via
// CFPreferencesCopyAppValue. cfprefsd aggressively caches the managed domain
// and doesn't reliably invalidate its cache on direct plist edits — it
// expects ingestion via mdmclient / `profiles install`. Reading from disk
// guarantees live changes are picked up.
struct ManagedPreferences {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin"

    // Per-user managed plist takes precedence over system-wide, matching
    // CFPreferences's resolution order for the managed domain.
    // Exposed as a closure so tests can point it at temporary files.
    nonisolated(unsafe) static var pathsProvider: () -> [String] = {
        [
            "/Library/Managed Preferences/\(NSUserName())/\(bundleID).plist",
            "/Library/Managed Preferences/\(bundleID).plist",
        ]
    }

    private static func managedValue(_ key: String) -> Any? {
        for path in pathsProvider() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let dict = NSDictionary(contentsOfFile: path) else {
                log.error("failed to parse \(path, privacy: .public) — check XML syntax")
                continue
            }
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    // Master kill switch — set false to disable the app entirely
    static var isEnabled: Bool               { bool("enabled") ?? true }

    // Force activation when the app launches
    static var activateOnLaunch: Bool?       { bool("activateOnLaunch") }

    // Whether the user can activate indefinitely (no time limit)
    static var allowIndefinite: Bool         { bool("allowIndefinite") ?? true }

    // Whether the user can manually deactivate while running
    static var allowUserToDisable: Bool      { bool("allowUserToDisable") ?? true }

    // Remove Quit from the menu bar menu
    static var disableQuit: Bool             { bool("disableQuit") ?? false }

    // Lock the display-sleep toggle; nil means user-controlled
    // When false, the display stays on (-d flag added to caffeinate)
    static var allowDisplaySleep: Bool?      { bool("allowDisplaySleep") }

    // Lock the device-lock-prevention toggle; nil means user-controlled
    // When true, forces -d on caffeinate regardless of allowDisplaySleep
    static var preventDeviceLock: Bool?      { bool("preventDeviceLock") }

    // Enforce deactivation on fast-user-switch; nil means user-controlled
    static var deactivateOnUserSwitch: Bool? { bool("deactivateOnUserSwitch") }

    // Hard cap on any single activation, in seconds
    static var maxDurationSeconds: Int?      { int("maxDurationSeconds") }

    // Override the available durations list entirely (array of seconds as integers)
    static var allowedDurations: [Int]? {
        guard let array = managedValue("allowedDurations") as? [Any] else { return nil }
        let ints = array.compactMap { ($0 as? NSNumber)?.intValue }
        return ints.isEmpty ? nil : ints
    }

    // ─── Force-active triggers (v2.0) ──────────────────────────────────
    //
    // Three independent process-name watch lists. When any matches a
    // running process, Niacin silently force-activates regardless of
    // whether the user has a session of their own. Process names are
    // matched case-insensitively as substrings against kinfo_proc's
    // p_comm (kernel-limited to 16 chars). Watch needles must fit.

    // IT-managed list of deploy daemons (jamf, installd, softwareupdated,
    // munki, IntuneMdmAgent, mdmclient, Installer, etc.). The use case is
    // "don't sleep mid-deploy while JAMF pushes overnight". Empty array by
    // default — IT must opt in by specifying processes.
    static var forceActiveDuringDeploys: [String] {
        (managedValue("forceActiveDuringDeploys") as? [Any])?
            .compactMap { $0 as? String } ?? []
    }

    // IT or user-managed list of arbitrary apps that should keep the
    // device awake while running (Zoom, Teams, OBS, etc.). Empty array
    // by default.
    static var forceActiveDuringApps: [String] {
        (managedValue("forceActiveDuringApps") as? [Any])?
            .compactMap { $0 as? String } ?? []
    }

    // Whether to auto-detect known AI runtimes (Ollama, LM Studio,
    // llama.cpp server, ComfyUI, etc.) and keep the device awake while
    // they're loaded. The list is hardcoded (see defaultAIRuntimeProcesses).
    // Managed-only — nil means user-controlled (resolves via
    // resolvedAIRuntimeAutoAwake below). When managed, MDM wins.
    static var aiRuntimeAutoAwake: Bool? { bool("aiRuntimeAutoAwake") }

    // The effective value used by the AI watcher and Ollama inference probe:
    // managed > user-defaults > built-in default (false). Off by default —
    // process-presence detection alone would keep launchd-managed Ollama
    // installs awake 24/7, which surprises users who didn't opt in. The AI
    // workstation audience that wants this on can flip the Settings toggle
    // (or IT can enforce it fleet-wide via the managed key).
    static var resolvedAIRuntimeAutoAwake: Bool {
        if let managed = aiRuntimeAutoAwake { return managed }
        return UserDefaults.standard.bool(forKey: "aiRuntimeAutoAwake")
    }

    // Known local-AI runtime process names. Case-insensitive substring
    // match against p_comm. Truncation-aware — names that the kernel
    // would chop are entered in their post-truncation form.
    static let defaultAIRuntimeProcesses: [String] = [
        "ollama",
        "LM Studio",
        "llama-server",
        "mlx-lm",
        "mlx_lm.server",
        "ComfyUI",
        "InvokeAI",
        "stable-diffu",       // stable-diffusion-webui, truncated
        "mistralrs",          // mistralrs-server, truncated
        "vllm",
    ]

    // True only if the key is set in a managed preferences plist (vs. user
    // defaults) — drives lock icons.
    static func isManaged(key: String) -> Bool {
        managedValue(key) != nil
    }

    private static func bool(_ key: String) -> Bool? {
        guard let raw = managedValue(key) else {
            log.debug("bool(\(key, privacy: .public)): not found in managed domain")
            return nil
        }
        let value = (raw as? NSNumber)?.boolValue
        log.debug("bool(\(key, privacy: .public)): \(value.map(String.init) ?? "nil", privacy: .public)")
        return value
    }

    private static func int(_ key: String) -> Int? {
        guard let raw = managedValue(key) else {
            log.debug("int(\(key, privacy: .public)): not found in managed domain")
            return nil
        }
        let value = (raw as? NSNumber)?.intValue
        log.debug("int(\(key, privacy: .public)): \(value.map(String.init) ?? "nil", privacy: .public)")
        return value
    }
}
