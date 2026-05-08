import Foundation

@Observable
@MainActor
final class SleepPreventer {
    private(set) var isActive = false
    private(set) var activeUntil: Date?
    private(set) var isAllowingDisplaySleep = false

    private var process: Process?

    func activate(duration: TimeInterval?, allowDisplaySleep: Bool = false) {
        deactivate()

        // -di: prevent display + system sleep (full awake)
        // -i:  prevent system sleep only, display can time out and lock per policy
        var args = allowDisplaySleep ? ["-i"] : ["-di"]
        if let duration, duration > 0 {
            args += ["-t", "\(Int(duration))"]
            activeUntil = Date().addingTimeInterval(duration)
        } else {
            activeUntil = nil
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try p.run()
            process = p
            isActive = true
            isAllowingDisplaySleep = allowDisplaySleep
        } catch {
            activeUntil = nil
        }
    }

    func deactivate() {
        process?.terminate()
        process = nil
        isActive = false
        activeUntil = nil
        isAllowingDisplaySleep = false
    }

    private func handleTermination() {
        process = nil
        isActive = false
        activeUntil = nil
        isAllowingDisplaySleep = false
    }
}
