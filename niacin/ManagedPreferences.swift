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
