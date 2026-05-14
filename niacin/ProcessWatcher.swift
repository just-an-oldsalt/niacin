// ProcessWatcher uses `sysctl(KERN_PROC_ALL)` to enumerate every running
// process by name. Under App Sandbox the kernel filters that call to return
// only the calling app's own processes, so the watcher has no value in the
// MAS build — it's compiled out entirely there. The MAS build relies on the
// AIRuntimeProbeRegistry (HTTP probes on loopback) plus, when present, the
// MCP server through which agents can declare keep-awake intent.
#if !MAS_BUILD
import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "process-watcher")

// Polls every N seconds for running processes matching any of the configured
// name patterns. Calls `onChange` when the matching set transitions
// non-empty ↔ empty, or when the set of matches grows / shrinks.
//
// Used by AppState to drive three independent force-activation triggers:
//   1. `forceActiveDuringDeploys` — IT-managed array of deploy daemons
//      (`jamf`, `installd`, etc.). Force-activates silently while IT pushes
//      software so the device doesn't sleep mid-deploy.
//   2. `forceActiveDuringApps` — IT or user-configurable array of
//      applications (`zoom.us`, `OBS`, etc.) that should keep the device
//      awake while running.
//   3. AI runtime auto-detect — hardcoded list of known local-AI runtimes
//      (Ollama, LM Studio, llama.cpp server, ComfyUI, etc.). Gated by the
//      `aiRuntimeAutoAwake` managed pref or the equivalent user toggle.
//
// `kinfo_proc.kp_proc.p_comm` is limited to 16 chars by the kernel, so name
// patterns must fit that ceiling. Matching is case-insensitive substring
// against `p_comm`; a needle of `ollama` will match `Ollama` and `ollamax`
// alike. Pick patterns specific enough to avoid collisions.
@MainActor
final class ProcessWatcher {
    private let watcherName: String
    private let interval: TimeInterval
    private let needlesProvider: @MainActor @Sendable () -> [String]
    private let onChange: @MainActor @Sendable (Set<String>) -> Void

    private var timer: Timer?
    private var lastMatching: Set<String> = []

    init(
        name: String,
        interval: TimeInterval = 5.0,
        needlesProvider: @escaping @MainActor @Sendable () -> [String],
        onChange: @escaping @MainActor @Sendable (Set<String>) -> Void
    ) {
        self.watcherName = name
        self.interval = interval
        self.needlesProvider = needlesProvider
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()  // run an immediate first check so callers don't wait `interval`
        log.info("\(self.watcherName, privacy: .public) started, interval=\(self.interval, privacy: .public)s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if !lastMatching.isEmpty {
            lastMatching = []
            onChange([])
        }
    }

    // Force a re-check. Useful when the needles provider's underlying source
    // changes (e.g. a managed-prefs reload) — caller can poke us instead of
    // waiting for the next scheduled tick.
    func recheck() {
        tick()
    }

    private func tick() {
        let needles = needlesProvider()
        guard !needles.isEmpty else {
            if !lastMatching.isEmpty {
                let prior = lastMatching
                lastMatching = []
                log.info("\(self.watcherName, privacy: .public): no patterns configured, clearing \(prior.sorted(), privacy: .public)")
                onChange([])
            }
            return
        }

        let running = Self.currentProcessNames()
        var matched = Set<String>()
        for needle in needles {
            let lowerNeedle = needle.lowercased()
            for name in running where name.lowercased().contains(lowerNeedle) {
                matched.insert(name)
            }
        }

        if matched != lastMatching {
            let prior = lastMatching
            lastMatching = matched
            log.info("\(self.watcherName, privacy: .public): matching=\(matched.sorted(), privacy: .public) (was \(prior.sorted(), privacy: .public))")
            onChange(matched)
        }
    }

    // Enumerate all running processes' `p_comm` names via sysctl(KERN_PROC).
    // Note: `p_comm` is at most 16 chars; longer process names are truncated.
    // Pick watch patterns that fit within that limit.
    private static func currentProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            log.error("sysctl size probe failed: \(String(cString: strerror(errno)), privacy: .public)")
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.size
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            log.error("sysctl fetch failed: \(String(cString: strerror(errno)), privacy: .public)")
            return []
        }

        var names = Set<String>()
        for i in 0..<count {
            var proc = procs[i]
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base)
            }
            if !name.isEmpty {
                names.insert(name)
            }
        }
        return names
    }
}
#endif
