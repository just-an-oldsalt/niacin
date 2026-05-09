import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.onLaunch()
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
