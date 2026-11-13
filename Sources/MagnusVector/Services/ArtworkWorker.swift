import Foundation

struct ArtworkRuntime: Decodable {
    let python: String
    let codex: String
    static func load() throws -> ArtworkRuntime {
        guard let url = Bundle.main.url(forResource: "runtime", withExtension: "json") else { throw ArtworkError.message("The artwork runtime is missing. Rebuild the app with script/build_and_run.sh.") }
        let runtime = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard FileManager.default.isExecutableFile(atPath: runtime.python) else {
            throw ArtworkError.message("The vector conversion runtime is unavailable. Rebuild the app to reconnect it.")
        }
        return runtime
    }
}

enum ArtworkError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

final class ArtworkWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    func run(mode: String, job: URL? = nil, connection: ProviderConnection? = nil, event: @escaping @Sendable ([String: Any]) -> Void) async throws {
        let runtime = try ArtworkRuntime.load()
        let requiresCodex = mode != "trace" && (connection?.id ?? "codex") == "codex"
        guard !requiresCodex || FileManager.default.isExecutableFile(atPath: runtime.codex) else {
            throw ArtworkError.message("Codex is unavailable. Install and sign in to Codex, then rebuild the app to reconnect it.")
        }
        guard let script = Bundle.main.url(forResource: "artwork_worker", withExtension: "py", subdirectory: "Artwork") else { throw ArtworkError.message("The artwork worker is missing from the app.") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process(); let pipe = Pipe()
                    p.executableURL = URL(fileURLWithPath: runtime.python)
                    p.arguments = [script.path, mode, "--codex", runtime.codex]
                    if let job { p.arguments! += ["--job", job.path, "--request", job.appendingPathComponent("request.json").path] }
                    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                    var environment = ProcessInfo.processInfo.environment
                    environment["PYTHONUNBUFFERED"] = "1"
                    environment["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    environment.removeValue(forKey: "MAGDOBE_PROVIDER_API_KEY")
                    environment.removeValue(forKey: "MAGDOBE_PROVIDER_CONFIG")
                    if let connection {
                        let config = try? JSONSerialization.data(withJSONObject: connection.workerConfiguration)
                        environment["MAGDOBE_PROVIDER_CONFIG"] = config.map { String(decoding: $0, as: UTF8.self) }
                        if let key = connection.apiKey { environment["MAGDOBE_PROVIDER_API_KEY"] = key }
                    }
                    p.environment = environment
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    self.process = p
                    do { try p.run(); self.lock.unlock() }
                    catch { self.lock.unlock(); continuation.resume(throwing: error); return }
                    var buffer = Data(); var reportedError: String?
                    while true {
                        let bytes = pipe.fileHandleForReading.availableData
                        if bytes.isEmpty { break }
                        buffer.append(bytes)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                            if value["stage"] as? String == "error" { reportedError = value["message"] as? String }
                            event(value)
                        }
                    }
                    p.waitUntilExit()
                    self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                    else if p.terminationStatus != 0 { continuation.resume(throwing: ArtworkError.message(reportedError ?? "The artwork process stopped. Try again or check the provider connection.")) }
                    else { continuation.resume() }
                }
            }
        } onCancel: { self.cancel() }
    }
}
