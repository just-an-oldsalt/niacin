import Foundation
import AppKit
import OSLog
import IOKit.pwr_mgt

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

    // ─── Force-active state ────────────────────────────────────────────
    //
    // MCP sessions feed into a shared IOKit power-assertion pair (held by
    // AppState, separate from the user-session assertions in `preventer`).
    // macOS composes both pairs, so the system stays awake whether the user
    // activated manually OR an MCP client is holding `keep_awake`, OR both.
    // Sessions self-release after their declared duration via per-session
    // Task watchdogs.
    private(set) var mcpSessions: [String: MCPSession] = [:]
    private var mcpSessionTasks: [String: Task<Void, Never>] = [:]
    private(set) var mcpServer: MCPServer?

    private var forceActiveSystemAssertion: IOPMAssertionID = 0
    private var forceActiveDisplayAssertion: IOPMAssertionID = 0

    var hasForceActive: Bool {
        !mcpSessions.isEmpty
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
            refreshCountdownTimer()
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
        refreshCountdownTimer()
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
        refreshMCPServer()

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

    // MARK: - MCP server lifecycle

    func startMCPServer() {
        guard mcpServer == nil else { return }
        let server = MCPServer(delegate: self)
        do {
            try server.start()
            mcpServer = server
            log.info("mcp server started on port \(server.actualPort ?? 0, privacy: .public)")
        } catch {
            log.error("mcp server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
        // Stopping the listener doesn't tear down outstanding sessions —
        // assertions stay held until they expire or are released by API.
    }

    func refreshMCPServer() {
        let wantedOn = ManagedPreferences.resolvedMCPServerEnabled
        if wantedOn && mcpServer == nil {
            startMCPServer()
        } else if !wantedOn && mcpServer != nil {
            stopMCPServer()
        }
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
                let reason = "Niacin force-active (MCP session)" as CFString
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
            tooltipText = String(localized: "Niacin — Active for MCP")
        } else {
            tooltipText = String(localized: "Niacin — Inactive")
        }
    }

    // One-shot cleanup for users upgrading from pre-v1.7 builds. Older
    // versions spawned `caffeinate` children that survived parent death and
    // leaked power assertions across crashes / updates / Force Quits. We kill
    // any caffeinates still parented to launchd (PID 1) — those are orphans by
    // definition. Caffeinates the user spawned themselves in a terminal have
    // the shell as parent and are left alone.
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
            refreshCountdownTimer()
        }
    }

    // Soonest expiry across every deadline-bearing source — user session and
    // MCP sessions. Drives the menu bar countdown so an agent-requested
    // `keep_awake(30 min)` ticks down the same way a user-initiated 30-minute
    // session does.
    var soonestDeadline: Date? {
        var candidates: [Date] = []
        if let u = preventer.activeUntil { candidates.append(u) }
        candidates.append(contentsOf: mcpSessions.values.compactMap { $0.expiresAt })
        return candidates.min()
    }

    // Identity tracker for the gentle-warning beep — when the soonest
    // deadline changes (one session expires, another takes over), we reset
    // `beepedForCurrentSession` so the next deadline gets its own warning.
    private var lastSoonestDeadline: Date?

    private func refreshCountdownTimer() {
        let needsTicker = soonestDeadline != nil
        if needsTicker && countdownTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateCountdown() }
            }
            RunLoop.main.add(t, forMode: .common)
            countdownTimer = t
        }
        updateCountdown()
        if !needsTicker {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func updateCountdown() {
        let deadline = soonestDeadline
        if deadline != lastSoonestDeadline {
            // New deadline (or none) — reset the gentle-warning latch so the
            // next session gets its own 30 s beep.
            beepedForCurrentSession = false
        }
        lastSoonestDeadline = deadline

        if let deadline {
            let remaining = Int(deadline.timeIntervalSinceNow)
            if remaining > 0 {
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
                return
            }
            // Deadline passed — expect a cleanup callback shortly (preventer
            // auto-deactivate or MCP session task). Clear the countdown and
            // fall through to the no-deadline tooltip logic.
            countdownText = nil
            isExpiringSoon = false
        } else {
            countdownText = nil
            isExpiringSoon = false
        }

        if preventer.isActive {
            tooltipText = String(localized: "Niacin — Keeping you awake")
        } else if hasForceActive {
            updateTooltipForForceActive()
        } else {
            tooltipText = String(localized: "Niacin — Inactive")
        }
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
        refreshMCPServer()

        guard preventer.isActive else { return }

        // Only interrupt the running session if the new policy is incompatible
        // with it. A compatible change (e.g. lock icons, allowUserToDisable
        // flipping) leaves caffeinate running.
        if let reason = sessionIncompatibilityReason() {
            log.info("deactivating running session: \(reason, privacy: .public)")
            preventer.deactivate()
            refreshCountdownTimer()
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

// MARK: - MCPSession

struct MCPSession: Sendable, Identifiable {
    let id: String
    let reason: String
    let createdAt: Date
    let expiresAt: Date?
    let clientName: String?
    let allowDisplaySleep: Bool
}

// MARK: - MCPDelegate conformance

extension AppState: MCPDelegate {
    func mcpKeepAwake(durationSeconds: Int?, reason: String, allowDisplaySleep: Bool, clientName: String?) -> MCPKeepAwakeResult {
        let now = Date()
        let expiresAt: Date? = durationSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
        let session = MCPSession(
            id: UUID().uuidString,
            reason: reason,
            createdAt: now,
            expiresAt: expiresAt,
            clientName: clientName,
            allowDisplaySleep: allowDisplaySleep
        )
        mcpSessions[session.id] = session

        // Auto-release task — replaces a Timer so it survives a system sleep
        // (Task.sleep is wall-clock, not run-loop).
        if let duration = durationSeconds, duration > 0 {
            let id = session.id
            mcpSessionTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    _ = self?.releaseMCPSession(id: id)
                }
            }
        }

        recomputeForceActiveAssertion()
        updateTooltipForForceActive()
        refreshCountdownTimer()
        return MCPKeepAwakeResult(sessionId: session.id, expiresAt: expiresAt)
    }

    func mcpReleaseAwake(sessionId: String?) -> Bool {
        if let id = sessionId {
            return releaseMCPSession(id: id)
        }
        // No id → release every MCP-owned session.
        let ids = Array(mcpSessions.keys)
        var any = false
        for id in ids { any = releaseMCPSession(id: id) || any }
        return any
    }

    func mcpStatus() -> MCPStatus {
        var sources: [String] = []
        for s in mcpSessions.values {
            sources.append("mcp:\(s.clientName ?? "agent")")
        }
        if preventer.isActive { sources.append("user") }

        return MCPStatus(
            keepingAwake: isKeepingAwake,
            activeUntil: preventer.activeUntil,
            forceActiveSources: sources
        )
    }

    @discardableResult
    func releaseMCPSession(id: String) -> Bool {
        guard mcpSessions.removeValue(forKey: id) != nil else { return false }
        mcpSessionTasks.removeValue(forKey: id)?.cancel()
        recomputeForceActiveAssertion()
        updateTooltipForForceActive()
        refreshCountdownTimer()
        return true
    }
}

