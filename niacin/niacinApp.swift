import SwiftUI
import AppKit
import OSLog

private let urlLog = Logger(subsystem: "com.oldsalt.niacin", category: "url-scheme")

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.onLaunch()
    }

    // Reload policy whenever the app gains focus — covers cases where the
    // kqueue watcher missed an event (network mounts, atomic-replace edge
    // cases) and the user is now interacting with us.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.reloadPolicy()
    }

    // niacin:// URL handler. Lets external automation (Calendar reminders,
    // Shortcuts, webhooks, Stream Deck, `open niacin://...` from a shell)
    // drive activation and deactivation. Schema:
    //
    //   niacin://activate                       — indefinite session
    //   niacin://activate?duration=1800         — 1800-second session
    //   niacin://activate?duration=indefinite   — same as no duration
    //   niacin://deactivate                     — end current session
    //
    // Activations still honour every managed-prefs guard
    // (`enabled`, `allowIndefinite`, `maxDurationSeconds`, etc.) because we
    // dispatch through AppState.activate, not directly to the preventer.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleNiacinURL(url)
        }
    }

    private func handleNiacinURL(_ url: URL) {
        guard url.scheme == "niacin" else {
            urlLog.warning("ignored non-niacin URL: \(url.absoluteString, privacy: .public)")
            return
        }

        let action = url.host ?? ""
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        urlLog.info("URL action: \(action, privacy: .public) params=\(params, privacy: .public)")

        Task { @MainActor in
            switch action {
            case "activate":
                let duration = Self.parseDuration(params["duration"])
                AppState.shared.activate(duration: duration)
            case "deactivate":
                AppState.shared.deactivate()
            default:
                urlLog.warning("unknown URL action: \(action, privacy: .public)")
            }
        }
    }

    // "1800" → 1800-second session; "indefinite" / nil / unparseable → .indefinite.
    // Negative or zero is treated as indefinite so callers can't accidentally
    // create a no-op session.
    private static func parseDuration(_ raw: String?) -> ActivationDuration {
        guard let raw, raw.lowercased() != "indefinite", let seconds = Int(raw), seconds > 0 else {
            return .indefinite
        }
        return ActivationDuration(seconds: seconds)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NiacinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName:
                    appState.preventer.lastError != nil ? "exclamationmark.triangle.fill" :
                    appState.isKeepingAwake ? "cup.and.saucer.fill" :
                    "cup.and.saucer"
                )
                if let countdown = appState.countdownText {
                    Text(countdown)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(appState.isExpiringSoon ? Color.orange : Color.primary)
                } else if appState.preventer.isActive {
                    Text("∞")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .help(appState.tooltipText)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }

        Window("About Niacin", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

}
