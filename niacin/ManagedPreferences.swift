import Foundation

// Reads MDM-managed preferences deployed by JAMF or any MDM solution.
// JAMF deploys the plist to: /Library/Managed Preferences/com.oldsalt.niacin.plist
// CFPreferences resolves the managed domain automatically — no extra configuration needed.
struct ManagedPreferences {
    private static let appID = "com.oldsalt.niacin" as CFString

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
              let array = raw as? [Int] else { return nil }
        return array
    }

    // Returns true if the given key is set in any managed preferences domain
    static func isManaged(key: String) -> Bool {
        CFPreferencesCopyAppValue(key as CFString, appID) != nil
    }

    private static func bool(_ key: String) -> Bool? {
        CFPreferencesCopyAppValue(key as CFString, appID) as? Bool
    }

    private static func int(_ key: String) -> Int? {
        CFPreferencesCopyAppValue(key as CFString, appID) as? Int
    }
}
