import SwiftUI
import AppKit
import Sparkle

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NiacinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Sparkle initializes its background updater immediately. AppState
        // gets a reference so the managed-policy `disableAutoUpdate` key can
        // gate auto-checks live via PolicyWatcher.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        AppState.shared.attachUpdater(controller.updater)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.preventer.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                if let countdown = appState.countdownText {
                    Text(countdown)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
