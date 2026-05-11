import SwiftUI
import Sparkle

struct SettingsView: View {
    @AppStorage("activateOnLaunch") private var activateOnLaunch = false
    @AppStorage("allowDisplaySleep") private var allowDisplaySleep = false
    @AppStorage("preventDeviceLock") private var preventDeviceLock = false
    @AppStorage("deactivateOnUserSwitch") private var deactivateOnUserSwitch = false
    @AppStorage("warnSoundOnExpiry") private var warnSoundOnExpiry = false

    @State private var appState = AppState.shared

    var body: some View {
        // .id() forces a clean rebuild when policy changes so static
        // ManagedPreferences.* reads in subviews are re-evaluated.
        Form {
            Section("General") {
                ManagedToggle(
                    "Activate on launch",
                    isOn: $activateOnLaunch,
                    managed: ManagedPreferences.activateOnLaunch
                )
            }

            Section("Screen & Lock") {
                ManagedToggle(
                    "Allow screen to sleep",
                    isOn: $allowDisplaySleep,
                    managed: ManagedPreferences.allowDisplaySleep
                )
                ManagedToggle(
                    "Prevent device from locking",
                    isOn: $preventDeviceLock,
                    managed: ManagedPreferences.preventDeviceLock
                )
            }

            Section("Session") {
                ManagedToggle(
                    "Deactivate on user switch",
                    isOn: $deactivateOnUserSwitch,
                    managed: ManagedPreferences.deactivateOnUserSwitch
                )
                Toggle("Play a sound 30 seconds before a timed session ends",
                       isOn: $warnSoundOnExpiry)
            }

            if let updater = appState.updater {
                Section("Software Update") {
                    let mdmDisabled = ManagedPreferences.disableAutoUpdate
                    ManagedToggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates && !mdmDisabled },
                            set: { updater.automaticallyChecksForUpdates = $0 }
                        ),
                        managed: mdmDisabled ? false : nil
                    )
                    Picker("Check frequency", selection: Binding(
                        get: { updater.updateCheckInterval },
                        set: { updater.updateCheckInterval = $0 }
                    )) {
                        Text("Daily").tag(TimeInterval(86_400))
                        Text("Weekly").tag(TimeInterval(86_400 * 7))
                        Text("Monthly").tag(TimeInterval(86_400 * 30))
                    }
                    .disabled(mdmDisabled)
                    HStack {
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(mdmDisabled)
                    }
                }
            }

            if hasManagedPolicies {
                Section("Managed by Organisation") {
                    if !ManagedPreferences.isEnabled {
                        PolicyRow("App disabled by IT policy", icon: "xmark.circle.fill", tint: .red)
                    }
                    if !ManagedPreferences.allowUserToDisable {
                        PolicyRow("Cannot be manually deactivated", icon: "lock.fill", tint: .orange)
                    }
                    if !ManagedPreferences.allowIndefinite {
                        PolicyRow("Indefinite activation not permitted", icon: "infinity", tint: .orange)
                    }
                    if let max = ManagedPreferences.maxDurationSeconds {
                        PolicyRow(
                            "Max duration: \(ActivationDuration(seconds: max).displayTitle)",
                            icon: "clock.badge.exclamationmark.fill",
                            tint: .orange
                        )
                    }
                    if ManagedPreferences.disableQuit {
                        PolicyRow("Quit disabled by policy", icon: "lock.fill", tint: .orange)
                    }
                    if ManagedPreferences.allowedDurations != nil {
                        PolicyRow("Available durations set by policy", icon: "list.bullet", tint: .secondary)
                    }
                    if ManagedPreferences.disableAutoUpdate {
                        PolicyRow("Auto-updates disabled by policy", icon: "lock.fill", tint: .orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 340)
        .id(appState.policyRevision)
    }

    private var hasManagedPolicies: Bool {
        !ManagedPreferences.isEnabled            ||
        !ManagedPreferences.allowUserToDisable   ||
        !ManagedPreferences.allowIndefinite      ||
        ManagedPreferences.maxDurationSeconds != nil ||
        ManagedPreferences.disableQuit           ||
        ManagedPreferences.allowedDurations != nil ||
        ManagedPreferences.disableAutoUpdate
    }
}

// A Toggle that shows a lock icon and becomes read-only when managed by MDM
private struct ManagedToggle: View {
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
            HStack(spacing: 6) {
                Text(title)
                if managed != nil {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }
        }
        .tint(.green)
        .disabled(managed != nil)
    }
}

// A labelled row used in the managed policy section
private struct PolicyRow: View {
    let text: LocalizedStringKey
    let icon: String
    let tint: Color

    init(_ text: LocalizedStringKey, icon: String, tint: Color) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: icon)
            .foregroundStyle(tint)
    }
}
