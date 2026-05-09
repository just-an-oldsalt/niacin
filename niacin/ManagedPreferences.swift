import Foundation

// Reads MDM-managed preferences deployed by JAMF or any MDM solution.
// JAMF deploys the plist to: /Library/Managed Preferences/com.oldsalt.niacin.plist
// CFPreferences resolves the managed domain automatically — no extra configuration needed.
struct ManagedPreferences {
    private static let appID = (Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin") as CFString

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
        guard let raw = CFPreferencesCopyAppValue("allowedDurations" as CFString, appID),
              let array = raw as? [Any] else { return nil }
        // CFPreferences returns NSNumber elements, not Int
        let ints = array.compactMap { ($0 as? NSNumber)?.intValue }
        return ints.isEmpty ? nil : ints
    }

    // Returns true only if the key exists in a managed preferences plist on disk,
    // not just in user defaults — prevents spurious lock icons on user-set prefs
    static func isManaged(key: String) -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin"
        let paths = [
            "/Library/Managed Preferences/\(bundleID).plist",
            "/Library/Managed Preferences/\(NSUserName())/\(bundleID).plist"
        ]
        return paths.contains { (NSDictionary(contentsOfFile: $0)?[key]) != nil }
    }

    private static func bool(_ key: String) -> Bool? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, appID) else { return nil }
        // Plist booleans come back as CFBoolean — use CFBooleanGetValue for a reliable read
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        // Integer 0/1 fallback (some MDM systems encode booleans as numbers)
        return (raw as? NSNumber)?.boolValue
    }

    private static func int(_ key: String) -> Int? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, appID) else { return nil }
        if CFGetTypeID(raw) == CFNumberGetTypeID() {
            return (raw as? NSNumber)?.intValue
        }
        return nil
    }
}
