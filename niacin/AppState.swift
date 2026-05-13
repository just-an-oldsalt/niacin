import Foundation
import AppKit
import OSLog
import IOKit.pwr_mgt
import Sparkle

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "policy")
private let auditLog = Logger(subsystem: "com.oldsalt.niacin", category: "audit")

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    let preventer = SleepPreventer()
    private var hasLaunched = false
    private var countdownTimer: Timer?
    private let policyWatcher = PolicyWatcher()
    private(set) var updater: SPUUpdater?

    // ─── Force-active state (v2.0) ─────────────────────────────────────
    //
    // Three independent ProcessWatchers feed into one set of IOKit power
    // assertions held by AppState itself (separate from the user-session
    // assertions held by `preventer`). When any watcher has matches, the
    // force-active assertion is held; macOS composes both assertion pairs
    // so the system stays awake whether the user activated manually OR a
    // watcher matched, OR both.
    private var deployWatcher: ProcessWatcher?
    private var appWatcher: ProcessWatcher?
    private var aiWatcher: ProcessWatcher?
    private var ollamaProbe: OllamaInferenceProbe?

    private(set) var deployMatches: Set<String> = []
    private(set) var appMatches: Set<String> = []
    private(set) var aiRuntimeMatches: Set<String> = []
    // True when Ollama's /api/ps endpoint has reported an empty models array
    // for 5+ minutes — Ollama is running but no model is loaded into VRAM.
    // While true, any Ollama-matching entries in aiRuntimeMatches are filtered
    // out of effectiveAIRuntimeMatches so the system can sleep.
    private(set) var ollamaIdle: Bool = false

    private var forceActiveSystemAssertion: IOPMAssertionID = 0
    private var forceActiveDisplayAssertion: IOPMAssertionID = 0

    // Process-presence AI matches with Ollama removed if active-inference
    // detection has declared it idle. This is the signal that actually drives
    // force-active state — aiRuntimeMatches stays as the raw process list for
    // observability.
    var effectiveAIRuntimeMatches: Set<String> {
        if ollamaIdle {
            return aiRuntimeMatches.filter { !$0.lowercased().contains("ollama") }
        }
        return aiRuntimeMatches
    }

    var hasForceActive: Bool {
        !deployMatches.isEmpty || !appMatches.isEmpty || !effectiveAIRuntimeMatches.isEmpty
    }

    // True if Niacin is keeping the system awake for *any* reason — user
    // session or force-active watcher. Drives the menu-bar icon state.
    var isKeepingAwake: Bool {
        preventer.isActive || hasForceActive
    }

    // Drives the menu bar countdown label; nil when inactive or indefinite
    private(set) var countdownText: String? = nil
    // True while a timed session has ≤30 seconds remaining. Drives the
    // gentle-warning UX: countdown text turns orange and an optional sound
    // (UserDefaults `warnSoundOnExpiry`) plays once at the threshold.
    private(set) var isExpiringSoon: Bool = false
    private var beepedForCurrentSession: Bool = false
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
        auditLog.info("activation: source=user duration=\(duration.displayTitle, privacy: .public) allowDisplaySleep=\(effectiveAllowDisplaySleep, privacy: .public)")
        preventer.activate(duration: duration.timeInterval, allowDisplaySleep: effectiveAllowDisplaySleep)
        if let err = preventer.lastError {
            // IOKit refused the assertion — surface it on the menu-bar tooltip
            // so the user knows the click did something even though the icon
            // didn't switch to the "active" state.
            tooltipText = String(localized: "Niacin — Error: \(err)")
        } else {
            startCountdownTimer(timed: duration.timeInterval != nil)
        }
    }

    func deactivate() {
        guard ManagedPreferences.allowUserToDisable else {
            log.warning("deactivate blocked — allowUserToDisable=false")
            return
        }
        log.info("deactivating (user request)")
        auditLog.info("deactivation: source=user")
        preventer.deactivate()
        stopCountdownTimer()
        updateTooltipForForceActive()  // refresh in case force-active is still running
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

        sweepOrphanCaffeinate()
        startProcessWatchers()

        let shouldActivate = ManagedPreferences.activateOnLaunch
            ?? UserDefaults.standard.bool(forKey: "activateOnLaunch")
        if shouldActivate && ManagedPreferences.isEnabled, let first = availableDurations.first {
            auditLog.info("activation: source=launch duration=\(first.displayTitle, privacy: .public)")
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

    // ─── Force-active watchers (v2.0) ──────────────────────────────────

    private func startProcessWatchers() {
        deployWatcher = ProcessWatcher(
            name: "deploy",
            needlesProvider: { ManagedPreferences.forceActiveDuringDeploys }
        ) { [weak self] matches in
            self?.handleWatcherChange(reason: "deploy", matches: matches)
        }
        deployWatcher?.start()

        appWatcher = ProcessWatcher(
            name: "apps",
            needlesProvider: { ManagedPreferences.forceActiveDuringApps }
        ) { [weak self] matches in
            self?.handleWatcherChange(reason: "app", matches: matches)
        }
        appWatcher?.start()

        aiWatcher = ProcessWatcher(
            name: "ai-runtime",
            needlesProvider: {
                ManagedPreferences.resolvedAIRuntimeAutoAwake
                    ? ManagedPreferences.defaultAIRuntimeProcesses
                    : []
            }
        ) { [weak self] matches in
            self?.handleWatcherChange(reason: "ai-runtime", matches: matches)
        }
        aiWatcher?.start()

        // Active-inference refinement layer for Ollama. The aiWatcher above
        // catches "ollama process is running"; this probe answers "is Ollama
        // actually doing anything". When Ollama has been idle (no model in
        // VRAM) for the grace window, the probe sets ollamaIdle=true and
        // Ollama-matching entries drop out of effectiveAIRuntimeMatches.
        ollamaProbe = OllamaInferenceProbe { [weak self] idle in
            guard let self else { return }
            guard self.ollamaIdle != idle else { return }
            self.ollamaIdle = idle
            auditLog.info("ollama-inference: idle=\(idle, privacy: .public)")
            self.recomputeForceActiveAssertion()
            self.updateTooltipForForceActive()
        }
        ollamaProbe?.start()
    }

    private func handleWatcherChange(reason: String, matches: Set<String>) {
        switch reason {
        case "deploy":     deployMatches = matches
        case "app":        appMatches = matches
        case "ai-runtime":
            aiRuntimeMatches = matches
            // If Ollama disappeared from the running-process list, reset the
            // probe's idle conclusion so a fresh Ollama launch isn't
            // suppressed by stale state from a prior session.
            let hasOllama = matches.contains(where: { $0.lowercased().contains("ollama") })
            if !hasOllama && ollamaIdle {
                ollamaIdle = false
            }
        default: return
        }

        // Structured audit-log entry that IT can grep for via `log show`.
        if matches.isEmpty {
            auditLog.info("force-active end: reason=\(reason, privacy: .public)")
        } else {
            auditLog.info("force-active begin: reason=\(reason, privacy: .public) matches=\(matches.sorted(), privacy: .public)")
        }

        recomputeForceActiveAssertion()
        updateTooltipForForceActive()
    }

    // Hold IOKit assertions for force-active reasons. These are independent
    // of the user-session assertions held by `preventer` — macOS composes
    // both pairs, so the system stays awake whenever EITHER pair is held.
    // When the user's session ends, force-active stays in place; when
    // force-active drops, the user's session is unaffected.
    private func recomputeForceActiveAssertion() {
        if hasForceActive {
            // Acquire (idempotent — release first if already held).
            if forceActiveSystemAssertion == 0 {
                let reason = "Niacin force-active (deploy / app / AI runtime)" as CFString
                var sys: IOPMAssertionID = 0
                let r1 = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason, &sys
                )
                if r1 == kIOReturnSuccess {
                    forceActiveSystemAssertion = sys
                } else {
                    log.error("force-active system assertion failed: \(r1, privacy: .public)")
                }

                var disp: IOPMAssertionID = 0
                let r2 = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason, &disp
                )
                if r2 == kIOReturnSuccess {
                    forceActiveDisplayAssertion = disp
                } else {
                    log.error("force-active display assertion failed: \(r2, privacy: .public)")
                }
                log.info("force-active engaged")
            }
        } else {
            // Release.
            if forceActiveSystemAssertion != 0 {
                IOPMAssertionRelease(forceActiveSystemAssertion)
                forceActiveSystemAssertion = 0
            }
            if forceActiveDisplayAssertion != 0 {
                IOPMAssertionRelease(forceActiveDisplayAssertion)
                forceActiveDisplayAssertion = 0
            }
            log.info("force-active released")
        }
    }

    private func updateTooltipForForceActive() {
        // Only override the tooltip when no user session is running. When
        // both user + force are active, the user session's tooltip wins
        // (it has more specific information like remaining time).
        guard !preventer.isActive else { return }

        if hasForceActive {
            let sources: [String] = [
                deployMatches.isEmpty ? nil : "deploy",
                appMatches.isEmpty ? nil : "app",
                effectiveAIRuntimeMatches.isEmpty ? nil : "AI",
            ].compactMap { $0 }
            tooltipText = String(localized: "Niacin — Active for \(sources.joined(separator: ", "))")
        } else {
            tooltipText = String(localized: "Niacin — Inactive")
        }
    }

    // One-shot cleanup for users upgrading from pre-v1.7 builds. Older
    // versions spawned `caffeinate` children that survived parent death and
    // leaked power assertions across crashes / Sparkle updates / Force Quits.
    // We kill any caffeinates still parented to launchd (PID 1) — those are
    // orphans by definition. Caffeinates the user spawned themselves in a
    // terminal have the shell as parent and are left alone.
    //
    // From v1.7 onwards Niacin doesn't spawn caffeinate at all, so this only
    // matters during the upgrade transition. Safe to remove in a later release.
    private func sweepOrphanCaffeinate() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "pgrep -P 1 -x caffeinate | xargs -r kill 2>/dev/null"]
        do {
            try task.run()
            task.waitUntilExit()
            log.info("orphan caffeinate sweep complete (status \(task.terminationStatus, privacy: .public))")
        } catch {
            log.error("orphan caffeinate sweep failed: \(error.localizedDescription, privacy: .public)")
        }
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
        isExpiringSoon = false
        beepedForCurrentSession = false
        // If force-active is keeping us awake even after the user session
        // ends, leave the tooltip in its force-active form. Only reset to
        // "Inactive" when nothing is keeping the system awake.
        if hasForceActive {
            updateTooltipForForceActive()
        } else {
            tooltipText = String(localized: "Niacin — Inactive")
        }
    }

    private func updateCountdown() {
        guard preventer.isActive else { stopCountdownTimer(); return }
        guard let until = preventer.activeUntil else {
            countdownText = nil
            isExpiringSoon = false
            tooltipText = String(localized: "Niacin — Keeping you awake")
            return
        }
        let remaining = Int(until.timeIntervalSinceNow)
        guard remaining > 0 else {
            countdownText = nil
            isExpiringSoon = false
            tooltipText = String(localized: "Niacin — Keeping you awake")
            return
        }

        // Gentle countdown warning: ≤30s remaining flips isExpiringSoon
        // (drives orange-text styling in the menu bar) and plays a beep
        // once if the user opted into the sound preference.
        let nowExpiring = remaining <= 30
        if nowExpiring && !isExpiringSoon && !beepedForCurrentSession {
            if UserDefaults.standard.bool(forKey: "warnSoundOnExpiry") {
                NSSound.beep()
            }
            beepedForCurrentSession = true
        }
        isExpiringSoon = nowExpiring

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
        log.info("updater attached, autoCheck=\(updater.automaticallyChecksForUpdates, privacy: .public) interval=\(updater.updateCheckInterval, privacy: .public)s")
    }

    // Niacin checks for updates daily, period. The only escape hatch is the
    // managed `disableAutoUpdate` key — IT teams push their own updates via
    // JAMF and want self-update suppressed. There is no user-facing opt-out;
    // we re-assert both fields on every policy reload so a stale UserDefaults
    // value (e.g. SUEnableAutomaticChecks=false written by a prior version)
    // can't survive a launch.
    private let dailyCheckInterval: TimeInterval = 86_400

    private func enforceAutoUpdatePolicy() {
        guard let updater else { return }
        let allowed = !ManagedPreferences.disableAutoUpdate
        if updater.automaticallyChecksForUpdates != allowed {
            updater.automaticallyChecksForUpdates = allowed
            log.info("auto-update policy change → autoCheck=\(allowed, privacy: .public)")
        }
        if updater.updateCheckInterval != dailyCheckInterval {
            updater.updateCheckInterval = dailyCheckInterval
            log.info("update interval pinned → \(self.dailyCheckInterval, privacy: .public)s")
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
