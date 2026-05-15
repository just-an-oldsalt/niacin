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
            // Force-active sources — MCP sessions are addressable (per-session
            // Release button), deploy/app matches are read-only.
            if appState.hasForceActive {
                Text("Active for:")
                forceActiveRows
                Divider()
            }

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
        let mode = appState.preventer.isAllowingDisplaySleep
            ? String(localized: "screen can sleep")
            : String(localized: "screen stays on")

        if let until = appState.preventer.activeUntil {
            let time = until.formatted(date: .omitted, time: .shortened)
            return String(localized: "Awake until \(time) · \(mode)")
        }
        return String(localized: "Keeping you awake · \(mode)")
    }

    // Rows that list every force-active source currently holding an
    // assertion. Today that's just MCP sessions — each renders as a
    // button so the user can release it directly from the menu.
    @ViewBuilder
    private var forceActiveRows: some View {
        ForEach(sortedMCPSessions, id: \.id) { session in
            Button {
                appState.releaseMCPSession(id: session.id)
            } label: {
                Text(mcpRowLabel(for: session))
            }
        }
    }

    private var sortedMCPSessions: [MCPSession] {
        appState.mcpSessions.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func mcpRowLabel(for s: MCPSession) -> String {
        let client = s.clientName ?? "agent"
        let suffix: String
        if let expires = s.expiresAt {
            let remaining = Int(expires.timeIntervalSinceNow)
            if remaining > 0 {
                suffix = " · \(Self.format(seconds: remaining)) left — release"
            } else {
                suffix = " · expiring — release"
            }
        } else {
            suffix = " · indefinite — release"
        }
        return "· MCP: \(client)\(suffix)"
    }

    private static func format(seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        } else if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }
}

private struct MenuManagedToggle: View {
    let title: LocalizedStringKey
    let binding: Binding<Bool>
    let managed: Bool?

    init(_ title: LocalizedStringKey, isOn binding: Binding<Bool>, managed: Bool?) {
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
