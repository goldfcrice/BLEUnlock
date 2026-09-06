import Cocoa
import os

// Watches the unified log for failed password attempts at the lock screen
// (loginwindow/SecurityAgent emit "Authentication failure" / "INCORRECT" /
// "APEventTouchIDNoMatch" entries that are not privacy-redacted).
class AuthFailureMonitor {
    private var process: Process?
    private var restartTimer: Timer?
    private var lastEventAt = 0.0
    private var lineBuffer = ""
    // Incremented on stop(); callbacks compare against the generation they
    // were created in so a late termination cannot restart a stopped monitor.
    private var generation = 0
    var onAuthFailure: (() -> Void)?

    // Keep in sync with looksLikeAuthFailure below. "Authentication fail"
    // covers both "Authentication failure" (loginwindow/SecurityAgent on
    // older macOS) and "Authentication failed ... ODErrorCredentialsInvalid"
    // (opendirectoryd on newer macOS).
    private static let predicate =
        "(process == \"loginwindow\" OR process == \"SecurityAgent\" OR process == \"opendirectoryd\") AND " +
        "(eventMessage CONTAINS[c] \"Authentication fail\" OR " +
        "eventMessage CONTAINS[c] \"INCORRECT\" OR " +
        "eventMessage CONTAINS[c] \"APEventTouchIDNoMatch\")"

    func start() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // ndjson = one JSON object per line; "json" pretty-prints a multi-line
        // array that a line-based parser cannot consume.
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        // Never hand a child an unread pipe for stderr: once its 64KB buffer
        // fills the process blocks forever and the monitor silently dies.
        p.standardError = FileHandle.nullDevice
        lineBuffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.ingest(chunk) }
        }
        let gen = generation
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.process = nil
                // log stream can die (logd restarts, system sleep); come back after a pause.
                self.restartTimer?.invalidate()
                self.restartTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    guard let self, self.generation == gen else { return }
                    self.restartTimer = nil
                    self.start()
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            print("AuthFailureMonitor: failed to start log stream: \(error)")
            restartTimer?.invalidate()
            restartTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.restartTimer = nil
                self?.start()
            }
        }
    }

    func stop() {
        generation += 1
        restartTimer?.invalidate()
        restartTimer = nil
        guard let p = process else { return }
        p.terminationHandler = nil
        process = nil
        if let pipe = p.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        p.terminate()
    }

    private func ingest(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lineBuffer += chunk
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  // log(1) json output has no "process" key; the executable
                  // arrives as "processImagePath" (full path).
                  let process = (json["process"] as? String)
                      ?? (json["processImagePath"] as? String).map { ($0 as NSString).lastPathComponent },
                  let message = json["eventMessage"] as? String else { continue }
            guard Self.looksLikeAuthFailure(process: process, message: message) else { continue }
            let now = Date().timeIntervalSince1970
            guard now >= lastEventAt + 2 else { continue } // one wrong attempt can log several entries
            lastEventAt = now
            os_log("auth-failure matched from %{public}@, dispatching callback", log: appLog, type: .default, process)
            onAuthFailure?()
        }
    }

    private static func looksLikeAuthFailure(process: String, message: String) -> Bool {
        let m = message.lowercased()
        if m.contains("authentication fail") || m.contains("apeventtouchidnomatch") {
            return true
        }
        // "incorrect" only counts from the lock-screen UI processes; keep this
        // in sync with the predicate above.
        return (process == "loginwindow" || process == "SecurityAgent") && m.contains("incorrect")
    }
}
