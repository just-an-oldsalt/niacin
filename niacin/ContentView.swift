import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("allowDisplaySleep") private var allowDisplaySleep = false
    @AppStorage("preventDeviceLock") private var preventDeviceLock = false

    var body: some View {
        if appState.preventer.isActive {
            Text(statusLabel)
            Divider()
            if ManagedPreferences.allowUserToDisable {
                Button("Deactivate") {
                    appState.deactivate()
                }
                Divider()
            }
        } else {
            if ManagedPreferences.isEnabled {
                ForEach(appState.availableDurations) { duration in
                    Button("Activate for \(duration.displayTitle)") {
                        appState.activate(duration: duration)
                    }
                }
                if appState.availableDurations.isEmpty {
                    Text("No durations available")
                }
            } else {
                Text("Disabled by IT policy")
            }

            Divider()

            if !ManagedPreferences.isManaged(key: "allowDisplaySleep") {
                Toggle("Allow screen to sleep", isOn: $allowDisplaySleep)
            }
            if !ManagedPreferences.isManaged(key: "preventDeviceLock") {
                Toggle("Prevent device from locking", isOn: $preventDeviceLock)
            }

            Divider()
        }

        SettingsLink {
            Text("Settings\u{2026}")
        }

        if !ManagedPreferences.disableQuit {
            Divider()
            Button("Quit Niacin") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var statusLabel: String {
        let mode: String
        if appState.preventer.isAllowingDisplaySleep {
            mode = "screen can sleep"
        } else {
            mode = "screen stays on"
        }

        if let until = appState.preventer.activeUntil {
            return "Awake until \(until.formatted(date: .omitted, time: .shortened)) \u{00B7} \(mode)"
        }
        return "Keeping you awake \u{00B7} \(mode)"
    }
}
