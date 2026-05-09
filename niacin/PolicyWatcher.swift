import Foundation
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "policy-watcher")

// Watches the managed-preferences plist files and invokes a callback on the
// main actor when they change. Uses kqueue (DispatchSourceFileSystemObject) for
// instant reaction with a 30-second mod-date poll as a safety net for
// filesystems where kqueue events may not deliver (network mounts, atomic
// replace edge cases). Events within 200 ms are debounced into a single fire.
final class PolicyWatcher {
    private let queue = DispatchQueue(label: "com.oldsalt.niacin.policy-watcher")
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var fds: [String: Int32] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var lastModDates: [String: Date] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var onChange: (@MainActor () -> Void)?

    private let paths: [String] = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.oldsalt.niacin"
        return [
            "/Library/Managed Preferences/\(bundleID).plist",
            "/Library/Managed Preferences/\(NSUserName())/\(bundleID).plist",
        ]
    }()

    func start(onChange: @escaping @MainActor () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            for path in self.paths {
                self.installWatch(path: path)
                self.lastModDates[path] = self.currentModDate(path)
            }
            self.startPollFallback()
            log.info("policy watcher started: \(self.paths.count, privacy: .public) paths, kqueue + 30s poll")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for source in self.sources.values { source.cancel() }
            self.sources.removeAll()
            self.fds.removeAll()
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
        }
    }

    private func currentModDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func installWatch(path: String) {
        if let existing = sources[path] {
            existing.cancel()
            sources[path] = nil
            fds[path] = nil
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log.debug("kqueue open skipped (file absent): \(path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .link],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            log.info("kqueue event [\(Self.describe(event), privacy: .public)] on \(path, privacy: .public)")
            // Atomic replace (cp, JAMF, defaults write) detaches the inode —
            // re-open the path so subsequent writes still fire.
            if event.contains(.rename) || event.contains(.delete) {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    self?.installWatch(path: path)
                }
            }
            self.scheduleFire()
        }

        source.setCancelHandler {
            close(fd)
        }

        sources[path] = source
        fds[path] = fd
        source.resume()
        log.debug("watching \(path, privacy: .public) (fd=\(fd, privacy: .public))")
    }

    private func startPollFallback() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.checkModDates()
        }
        pollTimer = timer
        timer.resume()
    }

    private func checkModDates() {
        var changed = false
        for path in paths {
            let modDate = currentModDate(path)
            if modDate != lastModDates[path] {
                if lastModDates[path] != nil || modDate != nil {
                    log.info("poll detected change at \(path, privacy: .public)")
                    changed = true
                }
                lastModDates[path] = modDate
            }
            // Re-attach a watch if the file appeared after we started.
            if modDate != nil && fds[path] == nil {
                installWatch(path: path)
            }
        }
        if changed { scheduleFire() }
    }

    private static func describe(_ event: DispatchSource.FileSystemEvent) -> String {
        var parts: [String] = []
        if event.contains(.write)   { parts.append("write") }
        if event.contains(.extend)  { parts.append("extend") }
        if event.contains(.attrib)  { parts.append("attrib") }
        if event.contains(.link)    { parts.append("link") }
        if event.contains(.rename)  { parts.append("rename") }
        if event.contains(.delete)  { parts.append("delete") }
        if event.contains(.revoke)  { parts.append("revoke") }
        if event.contains(.funlock) { parts.append("funlock") }
        return parts.isEmpty ? "0x\(String(event.rawValue, radix: 16))" : parts.joined(separator: ",")
    }

    private func scheduleFire() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let cb = self?.onChange else { return }
            Task { @MainActor in cb() }
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: item)
    }
}
