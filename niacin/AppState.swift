import Foundation
import AppKit

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    let preventer = SleepPreventer()
    private var hasLaunched = false
    private var countdownTimer: Timer?
    private var policyPollTimer: Timer?
    private var lastPlistModDates: [String: Date] = [:]

    // Drives the menu bar countdown label; nil when inactive or indefinite
    private(set) var countdownText: String? = nil
    // Drives the menu bar tooltip
    private(set) var tooltipText: String = "Niacin — Inactive"
    // Incremented on every policy reload; observed by computed properties to force re-renders
    private(set) var policyRevision: Int = 0

    // The durations shown in the menu, filtered and capped by managed policy
    var availableDurations: [ActivationDuration] {
        _ = policyRevision // establish dependency so policy changes trigger re-evaluation
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
        startCountdownTimer(timed: duration.timeInterval != nil)
    }

    func deactivate() {
        guard ManagedPreferences.allowUserToDisable else { return }
        preventer.deactivate()
        stopCountdownTimer()
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

        startPolicyWatcher()
    }

    @objc private func sessionResigned() {
        let shouldDeactivate = ManagedPreferences.deactivateOnUserSwitch
            ?? UserDefaults.standard.bool(forKey: "deactivateOnUserSwitch")
        if shouldDeactivate {
            preventer.deactivate()
            stopCountdownTimer()
        }
    }

    private func startCountdownTimer(timed: Bool) {
        stopCountdownTimer()
        updateCountdown()
        guard timed else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownText = nil
        tooltipText = "Niacin — Inactive"
    }

    private func updateCountdown() {
        guard preventer.isActive else { stopCountdownTimer(); return }
        guard let until = preventer.activeUntil else {
            countdownText = nil
            tooltipText = "Niacin — Keeping you awake"
            return
        }
        let remaining = Int(until.timeIntervalSinceNow)
        guard remaining > 0 else {
            countdownText = nil
            tooltipText = "Niacin — Keeping you awake"
            return
        }
        let formatted = Self.format(seconds: remaining)
        countdownText = formatted
        tooltipText = "Niacin — \(formatted) remaining"
    }

    private static func format(seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        } else if seconds >= 60 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds)s"
        }
    }

    // MARK: - Live policy reload

    private func startPolicyWatcher() {
        // Catch JAMF profile installs/removals instantly via distributed notification
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(managedConfigChanged),
            name: NSNotification.Name("com.apple.managedconfiguration.profileListChanged"),
            object: nil
        )

        // Poll plist mod dates every 5 seconds — reliable regardless of how the file
        // is written (in-place, replace, JAMF, sudo defaults write, etc.)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPlistChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        policyPollTimer = timer
    }

    @objc private func managedConfigChanged() {
        reloadPolicy()
    }

    private func checkPlistChanges() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin"
        let paths = [
            "/Library/Managed Preferences/\(bundleID).plist",
            "/Library/Managed Preferences/\(NSUserName())/\(bundleID).plist"
        ]

        var changed = false
        for path in paths {
            let modDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if modDate != lastPlistModDates[path] {
                lastPlistModDates[path] = modDate
                changed = true
            }
        }

        if changed { reloadPolicy() }
    }

    func reloadPolicy() {
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin") as CFString
        CFPreferencesAppSynchronize(bundleID)
        CFPreferencesSynchronize(bundleID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(bundleID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(bundleID, kCFPreferencesAnyUser, kCFPreferencesAnyHost)

        // Always bump so availableDurations and lock icons re-evaluate
        policyRevision += 1

        // Deactivate any running session — new policy is enforced on next activation
        guard preventer.isActive else { return }
        preventer.deactivate()
        stopCountdownTimer()
    }
}
