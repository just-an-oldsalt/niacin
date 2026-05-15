import SwiftUI

struct SettingsView: View {
    @AppStorage("activateOnLaunch") private var activateOnLaunch = false
    @AppStorage("allowDisplaySleep") private var allowDisplaySleep = false
    @AppStorage("preventDeviceLock") private var preventDeviceLock = false
    @AppStorage("deactivateOnUserSwitch") private var deactivateOnUserSwitch = false
    @AppStorage("warnSoundOnExpiry") private var warnSoundOnExpiry = false
    @AppStorage("mcpServerEnabled") private var mcpServerEnabled = false

    @State private var appState = AppState.shared
    @State private var mcpToken: String? = nil
    @State private var mcpTokenJustGenerated = false
    @State private var mcpCopiedFlash = false

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

            Section("AI Agent Integration (MCP)") {
                ManagedToggle(
                    "Allow AI agents to drive keep-awake",
                    isOn: $mcpServerEnabled,
                    managed: ManagedPreferences.mcpServerEnabled
                )
                .onChange(of: mcpServerEnabled) { _, _ in
                    appState.refreshMCPServer()
                    refreshToken()
                }

                if ManagedPreferences.resolvedMCPServerEnabled {
                    mcpServerStatusView
                }

                Text("Niacin runs a local-only MCP server. Paired AI agents (Claude Desktop, Claude Code, Cursor) can request keep-awake assertions via the `keep_awake` tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
        .id(appState.policyRevision)
        .onAppear { refreshToken() }
    }

    private var hasManagedPolicies: Bool {
        !ManagedPreferences.isEnabled            ||
        !ManagedPreferences.allowUserToDisable   ||
        !ManagedPreferences.allowIndefinite      ||
        ManagedPreferences.maxDurationSeconds != nil ||
        ManagedPreferences.disableQuit           ||
        ManagedPreferences.allowedDurations != nil ||
        ManagedPreferences.mcpServerEnabled != nil
    }

    // MARK: - MCP server status / token UX

    @ViewBuilder
    private var mcpServerStatusView: some View {
        let port = appState.mcpServer?.actualPort.map(String.init) ?? "(starting…)"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: appState.mcpServer != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(appState.mcpServer != nil ? .green : .orange)
                Text("Listening on `http://127.0.0.1:\(port)`")
                    .font(.callout.monospaced())
            }

            if let token = mcpToken, mcpTokenJustGenerated {
                Text("Token (shown once):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
            } else if mcpToken != nil {
                Text("Token configured (use Rotate to generate a new one).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No token yet — generate one to connect a client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if mcpToken == nil {
                    Button("Generate Token") { generateToken() }
                } else {
                    Button("Rotate") { generateToken() }
                    Button("Revoke") { revokeToken() }
                        .foregroundStyle(.red)
                    Button(mcpCopiedFlash ? "Copied!" : "Copy Config") {
                        copyConfigSnippet()
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshToken() {
        mcpTokenJustGenerated = false
        mcpToken = try? MCPTokenStore.currentToken()
    }

    private func generateToken() {
        do {
            mcpToken = try MCPTokenStore.generateAndStore()
            mcpTokenJustGenerated = true
        } catch {
            mcpToken = nil
            mcpTokenJustGenerated = false
        }
    }

    private func revokeToken() {
        try? MCPTokenStore.revoke()
        mcpToken = nil
        mcpTokenJustGenerated = false
    }

    private func copyConfigSnippet() {
        guard let token = mcpToken, let port = appState.mcpServer?.actualPort else { return }
        let snippet = """
        {
          "mcpServers": {
            "niacin": {
              "url": "http://127.0.0.1:\(port)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        mcpCopiedFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            mcpCopiedFlash = false
        }
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
