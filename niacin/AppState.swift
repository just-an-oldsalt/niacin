import Foundation
import AppKit
import OSLog
import Sparkle

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "policy")

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    let preventer = SleepPreventer()
    private var hasLaunched = false
    private var countdownTimer: Timer?
    private let policyWatcher = PolicyWatcher()
    private(set) var updater: SPUUpdater?

    // Drives the menu bar countdown label; nil when inactive or indefinite
    private(set) var countdownText: String? = nil
    // Drives the menu bar tooltip
    private(set) var tooltipText: String = String(localized: "Niacin — Inactive")
    // Incremented on every policy reload; views read this via .id(...) to force
    // a fresh re-render so static ManagedPreferences.* reads pick up new values.
    private(set) var policyRevision: Int = 0

    // The durations shown in the menu, filtered and capped by managed policy.
    // Views must apply `.id(appState.policyRevision)` on the enclosing container
    // so this getter is re-invoked when policy changes.
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
        guard ManagedPreferences.isEnabled else {
            log.warning("activate blocked — app disabled by policy")
            return
        }

        let allowDisplaySleep = ManagedPreferences.allowDisplaySleep
            ?? UserDefaults.standard.bool(forKey: "allowDisplaySleep")
        let preventDeviceLock = ManagedPreferences.preventDeviceLock
            ?? UserDefaults.standard.bool(forKey: "preventDeviceLock")

        // preventDeviceLock requires the display to stay on, overriding allowDisplaySleep
        let effectiveAllowDisplaySleep = allowDisplaySleep && !preventDeviceLock

        log.info("activating: duration=\(duration.displayTitle, privacy: .public) allowDisplaySleep=\(effectiveAllowDisplaySleep, privacy: .public)")
        preventer.activate(duration: duration.timeInterval, allowDisplaySleep: effectiveAllowDisplaySleep)
        startCountdownTimer(timed: duration.timeInterval != nil)
    }

    func deactivate() {
        guard ManagedPreferences.allowUserToDisable else {
            log.warning("deactivate blocked — allowUserToDisable=false")
            return
        }
        log.info("deactivating (user request)")
        preventer.deactivate()
        stopCountdownTimer()
    }

    func toggle() {
        if preventer.isActive {
            deactivate()
        } else if let first = availableDurations.first {
            activate(duration: first)
        }
    }

    func onLaunch() {
        guard !hasLaunched else { return }
        hasLaunched = true

        let shouldActivate = ManagedPreferences.activateOnLaunch
            ?? UserDefaults.standard.bool(forKey: "activateOnLaunch")
        if shouldActivate && ManagedPreferences.isEnabled, let first = availableDurations.first {
            activate(duration: first)
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
        tooltipText = String(localized: "Niacin — Inactive")
    }

    private func updateCountdown() {
        guard preventer.isActive else { stopCountdownTimer(); return }
        guard let until = preventer.activeUntil else {
            countdownText = nil
            tooltipText = String(localized: "Niacin — Keeping you awake")
            return
        }
        let remaining = Int(until.timeIntervalSinceNow)
        guard remaining > 0 else {
            countdownText = nil
            tooltipText = String(localized: "Niacin — Keeping you awake")
            return
        }
        let formatted = Self.format(seconds: remaining)
        countdownText = formatted
        tooltipText = String(localized: "Niacin — \(formatted) remaining")
    }

    private static func format(seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0
                ? String(localized: "\(h)h \(m)m")
                : String(localized: "\(h)h")
        } else if seconds >= 60 {
            return String(localized: "\(seconds / 60)m")
        } else {
            return String(localized: "\(seconds)s")
        }
    }

    // MARK: - Live policy reload

    private func startPolicyWatcher() {
        // kqueue file watcher on the managed plist paths — fires within milliseconds.
        policyWatcher.start { [weak self] in
            log.info("policy watcher fired — reloading policy")
            self?.reloadPolicy()
        }

        // Best-effort: cfprefsd posts this when a managed preferences domain
        // changes. Not documented and not guaranteed; the kqueue watcher is
        // the real workhorse, but if it fires we get an even faster reaction.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(managedConfigChanged),
            name: NSNotification.Name("com.apple.managedconfiguration.profileListChanged"),
            object: nil
        )

        // After waking from sleep, the kqueue may have missed events that
        // happened while we were suspended. Force a reload.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        log.info("system woke — reloading policy")
        reloadPolicy()
    }

    @objc private func managedConfigChanged() {
        log.info("managedConfigChanged notification received — reloading policy")
        reloadPolicy()
    }

    func reloadPolicy() {
        // ManagedPreferences reads directly from disk, so no cfprefsd sync
        // is needed — the next read will see the current plist contents.
        policyRevision += 1
        log.info("policyRevision=\(self.policyRevision, privacy: .public) isActive=\(self.preventer.isActive, privacy: .public) isEnabled=\(ManagedPreferences.isEnabled, privacy: .public)")
        enforceAutoUpdatePolicy()

        guard preventer.isActive else { return }

        // Only interrupt the running session if the new policy is incompatible
        // with it. A compatible change (e.g. lock icons, allowUserToDisable
        // flipping) leaves caffeinate running.
        if let reason = sessionIncompatibilityReason() {
            log.info("deactivating running session: \(reason, privacy: .public)")
            preventer.deactivate()
            stopCountdownTimer()
        }
    }

    // MARK: - Sparkle wiring

    // Called once from NiacinApp.init after the SPUStandardUpdaterController
    // is created. Lets AppState gate auto-checks on the managed-policy key.
    func attachUpdater(_ updater: SPUUpdater) {
        self.updater = updater
        enforceAutoUpdatePolicy()
        log.info("updater attached, autoCheck=\(updater.automaticallyChecksForUpdates, privacy: .public)")
    }

    private func enforceAutoUpdatePolicy() {
        guard let updater else { return }
        let allowed = !ManagedPreferences.disableAutoUpdate
        if updater.automaticallyChecksForUpdates != allowed {
            updater.automaticallyChecksForUpdates = allowed
            log.info("auto-update policy change → autoCheck=\(allowed, privacy: .public)")
        }
    }

    // Returns a human-readable reason why the current session must end under
    // the new policy, or nil if it can keep running.
    private func sessionIncompatibilityReason() -> String? {
        if !ManagedPreferences.isEnabled {
            return "app disabled by policy"
        }
        let isIndefinite = preventer.activeUntil == nil
        if isIndefinite && !ManagedPreferences.allowIndefinite {
            return "indefinite activation no longer permitted"
        }
        if let max = ManagedPreferences.maxDurationSeconds {
            if isIndefinite {
                return "indefinite session exceeds maxDurationSeconds=\(max)"
            }
            if let until = preventer.activeUntil {
                let remaining = Int(until.timeIntervalSinceNow)
                if remaining > max {
                    return "remaining=\(remaining)s exceeds maxDurationSeconds=\(max)"
                }
            }
        }
        return nil
    }
}
