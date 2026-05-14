import Foundation
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "ai-probe")

// Polls well-known local AI-runtime HTTP endpoints on the loopback interface
// to determine which runtimes are actively loaded.
//
// This is the sandbox-safe replacement for process-name watching (which
// requires `KERN_PROC_ALL` and is filtered out of sandboxed apps). All probes
// hit `127.0.0.1:<port>`, requiring only the `com.apple.security.network.client`
// entitlement on MAS builds.
//
// Each probe distinguishes three states:
//   .offline — endpoint refused / timed out
//   .idle    — endpoint responds but nothing useful is loaded
//   .busy    — endpoint responds and a model/inference is active
//
// Only `.busy` runtimes contribute to keep-awake. To dampen flapping (a model
// briefly unloads between requests, the keep-alive expires, etc.), each
// descriptor declares an `idleGrace` window: after seeing `.busy`, the
// runtime stays in `busyMatches` for at least `idleGrace` seconds even if
// subsequent polls report `.idle` or `.offline`.

struct AIRuntimeProbeDescriptor: Sendable {
    enum Liveness: Sendable { case offline, idle, busy }

    let id: String
    let displayName: String
    let url: URL
    let interpret: @Sendable (Data, Int) -> Liveness
    let idleGrace: TimeInterval
    // Process-name substrings this probe is authoritative over. AppState
    // filters these out of ProcessWatcher matches so the probe has the
    // final word for runtimes it covers — e.g., the probe sees Ollama as
    // idle (no model loaded) and we drop the `ollama` process match.
    let coveredProcessNames: Set<String>
}

extension AIRuntimeProbeDescriptor {
    static let defaults: [AIRuntimeProbeDescriptor] = [
        .ollama,
        .lmStudio,
        .llamaCpp,
        .textGenerationWebUI,
        .comfyUI,
    ]

    // GET /api/ps → { "models": [...] }. Non-empty `models` means a model is
    // resident in VRAM; empty means Ollama is up but quiescent.
    static let ollama = AIRuntimeProbeDescriptor(
        id: "ollama",
        displayName: "Ollama",
        url: URL(string: "http://127.0.0.1:11434/api/ps")!,
        interpret: { data, status in
            guard status == 200 else { return .offline }
            let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [Any]
            return (models?.isEmpty ?? true) ? .idle : .busy
        },
        // Pairs with Ollama's default 5-minute model keep-alive — gives us a
        // matching dwell window before declaring the runtime idle.
        idleGrace: 300,
        coveredProcessNames: ["ollama"]
    )

    // GET /v1/models. LM Studio's local server returns the loaded model list.
    // Server only runs while LM Studio is foregrounded with a loaded model, so
    // a 200 here is a reliable "busy" signal.
    static let lmStudio = AIRuntimeProbeDescriptor(
        id: "lmstudio",
        displayName: "LM Studio",
        url: URL(string: "http://127.0.0.1:1234/v1/models")!,
        interpret: anyOkIsBusy,
        idleGrace: 60,
        coveredProcessNames: ["LM Studio", "lm-studio"]
    )

    // llama.cpp's HTTP server (default port). /health returns 200 when ready.
    static let llamaCpp = AIRuntimeProbeDescriptor(
        id: "llama-cpp",
        displayName: "llama.cpp",
        url: URL(string: "http://127.0.0.1:8080/health")!,
        interpret: anyOkIsBusy,
        idleGrace: 60,
        coveredProcessNames: ["llama-server", "llama.cpp"]
    )

    // text-generation-webui (oobabooga). /v1/internal/model/info or /v1/models.
    static let textGenerationWebUI = AIRuntimeProbeDescriptor(
        id: "text-gen-webui",
        displayName: "text-generation-webui",
        url: URL(string: "http://127.0.0.1:5000/v1/models")!,
        interpret: anyOkIsBusy,
        idleGrace: 60,
        coveredProcessNames: ["text-generati"]   // 16-char p_comm truncation
    )

    // ComfyUI's /system_stats returns 200 once the server is running.
    static let comfyUI = AIRuntimeProbeDescriptor(
        id: "comfyui",
        displayName: "ComfyUI",
        url: URL(string: "http://127.0.0.1:8188/system_stats")!,
        interpret: anyOkIsBusy,
        idleGrace: 60,
        coveredProcessNames: ["ComfyUI"]
    )

    private static let anyOkIsBusy: @Sendable (Data, Int) -> Liveness = { _, status in
        (200...299).contains(status) ? .busy : .offline
    }
}

@MainActor
final class AIRuntimeProbeRegistry {
    private let probes: [AIRuntimeProbeDescriptor]
    private let pollInterval: TimeInterval
    private let session: URLSession

    private var pollTask: Task<Void, Never>?
    // First .busy observation timestamp per probe — used to apply idleGrace
    // after subsequent .idle/.offline polls.
    private var lastBusyAt: [String: Date] = [:]
    private(set) var busyMatches: Set<String> = []

    private let onChange: @MainActor @Sendable (Set<String>) -> Void

    var coveredProcessNames: Set<String> {
        Set(probes.flatMap { $0.coveredProcessNames })
    }

    init(
        probes: [AIRuntimeProbeDescriptor]? = nil,
        pollInterval: TimeInterval = 30,
        onChange: @escaping @MainActor @Sendable (Set<String>) -> Void
    ) {
        let probes = probes ?? AIRuntimeProbeDescriptor.defaults
        self.probes = probes
        self.pollInterval = pollInterval
        self.onChange = onChange

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func start() {
        guard pollTask == nil else { return }
        log.info("ai-probe registry started, probes=\(self.probes.count, privacy: .public) interval=\(self.pollInterval, privacy: .public)s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                let interval = await MainActor.run { self?.pollInterval ?? 30 }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lastBusyAt.removeAll()
        if !busyMatches.isEmpty {
            busyMatches = []
            onChange([])
        }
    }

    private func pollAll() async {
        // Skip the whole pass when the auto-awake feature is off — saves
        // 5 loopback requests every 30s on machines that opted out.
        guard ManagedPreferences.resolvedAIRuntimeAutoAwake else {
            if !busyMatches.isEmpty {
                busyMatches = []
                lastBusyAt.removeAll()
                onChange([])
            }
            return
        }

        let now = Date()
        let session = self.session
        let snapshot = self.probes

        let results: [(String, AIRuntimeProbeDescriptor.Liveness)] = await withTaskGroup(
            of: (String, AIRuntimeProbeDescriptor.Liveness).self
        ) { group in
            for probe in snapshot {
                group.addTask {
                    do {
                        var req = URLRequest(url: probe.url)
                        req.httpMethod = "GET"
                        req.timeoutInterval = 2
                        let (data, response) = try await session.data(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        return (probe.id, probe.interpret(data, status))
                    } catch {
                        return (probe.id, .offline)
                    }
                }
            }
            var collected: [(String, AIRuntimeProbeDescriptor.Liveness)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var nextBusy: Set<String> = []
        for (id, liveness) in results {
            guard let probe = probes.first(where: { $0.id == id }) else { continue }
            switch liveness {
            case .busy:
                lastBusyAt[id] = now
                nextBusy.insert(probe.displayName)
            case .idle, .offline:
                if let last = lastBusyAt[id],
                   now.timeIntervalSince(last) < probe.idleGrace {
                    // Still in dwell window — keep it busy.
                    nextBusy.insert(probe.displayName)
                } else {
                    lastBusyAt.removeValue(forKey: id)
                }
            }
        }

        if nextBusy != busyMatches {
            let added = nextBusy.subtracting(busyMatches).sorted()
            let removed = busyMatches.subtracting(nextBusy).sorted()
            log.info("ai-probe busy change: +\(added, privacy: .public) -\(removed, privacy: .public)")
            busyMatches = nextBusy
            onChange(nextBusy)
        }
    }
}
