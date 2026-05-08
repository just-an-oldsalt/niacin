import Foundation
import AppKit

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    let preventer = SleepPreventer()
    private var hasLaunched = false

    // The durations shown in the menu, filtered and capped by managed policy
    var availableDurations: [ActivationDuration] {
        var durations: [ActivationDuration]

        if let managed = ManagedPreferences.allowedDurations {
            durations = managed.map { ActivationDuration(seconds: $0) }
        } else {
            durations = [
                .indefinite,
                .minutes(5),
                .minutes(10),
                .minutes(15),
                .minutes(30),
                .hours(1),
                .hours(2),
            ]
        }

        if let maxSecs = ManagedPreferences.maxDurationSeconds {
            durations = durations.filter {
                guard let s = $0.seconds else { return ManagedPreferences.allowIndefinite }
                return s <= maxSecs
            }
        }

        if !ManagedPreferences.allowIndefinite {
            durations = durations.filter { $0.seconds != nil }
        }

        return durations
    }

    func activate(duration: ActivationDuration) {
        guard ManagedPreferences.isEnabled else { return }

        let allowDisplaySleep = ManagedPreferences.allowDisplaySleep
            ?? UserDefaults.standard.bool(forKey: "allowDisplaySleep")
        let preventDeviceLock = ManagedPreferences.preventDeviceLock
            ?? UserDefaults.standard.bool(forKey: "preventDeviceLock")

        // preventDeviceLock requires the display to stay on, overriding allowDisplaySleep
        let effectiveAllowDisplaySleep = allowDisplaySleep && !preventDeviceLock

        preventer.activate(duration: duration.timeInterval, allowDisplaySleep: effectiveAllowDisplaySleep)
    }

    func deactivate() {
        guard ManagedPreferences.allowUserToDisable else { return }
        preventer.deactivate()
    }

    func toggle() {
        preventer.isActive ? deactivate() : activate(duration: availableDurations.first ?? .indefinite)
    }

    func onLaunch() {
        guard !hasLaunched else { return }
        hasLaunched = true

        let shouldActivate = ManagedPreferences.activateOnLaunch
            ?? UserDefaults.standard.bool(forKey: "activateOnLaunch")
        if shouldActivate && ManagedPreferences.isEnabled {
            activate(duration: availableDurations.first ?? .indefinite)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionResigned),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared
        )
    }

    @objc private func sessionResigned() {
        let shouldDeactivate = ManagedPreferences.deactivateOnUserSwitch
            ?? UserDefaults.standard.bool(forKey: "deactivateOnUserSwitch")
        if shouldDeactivate {
            preventer.deactivate()
        }
    }
}
