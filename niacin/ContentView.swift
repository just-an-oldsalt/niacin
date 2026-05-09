import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage("allowDisplaySleep") private var allowDisplaySleep = false
    @AppStorage("preventDeviceLock") private var preventDeviceLock = false

    var body: some View {
        // .id() invalidates the menu when policy changes so static
        // ManagedPreferences.* reads below pick up new values even if the
        // menu is already open.
        Group {
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
                MenuManagedToggle(
                    "Allow screen to sleep",
                    isOn: $allowDisplaySleep,
                    managed: ManagedPreferences.allowDisplaySleep
                )
                MenuManagedToggle(
                    "Prevent device from locking",
                    isOn: $preventDeviceLock,
                    managed: ManagedPreferences.preventDeviceLock
                )
                Divider()
            }

            Button("Settings\u{2026}") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("About Niacin") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }

            if !ManagedPreferences.disableQuit {
                Divider()
                Button("Quit Niacin") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .id(appState.policyRevision)
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

private struct MenuManagedToggle: View {
    let title: String
    let binding: Binding<Bool>
    let managed: Bool?

    init(_ title: String, isOn binding: Binding<Bool>, managed: Bool?) {
        self.title = title
        self.binding = binding
        self.managed = managed
    }

    var body: some View {
        Toggle(isOn: managed != nil ? .constant(managed!) : binding) {
            HStack(spacing: 4) {
                Text(title)
                if managed != nil {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(managed != nil)
    }
}
