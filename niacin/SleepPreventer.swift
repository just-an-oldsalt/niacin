import Foundation
import OSLog
import IOKit.pwr_mgt

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "sleep-preventer")

// Holds IOKit power assertions that prevent system / display idle sleep. The
// assertions are owned by this process — when Niacin exits for any reason
// (clean quit, crash, kill -9, Sparkle update), the kernel releases them
// automatically. This is the key reason for moving off `caffeinate`: spawned
// caffeinate children would survive parent death and leak power assertions.
@Observable
@MainActor
final class SleepPreventer {
    private(set) var isActive = false
    private(set) var activeUntil: Date?
    private(set) var isAllowingDisplaySleep = false

    // Non-nil when the most recent `activate()` failed at the IOKit boundary
    // (very rare, but possible under restrictive sandbox profiles or future
    // macOS releases that lock down `IOPMAssertionCreateWithName`). Cleared
    // on the next successful activate() or any deactivate(). Views surface
    // it as a menu-bar error icon + tooltip so the user knows something is
    // wrong rather than seeing the menu silently fail.
    private(set) var lastError: String?

    // Two assertions because macOS lets us hold them independently — system
    // idle sleep and display idle sleep are separate concerns, mirroring
    // caffeinate's `-i` (system only) vs `-di` (system + display) flags.
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0

    // Auto-deactivate timer for timed sessions (replaces caffeinate's `-t`).
    private var deactivationTimer: Timer?

    func activate(duration: TimeInterval?, allowDisplaySleep: Bool = false) {
        deactivate()

        let reason = "Niacin keeping the system awake" as CFString

        var sysID: IOPMAssertionID = 0
        let sysResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sysID
        )
        guard sysResult == kIOReturnSuccess else {
            let msg = "system-sleep assertion failed (IOReturn \(sysResult))"
            log.error("\(msg, privacy: .public)")
            lastError = msg
            return
        }
        systemAssertionID = sysID

        if !allowDisplaySleep {
            var dispID: IOPMAssertionID = 0
            let dispResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &dispID
            )
            guard dispResult == kIOReturnSuccess else {
                let msg = "display-sleep assertion failed (IOReturn \(dispResult))"
                log.error("\(msg, privacy: .public)")
                lastError = msg
                IOPMAssertionRelease(systemAssertionID)
                systemAssertionID = 0
                return
            }
            displayAssertionID = dispID
        }

        isActive = true
        isAllowingDisplaySleep = allowDisplaySleep
        lastError = nil

        if let duration, duration > 0 {
            activeUntil = Date().addingTimeInterval(duration)
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.deactivate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            deactivationTimer = timer
        } else {
            activeUntil = nil
        }

        let durationDesc = activeUntil.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "indefinitely"
        let mode = allowDisplaySleep ? "system-only" : "system+display"
        log.info("activated: \(mode, privacy: .public), \(durationDesc, privacy: .public)")
    }

    func deactivate() {
        guard isActive else { return }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        deactivationTimer?.invalidate()
        deactivationTimer = nil
        isActive = false
        activeUntil = nil
        isAllowingDisplaySleep = false
        lastError = nil
        log.info("deactivated, assertions released")
    }
}
