import Foundation
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "ollama-probe")

// Polls Ollama's `/api/ps` endpoint to distinguish "Ollama is running" from
// "Ollama has a model loaded into VRAM right now". The process watcher catches
// the former (`ollama` in the running-process list); this probe refines it.
//
// The use case: Ollama is commonly installed as a launchd autostart service
// that idles in the background. With process-presence detection alone, the
// system would stay awake 24/7. With this probe, force-active drops 5 minutes
// after the last loaded model unloads — the default Ollama keep-alive — so the
// device can sleep when nothing is actually inferring.
//
// Endpoint contract (Ollama):
//   GET http://127.0.0.1:11434/api/ps
//   200 → { "models": [ {...}, ... ] }
// When the array is empty, no model is in VRAM. When non-empty, inference is
// either active or sitting in the keep-alive window — both should keep the
// system awake.
//
// Probe is gated on `ManagedPreferences.aiRuntimeAutoAwake`; when the managed
// key is false, the probe returns immediately so it costs nothing.
//
// Failure handling: if the endpoint is unreachable (Ollama not running, port
// blocked, transient network), we leave the last known state alone. The
// process watcher's removal of Ollama from `aiRuntimeMatches` is the
// authoritative "Ollama is gone" signal — the probe stays out of its way.
@MainActor
final class OllamaInferenceProbe {
    private let url = URL(string: "http://127.0.0.1:11434/api/ps")!
    private let interval: TimeInterval = 30
    // Minimum time we must observe an empty models array before declaring
    // Ollama "idle". Pairs with Ollama's default 5-min model keep-alive so
    // we don't flap force-active state every time a model unloads.
    private let idleGraceSeconds: TimeInterval = 300

    private var timer: Timer?
    // Timestamp of the first empty-models observation in the current idle
    // window. Reset to nil whenever we see a non-empty models array.
    private var idleSince: Date?
    private(set) var isIdle: Bool = false
    private let onChange: @MainActor @Sendable (Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in await self.tick() }
        log.info("ollama probe started, interval=\(self.interval, privacy: .public)s grace=\(self.idleGraceSeconds, privacy: .public)s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        idleSince = nil
        if isIdle {
            isIdle = false
            onChange(false)
        }
    }

    private func tick() async {
        guard ManagedPreferences.resolvedAIRuntimeAutoAwake else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // Ollama unreachable: don't change state. The process watcher owns
            // the "Ollama is gone" transition.
            return
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return
        }

        let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [Any] ?? []

        if models.isEmpty {
            if idleSince == nil {
                idleSince = Date()
            }
            let elapsed = idleSince.map { Date().timeIntervalSince($0) } ?? 0
            let nowIdle = elapsed >= idleGraceSeconds
            if nowIdle != isIdle {
                isIdle = nowIdle
                log.info("ollama idle transition: isIdle=\(nowIdle, privacy: .public) elapsed=\(Int(elapsed), privacy: .public)s")
                onChange(nowIdle)
            }
        } else {
            idleSince = nil
            if isIdle {
                isIdle = false
                log.info("ollama busy again, dropping idle state (models=\(models.count, privacy: .public))")
                onChange(false)
            }
        }
    }
}
